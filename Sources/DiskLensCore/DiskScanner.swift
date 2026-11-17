import Darwin
import Foundation
import Synchronization

public struct ScanOptions: Sendable {
    /// Count bytes allocated on disk (true) or logical file length (false).
    public var useAllocatedSize: Bool = true
    /// Descend into other mounted volumes found below the scan root.
    public var crossMountPoints: Bool = false
    /// Number of worker threads. `nil` = choose from the storage medium
    /// (parallel on SSDs, serial on spinning disks).
    public var threadCount: Int?
    /// Absolute paths that are never entered.
    public var excludedPaths: Set<String> = ScanOptions.defaultExcludedPaths
    /// Add "Hidden space" / "Free space" nodes under the root when the root is a volume.
    public var addVolumeSpaceNodes: Bool = false
    /// Count cloud-only (dataless) files with their logical size, so synced
    /// cloud folders show what's stored remotely. Off: they count as 0 bytes.
    public var countCloudOnlyFiles: Bool = false
    /// Deduplicate APFS clones by clone ID (like hard links).
    public var deduplicateClones: Bool = true
    /// Depth down to which a live preview of the tree is recorded during the scan.
    public var previewDepth: Int = 3

    public init() {}

    /// Virtual or duplicated parts of the root file system. Everything on the
    /// Data volume that matters is reachable through firmlinks (/Users,
    /// /Applications, /private …), so /System/Volumes is skipped to avoid
    /// counting it twice.
    public static let defaultExcludedPaths: Set<String> = [
        "/System/Volumes", "/Volumes", "/dev", "/net", "/home",
        "/.vol", "/.nofollow", "/.resolve",
    ]

    func resolvedThreadCount(for path: String) -> Int {
        if let threadCount { return max(1, threadCount) }
        return StorageMedium.detect(path: path).recommendedThreadCount
    }
}

/// Live counters a UI can poll while a scan runs, plus a partial tree preview.
public final class ScanProgress: Sendable {
    private let files = Atomic<Int>(0)
    private let directories = Atomic<Int>(0)
    private let bytes = Atomic<UInt64>(0)
    private let currentPath = Mutex<String>("")
    let preview = PreviewRecorder()

    public init() {}

    public struct Snapshot: Sendable, Equatable {
        public var files: Int
        public var directories: Int
        public var bytes: UInt64
        public var currentPath: String

        public init(files: Int, directories: Int, bytes: UInt64, currentPath: String) {
            self.files = files
            self.directories = directories
            self.bytes = bytes
            self.currentPath = currentPath
        }
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            files: files.load(ordering: .relaxed),
            directories: directories.load(ordering: .relaxed),
            bytes: bytes.load(ordering: .relaxed),
            currentPath: currentPath.withLock { $0 }
        )
    }

    /// A tree containing everything scanned so far down to the preview depth.
    /// Completed directories are the real (now immutable) nodes; directories
    /// still being scanned are stand-ins holding what is known. Safe to call
    /// from any thread while the scan runs.
    public func previewTree() -> RootNode? {
        preview.build()
    }

    func add(files f: Int, bytes b: UInt64, path: String) {
        files.add(f, ordering: .relaxed)
        bytes.add(b, ordering: .relaxed)
        let dirCount = directories.add(1, ordering: .relaxed).newValue
        if dirCount & 31 == 0 {
            currentPath.withLock { $0 = path }
        }
    }
}

/// Records directory listings / completions near the root so a partial tree
/// can be shown while scanning without touching nodes that are still mutating.
final class PreviewRecorder: Sendable {
    struct Listing {
        var entries: [(node: FileNode, isDirectory: Bool)]
        var isRestricted: Bool
    }

    private struct State {
        var root: RootNode?
        var listings: [ObjectIdentifier: Listing] = [:]
        var completed: Set<ObjectIdentifier> = []
    }

    private let state = Mutex(State())

    func start(root: RootNode) {
        state.withLock { $0 = State(root: root) }
    }

    func listed(_ node: FileNode, entries: [(node: FileNode, isDirectory: Bool)], restricted: Bool) {
        state.withLock { $0.listings[ObjectIdentifier(node)] = Listing(entries: entries, isRestricted: restricted) }
    }

    func completed(_ node: FileNode) {
        _ = state.withLock { $0.completed.insert(ObjectIdentifier(node)) }
    }

