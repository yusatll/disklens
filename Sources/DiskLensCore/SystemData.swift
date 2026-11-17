import Foundation

/// The cleanable parts of macOS "System Data" — the catch-all storage category
/// in System Settings › General › Storage.
///
/// Each category says what it is, how safe it is to remove, and *how* it is
/// removed. Where a tool has a supported cleanup command (`tmutil`,
/// `xcrun simctl`, `conda clean`, the system purge API, Finder's Empty Trash)
/// that command is used instead of deleting files behind its back. Things the
/// system manages itself (swap, `/System`, Spotlight, app databases) are never
/// offered.
public struct CleanupCategory: Identifiable, Sendable {
    public enum Safety: Int, Sendable, Comparable {
        /// Rebuilt automatically or re-downloaded on demand.
        case safe
        /// Removable, but the user should know what they lose.
        case review

        public static func < (a: Safety, b: Safety) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Method: Sendable, Equatable {
        /// Delete everything inside these folders (the folders stay).
        case deleteContents
        /// Same, but the folders are owned by root.
        case deleteContentsAsAdministrator
        /// Move everything inside these folders to the Trash (reversible).
        case trashContents
        /// Move the listed items themselves to the Trash.
        case trashItems
        /// Run a tool's own cleanup command.
        case command([String])
        /// Ask macOS to purge purgeable space.
        case purge
        /// Delete Time Machine local snapshots with `tmutil`.
        case deleteLocalSnapshots
        /// Empty the Trash through Finder.
        case emptyTrash
    }

    public enum Kind: String, Sendable, CaseIterable {
        case userCaches, userLogs, mailDownloads, trash, purgeable
        case xcodeDerivedData, deviceSupport, simulatorCaches, unavailableSimulators
        case npmCache, gradleCaches, condaPackages
        case localSnapshots, systemCaches, systemLogs, xcodeArchives, deviceBackups, macOSInstallers
    }

    public let kind: Kind
    public var id: String { kind.rawValue }
    public let safety: Safety
    public let method: Method
    /// Folders (or items, for `trashItems`) the category covers.
    public let paths: [String]
    /// Bytes that cleaning would release (nil = not measured / unknown).
    public var size: UInt64?

    public init(kind: Kind, safety: Safety, method: Method, paths: [String], size: UInt64? = nil) {
        self.kind = kind
        self.safety = safety
        self.method = method
        self.paths = paths
        self.size = size
    }

    public var needsAdministrator: Bool { method == .deleteContentsAsAdministrator }
}

public enum SystemDataCatalog {
    /// All categories that apply to this Mac (tools and folders that exist).
    public static func categories(home: String = NSHomeDirectory()) -> [CleanupCategory] {
        let fm = FileManager.default
        func existing(_ paths: [String]) -> [String] { paths.filter { fm.fileExists(atPath: $0) } }
        let dev = home + "/Library/Developer"
        var result: [CleanupCategory] = []

        func add(_ kind: CleanupCategory.Kind, _ safety: CleanupCategory.Safety, _ method: CleanupCategory.Method,
                 _ paths: [String], requirePaths: Bool = true) {
            let present = existing(paths)
            if requirePaths && present.isEmpty { return }
            result.append(CleanupCategory(kind: kind, safety: safety, method: method, paths: present))
        }

        // Safe: rebuilt or re-downloaded automatically.
        add(.userCaches, .safe, .deleteContents, [home + "/Library/Caches"])
        add(.userLogs, .safe, .deleteContents, [home + "/Library/Logs"])
        add(.mailDownloads, .safe, .deleteContents,
            [home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"])
        add(.trash, .safe, .emptyTrash, [home + "/.Trash"])
        add(.purgeable, .safe, .purge, [], requirePaths: false)
        add(.xcodeDerivedData, .safe, .deleteContents, [dev + "/Xcode/DerivedData"])
        add(.deviceSupport, .safe, .deleteContents,
            ["iOS", "watchOS", "tvOS", "visionOS", "macOS"].map { dev + "/Xcode/\($0) DeviceSupport" })
        add(.simulatorCaches, .safe, .deleteContents, [dev + "/CoreSimulator/Caches"])
        if fm.fileExists(atPath: "/usr/bin/xcrun"), fm.fileExists(atPath: dev + "/CoreSimulator/Devices") {
            result.append(CleanupCategory(kind: .unavailableSimulators, safety: .safe,
                                          method: .command(["/usr/bin/xcrun", "simctl", "delete", "unavailable"]),
                                          paths: unavailableSimulatorPaths(developerFolder: dev)))
        }
        add(.npmCache, .safe, .deleteContents, [home + "/.npm/_cacache"])

        // Review: removable, but there is something to lose.
        add(.gradleCaches, .review, .deleteContents, [home + "/.gradle/caches"])
        for base in ["miniconda3", "anaconda3", "opt/miniconda3", "opt/anaconda3", "miniforge3"] {
            let conda = home + "/" + base + "/bin/conda"
            if fm.isExecutableFile(atPath: conda) {
                add(.condaPackages, .review, .command([conda, "clean", "--all", "--yes"]), [home + "/" + base + "/pkgs"])
                break
            }
        }
        add(.localSnapshots, .review, .deleteLocalSnapshots, [], requirePaths: false)
        add(.systemCaches, .review, .deleteContentsAsAdministrator, ["/Library/Caches"])
        add(.systemLogs, .review, .deleteContentsAsAdministrator, ["/Library/Logs"])
        add(.xcodeArchives, .review, .trashContents, [dev + "/Xcode/Archives"])
        add(.deviceBackups, .review, .trashContents, [home + "/Library/Application Support/MobileSync/Backup"])
        let installers = ((try? fm.contentsOfDirectory(atPath: "/Applications")) ?? [])
            .filter { $0.hasPrefix("Install macOS") && $0.hasSuffix(".app") }
            .map { "/Applications/" + $0 }
        if !installers.isEmpty {
            result.append(CleanupCategory(kind: .macOSInstallers, safety: .review, method: .trashItems, paths: installers))
        }
        return result
    }

    /// Data folders of simulators whose runtime is no longer installed
    /// (what `xcrun simctl delete unavailable` removes).
    static func unavailableSimulatorPaths(developerFolder: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "unavailable", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]]
        else { return [] }
        return devices.values.flatMap { $0 }
            .compactMap { $0["udid"] as? String }
            .map { developerFolder + "/CoreSimulator/Devices/" + $0 }
    }
}

/// Performs the non-privileged cleanup methods. Administrator work is done by
/// the caller through `Privileged`.
public enum SystemDataCleaner {
    public struct Outcome: Sendable {
        /// Real problems worth showing (not protection by macOS).
        public var failures: [String: String] = [:]
        /// Items moved to the Trash (space is released when the Trash is emptied).
        public var trashed = 0
        /// Items macOS protects from apps (SIP / privacy / app sandbox data);
        /// left alone on purpose — this is expected, not an error.
        public var protectedPaths: [String] = []

