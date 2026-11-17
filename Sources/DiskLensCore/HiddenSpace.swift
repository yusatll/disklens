import Darwin
import Foundation

// MARK: - APFS snapshots

public struct SnapshotInfo: Sendable, Hashable, Identifiable {
    public var id: String { volumePath + "#" + name }
    public let name: String
    /// APFS transaction ID (XID) of the snapshot.
    public let xid: UInt64
    public let volumePath: String
    public let created: Date?
    /// Bytes held only by this snapshot, if the file system could tell.
    public internal(set) var size: UInt64?

    public enum Creator: Sendable {
        case timeMachine
        case systemUpdate
        case thirdParty(String)
    }

    public var creator: Creator {
        if name.hasPrefix("com.apple.TimeMachine.") { return .timeMachine }
        if name.hasPrefix("com.apple.os.update-") || name.hasPrefix("com.apple.bless.") { return .systemUpdate }
        // Third-party tools name snapshots "<bundle id>.<something>".
        let parts = name.split(separator: ".")
        if parts.count >= 3 { return .thirdParty(parts.prefix(3).joined(separator: ".")) }
        return .thirdParty(name)
    }

    public var isThirdParty: Bool {
        if case .thirdParty = creator { return true }
        return false
    }

    /// Time Machine snapshot date ("2026-11-08-165915"), used by `tmutil deletelocalsnapshots`.
    public var timeMachineDate: String? {
        guard case .timeMachine = creator else { return nil }
        let trimmed = name.replacingOccurrences(of: "com.apple.TimeMachine.", with: "")
        return trimmed.replacingOccurrences(of: ".local", with: "")
    }

    public var displayName: String {
        switch creator {
        case .timeMachine:
            if let created {
                return String(localized: "Time Machine – \(created.formatted(date: .abbreviated, time: .shortened))")
            }
            return String(localized: "Time Machine – \(timeMachineDate ?? name)")
        case .systemUpdate:
            return String(localized: "System update snapshot")
        case let .thirdParty(creator):
            return name == creator ? name : "\(name)"
        }
    }

    /// Shell command (run as root) that deletes this snapshot.
    public var deletionCommand: [String] {
        if let date = timeMachineDate {
            return ["/usr/bin/tmutil", "deletelocalsnapshots", date]
        }
        return ["/usr/sbin/diskutil", "apfs", "deleteSnapshot", volumePath, "-xid", String(xid)]
    }
}

public enum APFSSnapshots {
    private typealias ListFunction = @convention(c) (Int32, UnsafeMutablePointer<attrlist>, UnsafeMutableRawPointer, Int, UInt32) -> Int32