    func build() -> RootNode? {
        let (root, listings, completed) = state.withLock { ($0.root, $0.listings, $0.completed) }
        guard let root else { return nil }
        if completed.contains(ObjectIdentifier(root)) { return root }
        guard let rootListing = listings[ObjectIdentifier(root)] else { return nil }

        func stand(in node: FileNode, listing: Listing, into proxy: FileNode) {
            var children: [FileNode] = []
            for entry in listing.entries {
                if !entry.isDirectory {
                    children.append(entry.node) // files never change after creation
                } else if completed.contains(ObjectIdentifier(entry.node)) {
                    children.append(entry.node)
                } else if let childListing = listings[ObjectIdentifier(entry.node)] {
                    let childProxy = FileNode(name: entry.node.name, kind: .directory, parent: proxy)
                    stand(in: entry.node, listing: childListing, into: childProxy)
                    children.append(childProxy)
                }
            }
            proxy.children = children
            proxy.kind = listing.isRestricted ? .restricted : .directory
            proxy.finalizeFromChildren()
        }

        let proxyRoot = RootNode(path: root.rootPath, title: root.title)
        stand(in: root, listing: rootListing, into: proxyRoot)
        return proxyRoot
    }
}

public struct ScanResult: Sendable {
    public let root: RootNode
    public let restrictedDirectoryCount: Int
    public let duration: TimeInterval
    public let threadCount: Int
}

public enum ScanError: Error, LocalizedError {
    case cannotOpen(path: String, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case let .cannotOpen(path, code):
            return String(localized: "Cannot read “\(path)”: \(String(cString: strerror(code)))")
        }
    }
}

/// Parallel directory-tree scanner.
///
/// Every directory is a task. A worker lists the directory with
/// `getattrlistbulk`, sums its files, and turns subdirectories into new tasks;
/// one subtask is kept on the same thread (depth-first, cache friendly) and the
/// rest go on a shared stack for other workers. Each task carries an atomic
/// pending counter; when the last child finishes, the directory's size is
/// computed and its children sorted, then the parent is notified. Sizes are
/// therefore aggregated bottom-up as the scan completes, with no second pass.
public struct DiskScanner: Sendable {
    public var options: ScanOptions

    public init(options: ScanOptions = ScanOptions()) {
        self.options = options
    }

