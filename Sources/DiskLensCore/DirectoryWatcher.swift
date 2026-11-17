import CoreServices
import Foundation

/// FSEvents wrapper: reports directories whose contents changed below a root.
public final class DirectoryWatcher: @unchecked Sendable {
    public struct Change: Sendable, Hashable {
        public let path: String
        /// The kernel dropped events; the whole subtree must be rescanned.
        public let mustScanSubdirectories: Bool

        public init(path: String, mustScanSubdirectories: Bool) {
            self.path = path
            self.mustScanSubdirectories = mustScanSubdirectories
        }
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "DiskLens.watcher")
    private let handler: @Sendable ([Change]) -> Void

    public init(path: String, latency: TimeInterval = 2.0, handler: @escaping @Sendable ([Change]) -> Void) {
        self.handler = handler

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            // With kFSEventStreamCreateFlagUseCFTypes, `paths` is a CFArray of CFStrings.
            let cfPaths = Unmanaged<NSArray>.fromOpaque(paths).takeUnretainedValue()
            var changes: [Change] = []
            for index in 0..<count {
                guard let path = cfPaths[index] as? String else { continue }
                let flag = flags[index]
                let rescan = flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
                    || flag & UInt32(kFSEventStreamEventFlagUserDropped) != 0
                    || flag & UInt32(kFSEventStreamEventFlagKernelDropped) != 0
                let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
                changes.append(Change(path: trimmed, mustScanSubdirectories: rescan))
            }
            if !changes.isEmpty { watcher.handler(changes) }
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot
                                     | kFSEventStreamCreateFlagUseCFTypes))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