    /// Lists the snapshots of a volume with `fs_snapshot_list` and measures each
    /// one with the APFS "space between snapshots" fsctl.
    public static func list(volumePath: String) -> [SnapshotInfo] {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fs_snapshot_list") else { return [] }
        let listFunction = unsafeBitCast(symbol, to: ListFunction.self)

        let fd = open(volumePath, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        let ATTR_CMN_NAME: UInt32 = 0x1
        let ATTR_CMN_OBJID: UInt32 = 0x20
        let ATTR_CMN_CRTIME: UInt32 = 0x200
        let ATTR_CMN_RETURNED_ATTRS: UInt32 = 0x8000_0000

        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJID | ATTR_CMN_CRTIME

        let capacity = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }

        var snapshots: [SnapshotInfo] = []
        while true {
            let count = listFunction(fd, &request, buffer, capacity, 0)
            if count <= 0 { break }
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<Int(count) {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                var p = entry + 4
                let returned = p.loadUnaligned(as: attribute_set_t.self)
                p += MemoryLayout<attribute_set_t>.size
                var name = ""
                var xid: UInt64 = 0
                var created: Date?
                if returned.commonattr & ATTR_CMN_NAME != 0 {
                    let ref = p.loadUnaligned(as: attrreference_t.self)
                    name = String(cString: (p + Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                    p += MemoryLayout<attrreference_t>.size
                }
                if returned.commonattr & ATTR_CMN_OBJID != 0 {
                    let objno = UInt64(p.loadUnaligned(as: UInt32.self))
                    let generation = UInt64((p + 4).loadUnaligned(as: UInt32.self))
                    xid = generation << 32 | objno
                    p += 8
                }
                if returned.commonattr & ATTR_CMN_CRTIME != 0 {
                    let spec = p.loadUnaligned(as: timespec.self)
                    created = Date(timeIntervalSince1970: Double(spec.tv_sec) + Double(spec.tv_nsec) / 1e9)
                    p += MemoryLayout<timespec>.size
                }
                if !name.isEmpty {
                    snapshots.append(SnapshotInfo(name: name, xid: xid, volumePath: volumePath, created: created, size: nil))
                }
                entry += length
            }
        }

        // Each snapshot's private size is the space between it and the previous one.
        snapshots.sort { $0.xid < $1.xid }
        var previous: UInt64 = 0
        for index in snapshots.indices {
            snapshots[index].size = spaceBetween(volumePath: volumePath, from: previous, to: snapshots[index].xid)
            previous = snapshots[index].xid
        }
        return snapshots
    }

    /// `fsctl(path, _IOWR('J', 0x13, {from, to, out}))`: bytes referenced only by
    /// snapshots in (from, to]. Undocumented; returns nil when unsupported
    /// (e.g. on the sealed system volume).
    static func spaceBetween(volumePath: String, from: UInt64, to: UInt64) -> UInt64? {
        var arguments: (UInt64, UInt64, UInt64) = (from, to, 0)
        let request: UInt = 0xC018_4A13
        let result = fsctl(volumePath, request, &arguments, 0)
        return result == 0 ? arguments.2 : nil
    }

    /// Volumes whose snapshots belong to a scan of `path`: on the startup disk
    /// the user data lives on the separate Data volume.
    public static func snapshotVolumes(forScanOf path: String) -> [String] {
        if path == "/" {
            let data = "/System/Volumes/Data"
            return FileManager.default.fileExists(atPath: data) ? [data] : ["/"]
        }
        return [path]
    }
}

// MARK: - Purgeable space

/// Purgeable space via the CoreServices disk-space recovery API
/// (`CSDiskSpaceGetRecoveryEstimate` / `CSDiskSpaceStartRecovery`, the same
/// calls the system uses). Resolved at runtime; absent → feature disabled.
public enum PurgeableSpace {
    private typealias EstimateFunction = @convention(c) (CFURL) -> UInt64
    public typealias RecoveryCompletion = @convention(block) (Bool, UInt64, CFError?) -> Void
    private typealias StartFunction = @convention(c) (
        CFURL, Int64, Int32, UnsafeMutablePointer<Unmanaged<AnyObject>?>, DispatchQueue, RecoveryCompletion
    ) -> Void

    nonisolated(unsafe) private static let handle = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW)

    public static var isRecoveryAvailable: Bool {
        handle != nil && dlsym(handle, "CSDiskSpaceStartRecovery") != nil
    }

    /// Bytes the system could free right now; nil if the API is unavailable.
    public static func estimate(volumePath: String) -> UInt64? {
        guard let handle, let symbol = dlsym(handle, "CSDiskSpaceGetRecoveryEstimate") else { return nil }
        let function = unsafeBitCast(symbol, to: EstimateFunction.self)
        return function(URL(fileURLWithPath: volumePath) as CFURL)
    }

    /// Asks the system to purge up to `bytes` (-1 = everything it can).
    /// Returns the volume's free bytes reported when recovery finished.
    public static func recover(volumePath: String, bytes: Int64 = -1) async throws -> UInt64 {
        guard let handle, let symbol = dlsym(handle, "CSDiskSpaceStartRecovery") else {
            throw PurgeError.unavailable
        }
        let function = unsafeBitCast(symbol, to: StartFunction.self)
        let url = URL(fileURLWithPath: volumePath) as CFURL
        return try await withCheckedThrowingContinuation { continuation in
            var operation: Unmanaged<AnyObject>?
            let completion: RecoveryCompletion = { succeeded, freed, error in
                if succeeded {
                    continuation.resume(returning: freed)
                } else {
                    continuation.resume(throwing: error.map { $0 as Error } ?? PurgeError.failed)
                }
            }
            function(url, bytes, 0, &operation, DispatchQueue.global(qos: .userInitiated), completion)
        }
    }

    public enum PurgeError: Error, LocalizedError {
        case unavailable
        case failed

        public var errorDescription: String? {
            switch self {
            case .unavailable: return String(localized: "Purging isn't available on this version of macOS.")
            case .failed: return String(localized: "macOS could not free purgeable space.")
            }
        }
    }
}

// MARK: - Hidden space breakdown

extension RootNode {
    /// Rebuilds the "Hidden space" / "Free space" nodes of a volume root from
    /// fresh capacity numbers, splitting hidden space into purgeable space,
    /// snapshots and the rest.
    public func updateVolumeSpace(_ space: VolumeSpace, snapshots: [SnapshotInfo]? = nil, purgeable: UInt64? = nil) {
        let previousSnapshots = children.first { $0.kind == .hiddenSpace }?
            .children.first { $0.kind == .snapshotGroup }?
            .children.compactMap { ($0 as? SnapshotNode)?.snapshot }
        let snapshotList = snapshots ?? previousSnapshots ?? []
        let previousPurgeable = children.first { $0.kind == .hiddenSpace }?.children.first { $0.kind == .purgeable }?.size

        children.removeAll { $0.kind == .hiddenSpace || $0.kind == .freeSpace }
        volumeSpace = space

        let visible = children.reduce(UInt64(0)) { $0 &+ $1.size }
        let hiddenTotal = space.used > visible ? space.used - visible : 0

        let hidden = FileNode(name: String(localized: "Hidden space"), kind: .hiddenSpace, parent: self)
        var remaining = hiddenTotal

        let measured = snapshotList.filter { ($0.size ?? 0) > 0 }
        if !measured.isEmpty {
            let group = FileNode(name: String(localized: "APFS snapshots"), kind: .snapshotGroup, parent: hidden)
            group.children = measured.map { SnapshotNode(snapshot: $0, parent: group) }
            group.finalizeFromChildren()
            group.size = min(group.size, remaining)
            remaining -= group.size
            hidden.children.append(group)
        }

        let purgeableBytes = min(purgeable ?? previousPurgeable ?? space.purgeable, remaining)
        if purgeableBytes > 0 {
            hidden.children.append(FileNode(name: String(localized: "Purgeable space"), kind: .purgeable, size: purgeableBytes, parent: hidden))
            remaining -= purgeableBytes
        }
        if remaining > 0 {
            hidden.children.append(FileNode(name: String(localized: "Other (system volumes, unreadable folders)"), kind: .otherHidden,
                                            size: remaining, parent: hidden))
        }
        hidden.finalizeFromChildren()
        if hidden.size > 0 { children.append(hidden) }

        children.append(FileNode(name: String(localized: "Free space"), kind: .freeSpace, size: space.available, parent: self))
        fileCount = children.reduce(0) { $0 + $1.fileCount }
        recomputeTotal()
        sortChildren()
    }

    private func recomputeTotal() {
        size = children.reduce(0) { $0 &+ $1.size }
    }
}