    public func scan(path: String, title: String? = nil, progress: ScanProgress = ScanProgress()) async throws -> ScanResult {
        let normalized = Self.normalize(path)
        let engine = ScanEngine(options: options, progress: progress, threadCount: options.resolvedThreadCount(for: normalized))
        let displayTitle = title ?? FileManager.default.displayName(atPath: normalized)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let thread = Thread {
                    continuation.resume(with: Result { try engine.run(rootPath: normalized, title: displayTitle) })
                }
                thread.name = "DiskLens.scan.coordinator"
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        } onCancel: {
            engine.cancel()
        }
    }

    /// Synchronous variant for tests, the command line and the privileged helper.
    public func scanBlocking(path: String, title: String? = nil, progress: ScanProgress = ScanProgress()) throws -> ScanResult {
        let normalized = Self.normalize(path)
        return try ScanEngine(options: options, progress: progress, threadCount: options.resolvedThreadCount(for: normalized))
            .run(rootPath: normalized, title: title ?? FileManager.default.displayName(atPath: normalized))
    }

    /// Lists one directory again (for file-system change events). Existing
    /// subdirectories named in `knownDirectories` are reported by name so the
    /// caller can keep their already scanned contents; new subdirectories are
    /// scanned completely.
    public func relist(path: String, knownDirectories: Set<String>) throws -> Relisting {
        let normalized = Self.normalize(path)
        let reader = BulkDirectoryReader()
        var nodes: [FileNode] = []
        var kept: [String] = []
        var newDirectories: [String] = []
        let base = normalized == "/" ? "" : normalized
        var options = self.options
        options.addVolumeSpaceNodes = false

        let status = reader.read(path: normalized) { entry in
            switch entry.type {
            case .directory:
                if entry.isMountPoint && !options.crossMountPoints { return }
                if options.excludedPaths.contains(base + "/" + entry.name) { return }
                if knownDirectories.contains(entry.name) {
                    kept.append(entry.name)
                } else {
                    newDirectories.append(entry.name)
                }
            default:
                nodes.append(ScanEngine.makeFileNode(entry: entry, options: options, parent: nil, dedup: nil))
            }
        }
        if status != 0 { throw ScanError.cannotOpen(path: normalized, errno: status) }

        for name in newDirectories {
            let childPath = base + "/" + name
            var childOptions = options
            childOptions.threadCount = childOptions.threadCount ?? 2
            if let result = try? DiskScanner(options: childOptions).scanBlocking(path: childPath) {
                let node = FileNode(name: name, kind: PackageDetector.isPackage(name: name) ? .package : .directory, parent: nil)
                node.children = result.root.children
                for child in node.children { child.parent = node }
                node.kind = result.root.kind == .restricted ? .restricted : node.kind
                node.finalizeFromChildren()
                nodes.append(node)
            }
        }
        return Relisting(newNodes: nodes, keptDirectoryNames: Set(kept))
    }

    public struct Relisting: Sendable {
        /// Files and newly found directories (unparented).
        public let newNodes: [FileNode]
        /// Names of directories that still exist and were already known.
        public let keptDirectoryNames: Set<String>
    }

    static func normalize(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

// MARK: - Engine

struct DedupKey: Hashable {
    let dev: Int32
    let id: UInt64
}

/// Hard-link and clone tables shared by all workers of one scan.
final class DedupTable: Sendable {
    private let hardLinks = Mutex<Set<DedupKey>>([])
    private let clones = Mutex<Set<DedupKey>>([])

    func firstHardLink(_ key: DedupKey) -> Bool {
        hardLinks.withLock { $0.insert(key).inserted }
    }

    func firstClone(_ key: DedupKey) -> Bool {
        clones.withLock { $0.insert(key).inserted }
    }
}

private final class DirTask: @unchecked Sendable {
    let node: FileNode
    let path: String
    let parent: DirTask?
    let depth: Int
    /// 1 for this directory's own listing + 1 per child directory task.
    let pending = Atomic<Int>(1)

    init(node: FileNode, path: String, parent: DirTask?, depth: Int) {
        self.node = node
        self.path = path
        self.parent = parent
        self.depth = depth
    }
}

final class ScanEngine: @unchecked Sendable {
    let options: ScanOptions
    let progress: ScanProgress
    let threadCount: Int

    private let condition = NSCondition()
    private var stack: [DirTask] = []       // guarded by condition
    private var finished = false            // guarded by condition
    private let cancelled = Atomic<Bool>(false)
    private let restrictedCount = Atomic<Int>(0)
    private let dedup = DedupTable()
    private let done = DispatchSemaphore(value: 0)

    init(options: ScanOptions, progress: ScanProgress, threadCount: Int) {
        self.options = options
        self.progress = progress
        self.threadCount = threadCount
    }

    func cancel() {
        cancelled.store(true, ordering: .relaxed)
        done.signal()
    }

    func run(rootPath: String, title: String) throws -> ScanResult {
        let start = Date()

        // Fail early with a useful error if the root itself is unreadable.
        let probe = open(rootPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if probe < 0 { throw ScanError.cannotOpen(path: rootPath, errno: errno) }
        close(probe)

        let root = RootNode(path: rootPath, title: title)
        progress.preview.start(root: root)
        let rootTask = DirTask(node: root, path: rootPath, parent: nil, depth: 0)
        stack.append(rootTask)

        let group = DispatchGroup()
        for index in 0..<threadCount {
            group.enter()
            let thread = Thread { [self] in
                worker()
                group.leave()
            }
            thread.name = "DiskLens.scan.worker.\(index)"
            thread.qualityOfService = .userInitiated
            thread.stackSize = 1 << 20
            thread.start()
        }

        done.wait()
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
        group.wait()

        if cancelled.load(ordering: .relaxed) { throw CancellationError() }

        if options.addVolumeSpaceNodes, let space = VolumeSpace.fetch(path: rootPath) {
            let snapshots = APFSSnapshots.snapshotVolumes(forScanOf: rootPath).flatMap(APFSSnapshots.list(volumePath:))
            let purgeable = PurgeableSpace.estimate(volumePath: rootPath)
            root.updateVolumeSpace(space, snapshots: snapshots, purgeable: purgeable)
        }

        return ScanResult(
            root: root,
            restrictedDirectoryCount: restrictedCount.load(ordering: .relaxed),
            duration: Date().timeIntervalSince(start),
            threadCount: threadCount
        )
    }

    // MARK: Workers

    private func worker() {
        // Never download iCloud "dataless" files/directories just to measure them.
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                           IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        let reader = BulkDirectoryReader()
        reader.requestCloneInfo = options.deduplicateClones

        while let task = nextTask() {
            var next: DirTask? = task
            while let current = next {
                if cancelled.load(ordering: .relaxed) { return }
                next = process(current, reader: reader)
            }
        }
    }

    private func nextTask() -> DirTask? {
        condition.lock()
        defer { condition.unlock() }
        while stack.isEmpty && !finished {
            condition.wait()
        }
        if finished { return nil }
        return stack.removeLast()
    }

    static func makeFileNode(entry: BulkEntry, options: ScanOptions, parent: FileNode?, dedup: DedupTable?) -> FileNode {
        var size = options.useAllocatedSize ? entry.allocatedSize : entry.logicalSize
        var flags: FileNode.Flags = entry.isDataless ? [.dataless] : []
        if entry.isDataless && options.countCloudOnlyFiles {
            size = entry.logicalSize
            flags.insert(.cloudOnly)
        }
        if entry.type == .regular, let dedup {
            if entry.linkCount > 1 && !dedup.firstHardLink(DedupKey(dev: entry.devID, id: entry.fileID)) {
                size = 0
                flags.insert(.hardLinkDuplicate)
            } else if options.deduplicateClones && entry.cloneRefCount > 1 && entry.cloneID != 0
                        && !entry.isDataless
                        && !dedup.firstClone(DedupKey(dev: entry.devID, id: entry.cloneID)) {
                size = 0
                flags.insert(.cloneDuplicate)
            }
        }
        let kind: FileNode.Kind = entry.type == .symlink ? .symlink : .file
        return FileNode(name: entry.name, kind: kind, size: size, flags: flags, parent: parent)
    }

    /// Lists one directory. Returns one child task to continue with on this thread.
    private func process(_ task: DirTask, reader: BulkDirectoryReader) -> DirTask? {
        var children: [FileNode] = []
        var subtasks: [DirTask] = []
        var fileBytes: UInt64 = 0
        var fileCount = 0
        let parentNode = task.node
        let basePath = task.path == "/" ? "" : task.path
        let recordPreview = task.depth <= options.previewDepth
        var previewEntries: [(node: FileNode, isDirectory: Bool)] = []

        let status = reader.read(path: task.path) { entry in
            switch entry.type {
            case .directory:
                if entry.isMountPoint && !options.crossMountPoints { return }
                let childPath = basePath + "/" + entry.name
                if options.excludedPaths.contains(childPath) { return }
                let kind: FileNode.Kind = PackageDetector.isPackage(name: entry.name) ? .package : .directory
                let child = FileNode(name: entry.name, kind: kind, parent: parentNode)
                if entry.isDataless { child.flags.insert(.dataless) }
                children.append(child)
                subtasks.append(DirTask(node: child, path: childPath, parent: task, depth: task.depth + 1))
                if recordPreview { previewEntries.append((child, true)) }

            case .regular, .symlink, .other:
                let node = Self.makeFileNode(entry: entry, options: options, parent: parentNode, dedup: dedup)
                children.append(node)
                fileBytes &+= node.size
                fileCount += 1
                if recordPreview { previewEntries.append((node, false)) }
            }
        }

        var restricted = false
        if status == EACCES || status == EPERM {
            parentNode.kind = .restricted
            // EPERM = blocked by macOS privacy protection (TCC/SIP), not by file permissions.
            if status == EPERM { parentNode.flags.insert(.privacyProtected) }
            restricted = true
            restrictedCount.add(1, ordering: .relaxed)
        }

        parentNode.children = children
        progress.add(files: fileCount, bytes: fileBytes, path: task.path)
        if recordPreview {
            progress.preview.listed(parentNode, entries: previewEntries, restricted: restricted)
        }

        var held: DirTask?
        if !subtasks.isEmpty {
            task.pending.add(subtasks.count, ordering: .relaxed)
            held = subtasks.removeLast()
            if !subtasks.isEmpty {
                condition.lock()
                stack.append(contentsOf: subtasks)
                if subtasks.count == 1 { condition.signal() } else { condition.broadcast() }
                condition.unlock()
            }
        }

        complete(task)
        return held
    }

    /// Drops one pending reference; the last one finalizes the directory and
    /// propagates upward.
    private func complete(_ task: DirTask) {
        var current: DirTask? = task
        while let t = current {
            if t.pending.subtract(1, ordering: .acquiringAndReleasing).newValue != 0 { return }
            t.node.finalizeFromChildren()
            if t.depth <= options.previewDepth + 1 {
                progress.preview.completed(t.node)
            }
            guard let parent = t.parent else {
                done.signal()
                return
            }
            current = parent
        }
    }
}

/// Directories that Finder presents as a single document.
enum PackageDetector {
    static let extensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "appex", "xpc", "qlgenerator",
        "mdimporter", "prefpane", "saver", "photoslibrary", "photolibrary", "musiclibrary",
        "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band", "rtfd", "pages",
        "numbers", "key", "sparsebundle", "xcodeproj", "xcworkspace", "xcarchive",
        "playground", "dsym", "docarchive", "workflow", "scptd", "lrdata",
        "vmwarevm", "pvm", "utm",
    ]

    static func isPackage(name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...]
        return extensions.contains(ext.lowercased())
    }
}
