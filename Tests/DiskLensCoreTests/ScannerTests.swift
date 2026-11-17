import Foundation
import Testing
@testable import DiskLensCore

/// Builds a throwaway directory tree for a test and removes it afterwards.
final class TempTree {
    let url: URL
    var path: String { url.path }

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskLensTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func file(_ relative: String, bytes: Int) throws -> URL {
        let fileURL = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Random bytes so APFS cannot compress / dedupe.
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, bytes) }
        }
        try data.write(to: fileURL)
        return fileURL
    }

    func directory(_ relative: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent(relative), withIntermediateDirectories: true)
    }
}

private func logicalScanner(threads: Int = 4) -> DiskScanner {
    var options = ScanOptions()
    options.useAllocatedSize = false
    options.threadCount = threads
    return DiskScanner(options: options)
}

@Suite("Scanner")
struct ScannerTests {
    @Test func sumsLogicalSizesBottomUp() throws {
        let tree = try TempTree()
        try tree.file("a.bin", bytes: 1000)
        try tree.file("sub/b.bin", bytes: 3000)
        try tree.file("sub/deeper/c.bin", bytes: 500)
        try tree.directory("empty")

        let result = try logicalScanner().scanBlocking(path: tree.path)
        let root = result.root

        #expect(root.size == 4500)
        #expect(root.fileCount == 3)
        #expect(root.children.map(\.name) == ["sub", "a.bin", "empty"])

        let sub = try #require(root.children.first)
        #expect(sub.kind == .directory)
        #expect(sub.size == 3500)
        #expect(sub.children.map(\.name) == ["b.bin", "deeper"])
        #expect(sub.children[1].children.first?.parent === sub.children[1])
    }

    @Test func allocatedSizeIsAtLeastLogical() throws {
        let tree = try TempTree()
        try tree.file("x.bin", bytes: 10)
        var options = ScanOptions()
        options.useAllocatedSize = true
        let result = try DiskScanner(options: options).scanBlocking(path: tree.path)
        // A non-empty file occupies at least one allocation block.
        #expect(result.root.size >= 10)
        #expect(result.root.size % 512 == 0)
    }

    @Test func countsHardLinkedDataOnce() throws {
        let tree = try TempTree()
        let original = try tree.file("one/data.bin", bytes: 8000)
        try tree.directory("two")
        try FileManager.default.linkItem(at: original, to: tree.url.appendingPathComponent("two/link.bin"))

        let result = try logicalScanner().scanBlocking(path: tree.path)
        #expect(result.root.size == 8000)
        #expect(result.root.fileCount == 2)

        let all = result.root.children.flatMap(\.children)
        #expect(all.filter { $0.flags.contains(.hardLinkDuplicate) }.count == 1)
        #expect(all.map(\.size).sorted() == [0, 8000])
    }

    @Test func doesNotFollowSymlinks() throws {
        let tree = try TempTree()
        try tree.file("real/big.bin", bytes: 5000)
        try FileManager.default.createSymbolicLink(
            at: tree.url.appendingPathComponent("alias"),
            withDestinationURL: tree.url.appendingPathComponent("real"))

        let result = try logicalScanner().scanBlocking(path: tree.path)
        let alias = try #require(result.root.children.first { $0.name == "alias" })
        #expect(alias.kind == .symlink)
        #expect(alias.children.isEmpty)
        // The symlink's own length is the target path, not 5000.
        #expect(result.root.size < 5000 + 1000)
    }

    @Test func detectsPackages() throws {
        let tree = try TempTree()
        try tree.file("Thing.app/Contents/MacOS/Thing", bytes: 100)
        let result = try logicalScanner().scanBlocking(path: tree.path)
        #expect(result.root.children.first?.kind == .package)
    }

    @Test func handlesWideAndDeepTreesWithManyThreads() throws {
        let tree = try TempTree()
        var expected = 0
        for dir in 0..<40 {
            for file in 0..<5 {
                let size = (dir + 1) * 10 + file
                try tree.file("d\(dir)/nested/n\(dir % 3)/f\(file).bin", bytes: size)
                expected += size
            }
        }
        for threads in [1, 3, 16] {
            let progress = ScanProgress()
            let result = try logicalScanner(threads: threads).scanBlocking(path: tree.path, progress: progress)
            #expect(result.root.size == UInt64(expected))
            #expect(result.root.fileCount == 200)
            #expect(progress.snapshot().files == 200)
            #expect(progress.snapshot().bytes == UInt64(expected))
        }
    }

