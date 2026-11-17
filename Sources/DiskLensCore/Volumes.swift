import Foundation

/// Capacity numbers for a volume, from public `NSURL` resource keys.
public struct VolumeSpace: Sendable, Equatable {
    public var total: UInt64
    /// Free right now (statfs view).
    public var available: UInt64
    /// What the system could free on demand for important work
    /// (`availableCapacityForImportantUsage`) — includes purgeable space.
    public var availableForImportantUsage: UInt64

    public init(total: UInt64, available: UInt64, availableForImportantUsage: UInt64) {
        self.total = total
        self.available = available
        self.availableForImportantUsage = availableForImportantUsage
    }

    public var used: UInt64 { total > available ? total - available : 0 }

    /// Space held by caches, local snapshots, etc. that macOS can purge.
    public var purgeable: UInt64 {
        availableForImportantUsage > available ? availableForImportantUsage - available : 0
    }

    public static func fetch(path: String) -> VolumeSpace? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacity
        else { return nil }
        let important = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
        return VolumeSpace(
            total: UInt64(max(0, total)),
            available: UInt64(max(0, available)),
            availableForImportantUsage: important ?? UInt64(max(0, available))
        )
    }
}

/// A mounted volume shown on the start screen.
public struct VolumeInfo: Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let format: String
    public let isInternal: Bool
    public let isEjectable: Bool
    public let isRootFileSystem: Bool
    public let space: VolumeSpace

    public static func mountedVolumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeLocalizedFormatDescriptionKey, .volumeIsInternalKey,
            .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsRootFileSystemKey,
            .volumeIsBrowsableKey,
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]
        ) else { return [] }

        var result: [VolumeInfo] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable ?? true,
                  let space = VolumeSpace.fetch(path: url.path),
                  space.total > 0
            else { continue }
            result.append(VolumeInfo(
                path: url.path,
                name: values.volumeName ?? url.lastPathComponent,
                format: values.volumeLocalizedFormatDescription ?? "",
                isInternal: values.volumeIsInternal ?? false,
                isEjectable: (values.volumeIsEjectable ?? false) || (values.volumeIsRemovable ?? false),
                isRootFileSystem: values.volumeIsRootFileSystem ?? (url.path == "/"),
                space: space
            ))
        }
        return result.sorted { lhs, rhs in
            if lhs.isRootFileSystem != rhs.isRootFileSystem { return lhs.isRootFileSystem }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

/// Byte count formatting shared by the app.
public enum ByteFormat {
    public static func string(_ bytes: UInt64) -> String {
        formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    nonisolated(unsafe) private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()
}