        public mutating func merge(_ other: Outcome) {
            failures.merge(other.failures) { a, _ in a }
            trashed += other.trashed
            protectedPaths += other.protectedPaths
        }
    }

    /// Deletes `path`. When the whole item can't go (something inside is
    /// protected or in use), it descends and deletes everything it can, so a
    /// single protected file doesn't keep a whole cache folder alive.
    static func removeAsMuchAsPossible(_ path: String, fm: FileManager, outcome: inout Outcome) {
        do {
            try fm.removeItem(atPath: path)
            return
        } catch {
            guard isProtection(error) || isNotEmpty(error) else {
                if !isMissing(error) { outcome.failures[path] = describe(error) }
                return
            }
            var isDirectory: ObjCBool = false
            let isRealDirectory = fm.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                && (try? fm.destinationOfSymbolicLink(atPath: path)) == nil
            guard isRealDirectory, let names = try? fm.contentsOfDirectory(atPath: path) else {
                outcome.protectedPaths.append(path)
                return
            }
            for name in names {
                removeAsMuchAsPossible(path + "/" + name, fm: fm, outcome: &outcome)
            }
            // The folder itself goes only if everything inside could be removed;
            // protected leftovers were already recorded by the recursion.
            if (try? fm.contentsOfDirectory(atPath: path))?.isEmpty == true {
                try? fm.removeItem(atPath: path)
            }
        }
    }

    private static func posixCode(_ error: Error) -> Int32? {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain { return Int32(nsError.code) }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        return nil
    }

    /// "Operation not permitted" / "Permission denied": macOS protection (SIP,
    /// privacy controls, another app's sandbox data) or another owner.
    static func isProtection(_ error: Error) -> Bool {
        if let code = posixCode(error) { return code == EPERM || code == EACCES || code == EROFS }
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && (nsError.code == NSFileWriteNoPermissionError || nsError.code == NSFileReadNoPermissionError
                || nsError.code == NSFileWriteVolumeReadOnlyError)
    }

    private static func isNotEmpty(_ error: Error) -> Bool {
        posixCode(error) == ENOTEMPTY || posixCode(error) == EBUSY
    }

    private static func isMissing(_ error: Error) -> Bool {
        let nsError = error as NSError
        return posixCode(error) == ENOENT || (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError)
    }

    /// Items directly inside the category's folders (what `deleteContents` removes).
    public static func contents(of category: CleanupCategory) -> [String] {
        category.paths.flatMap { folder -> [String] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            return names.map { folder + "/" + $0 }
        }
    }

    public static func clean(_ category: CleanupCategory) async -> Outcome {
        var outcome = Outcome()
        let fm = FileManager()
        switch category.method {
        case .deleteContents:
            for path in contents(of: category) {
                removeAsMuchAsPossible(path, fm: fm, outcome: &outcome)
            }

        case .trashContents, .trashItems:
            let targets = category.method == .trashItems ? category.paths : contents(of: category)
            for path in targets {
                do {
                    try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                    outcome.trashed += 1
                } catch {
                    if isProtection(error) {
                        outcome.protectedPaths.append(path)
                    } else if !isMissing(error) {
                        outcome.failures[path] = describe(error)
                    }
                }
            }

        case let .command(argv):
            let (status, output) = run(argv)
            if status != 0 { outcome.failures[argv.joined(separator: " ")] = output.isEmpty ? "exit \(status)" : output }

        case .purge:
            do {
                _ = try await PurgeableSpace.recover(volumePath: "/")
            } catch {
                outcome.failures["purge"] = error.localizedDescription
            }

        case .deleteLocalSnapshots:
            for snapshot in APFSSnapshots.snapshotVolumes(forScanOf: "/").flatMap(APFSSnapshots.list(volumePath:)) {
                guard snapshot.timeMachineDate != nil else { continue }
                if !Privileged.runWithoutPrivileges(snapshot.deletionCommand) {
                    outcome.failures[snapshot.name] = String(localized: "Could not delete the snapshot.")
                }
            }

        case .emptyTrash:
            let (status, output) = run(["/usr/bin/osascript", "-e", "tell application \"Finder\" to empty trash"])
            if status != 0 { outcome.failures["Trash"] = output.isEmpty ? "exit \(status)" : output }

        case .deleteContentsAsAdministrator:
            break // done by the caller with Privileged
        }
        return outcome
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(underlying.code)))
        }
        return nsError.localizedDescription
    }

    static func run(_ argv: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (127, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, String(text.suffix(400)))
    }
}