    @Test func marksUnreadableDirectoriesRestricted() throws {
        let tree = try TempTree()
        try tree.file("open/a.bin", bytes: 100)
        try tree.file("locked/secret.bin", bytes: 100)
        let locked = tree.url.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let result = try logicalScanner().scanBlocking(path: tree.path)
        let node = try #require(result.root.children.first { $0.name == "locked" })
        #expect(node.kind == .restricted)
        #expect(node.size == 0)
        #expect(result.restrictedDirectoryCount == 1)
        #expect(result.root.size == 100)
    }

    @Test func throwsForMissingRoot() {
        #expect(throws: ScanError.self) {
            try logicalScanner().scanBlocking(path: "/nonexistent-\(UUID().uuidString)")
        }
    }

    @Test func asyncScanCanBeCancelled() async throws {
        let tree = try TempTree()
        for i in 0..<50 { try tree.file("d\(i)/f.bin", bytes: 10) }
        let task = Task {
            try await logicalScanner(threads: 2).scan(path: tree.path)
        }
        task.cancel()
        // Either it finished before the cancel landed or it threw CancellationError — never hangs.
        do {
            _ = try await task.value
        } catch is CancellationError {
        }
    }

    @Test func excludedPathsAreSkipped() throws {
        let tree = try TempTree()
        try tree.file("keep/a.bin", bytes: 100)
        try tree.file("skip/b.bin", bytes: 900)
        var options = ScanOptions()
        options.useAllocatedSize = false
        options.excludedPaths = [tree.path + "/skip"]
        let result = try DiskScanner(options: options).scanBlocking(path: tree.path)
        #expect(result.root.size == 100)
        #expect(result.root.children.map(\.name) == ["keep"])
    }
}

@Suite("Tree")
struct TreeTests {
    @Test func pathsAndLookup() throws {
        let tree = try TempTree()
        try tree.file("a/b/c.txt", bytes: 10)
        let root = try logicalScanner().scanBlocking(path: tree.path).root

        let c = try #require(root.node(atPath: tree.path + "/a/b/c.txt"))
        #expect(c.path == tree.path + "/a/b/c.txt")
        #expect(c.lineage.map(\.name) == [root.name, "a", "b", "c.txt"])
        #expect(c.isDescendant(of: root))
        #expect(root.node(atPath: tree.path) === root)
        #expect(root.node(atPath: tree.path + "/a/zzz") == nil)
        #expect(root.node(atPath: "/elsewhere") == nil)
    }

    @Test func detachUpdatesAncestorsAndOrder() throws {
        let tree = try TempTree()
        try tree.file("big/x.bin", bytes: 6000)
        try tree.file("big/y.bin", bytes: 1000)
        try tree.file("mid/z.bin", bytes: 4000)
        let root = try logicalScanner().scanBlocking(path: tree.path).root
        #expect(root.children.map(\.name) == ["big", "mid"])

        let x = try #require(root.node(atPath: tree.path + "/big/x.bin"))
        x.detach()

        #expect(x.parent == nil)
        #expect(root.size == 5000)
        #expect(root.fileCount == 2)
        #expect(root.children.map(\.name) == ["mid", "big"])
        #expect(root.children[1].size == 1000)
    }

    @Test func specialNodesSortLast() {
        let root = RootNode(path: "/x", title: "X")
        let free = FileNode(name: "Free space", kind: .freeSpace, size: 9_999, parent: root)
        let hidden = FileNode(name: "Hidden space", kind: .hiddenSpace, size: 5, parent: root)
        let small = FileNode(name: "small", kind: .file, size: 1, parent: root)
        let big = FileNode(name: "big", kind: .file, size: 100, parent: root)
        root.children = [free, small, hidden, big]
        root.finalizeFromChildren()
        #expect(root.children.map(\.name) == ["big", "small", "Hidden space", "Free space"])
    }

    @Test func detachCanReclaimIntoFreeSpace() {
        let root = RootNode(path: "/x", title: "X")
        let file = FileNode(name: "f", kind: .file, size: 100, parent: root)
        let free = FileNode(name: "Free space", kind: .freeSpace, size: 50, parent: root)
        root.children = [file, free]
        root.finalizeFromChildren()
        #expect(root.size == 150)

        file.detach(reclaimToFreeSpace: true)
        #expect(free.size == 150)
        #expect(root.size == 150)
    }
}
