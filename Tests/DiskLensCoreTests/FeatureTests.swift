import Foundation
import Synchronization
import Testing
@testable import DiskLensCore

private func scanner(allocated: Bool = false, clones: Bool = true) -> DiskScanner {
    var options = ScanOptions()
    options.useAllocatedSize = allocated
    options.deduplicateClones = clones
    options.threadCount = 4
    return DiskScanner(options: options)
}

@Suite("Clones")
struct CloneTests {
    @Test func apfsClonesAreCountedOnce() throws {
        let tree = try TempTree()
        let original = try tree.file("a/original.bin", bytes: 200_000)
        try tree.directory("b")
        let cloneURL = tree.url.appendingPathComponent("b/clone.bin")
        // copyfile with COPYFILE_CLONE makes an APFS clone (same as `cp -c`).
        let status = copyfile(original.path, cloneURL.path, nil, copyfile_flags_t(COPYFILE_CLONE_FORCE))
        try #require(status == 0, "clonefile not supported on this volume")

        let deduped = try scanner(allocated: true).scanBlocking(path: tree.path).root
        let naive = try scanner(allocated: true, clones: false).scanBlocking(path: tree.path).root

        let all = deduped.children.flatMap(\.children)
        #expect(all.filter { $0.flags.contains(.cloneDuplicate) }.count == 1)
        #expect(deduped.size * 2 == naive.size)
    }
}

@Suite("Archive")
struct ArchiveTests {
    @Test func roundTripsTrees() throws {
        let tree = try TempTree()
        try tree.file("x/y/z.bin", bytes: 1234)
        try tree.file("x/w.bin", bytes: 10)
        try tree.file("Thing.app/Contents/bin", bytes: 77)
        let root = try scanner().scanBlocking(path: tree.path).root

        let data = try TreeArchive.encode([(path: tree.path, root: root, restrictedCount: 3)])
        let entries = try TreeArchive.decode(data)
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.path == tree.path)
        #expect(entry.restrictedCount == 3)
        #expect(entry.children.map(\.name) == root.children.map(\.name))
        #expect(entry.children.map(\.size) == root.children.map(\.size))
        let x = try #require(entry.children.first { $0.name == "x" })
        #expect(x.size == 1244)
        #expect(x.children.first?.parent === x)
        #expect(entry.children.contains { $0.kind == .package })
    }

    @Test func rejectsGarbage() {
        #expect(throws: (any Error).self) { try TreeArchive.decode(Data([1, 2, 3])) }
    }
}

@Suite("Grafting")
struct GraftTests {
    @Test func replaceContentsUpdatesAncestors() throws {
        let tree = try TempTree()
        try tree.file("a/old.bin", bytes: 100)
        try tree.file("b/keep.bin", bytes: 500)
        let root = try scanner().scanBlocking(path: tree.path).root
        let a = try #require(root.node(atPath: tree.path + "/a"))

        let replacement = FileNode(name: "new.bin", kind: .file, size: 900, parent: nil)
        a.replaceContents(with: [replacement], kind: .directory)

        #expect(a.size == 900)
        #expect(replacement.parent === a)
        #expect(root.size == 1400)
        #expect(root.children.map(\.name) == ["a", "b"])
    }

    @Test func relistKeepsKnownDirectoriesAndScansNewOnes() throws {
        let tree = try TempTree()
        try tree.file("known/k.bin", bytes: 10)
        try tree.file("fresh/f.bin", bytes: 20)
        try tree.file("top.bin", bytes: 30)
        let relisting = try scanner().relist(path: tree.path, knownDirectories: ["known", "gone"])

        #expect(relisting.keptDirectoryNames == ["known"])
        let names = Set(relisting.newNodes.map(\.name))
        #expect(names == ["fresh", "top.bin"])
        #expect(relisting.newNodes.first { $0.name == "fresh" }?.size == 20)
    }

    @Test func restrictedDescendantsAreFound() throws {
        let tree = try TempTree()
        try tree.file("open/x.bin", bytes: 1)
        try tree.file("deep/locked/y.bin", bytes: 1)
        let locked = tree.url.appendingPathComponent("deep/locked")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let root = try scanner().scanBlocking(path: tree.path).root
        #expect(root.restrictedDescendants().map(\.path) == [locked.path])
    }

    @Test func nearestNodeStopsAtDeepestExisting() throws {
        let tree = try TempTree()
        try tree.file("a/b/c.bin", bytes: 1)
        let root = try scanner().scanBlocking(path: tree.path).root
        #expect(root.nearestNode(toPath: tree.path + "/a/b/new/deeper")?.name == "b")
        #expect(root.nearestNode(toPath: "/elsewhere") == nil)
    }
}

@Suite("Preview")
struct PreviewTests {
    @Test func previewOfFinishedScanIsTheRealTree() throws {
        let tree = try TempTree()
        try tree.file("a/b.bin", bytes: 10)
        let progress = ScanProgress()
        let result = try scanner().scanBlocking(path: tree.path, progress: progress)
        #expect(progress.previewTree() === result.root)
    }

    @Test func partialPreviewUsesCompletedSubtrees() {
        let recorder = PreviewRecorder()
        let root = RootNode(path: "/p", title: "P")
        let done = FileNode(name: "done", kind: .directory, parent: root)
        done.children = [FileNode(name: "f", kind: .file, size: 40, parent: done)]
        done.finalizeFromChildren()
        let busy = FileNode(name: "busy", kind: .directory, parent: root)
        let busyFile = FileNode(name: "g", kind: .file, size: 5, parent: busy)
        let unlisted = FileNode(name: "later", kind: .directory, parent: busy)
        let file = FileNode(name: "top", kind: .file, size: 1, parent: root)

        recorder.start(root: root)
        recorder.listed(root, entries: [(done, true), (busy, true), (file, false)], restricted: false)
        recorder.completed(done)
        recorder.listed(busy, entries: [(busyFile, false), (unlisted, true)], restricted: false)

        let preview = recorder.build()
        #expect(preview != nil)
        #expect(preview !== root)
        #expect(preview?.size == 46)
        #expect(preview?.children.first === done)
        let busyProxy = preview?.children.first { $0.name == "busy" }
        #expect(busyProxy !== busy)
        #expect(busyProxy?.children.map(\.name) == ["g"])
    }
}

@Suite("Hidden space")
struct HiddenSpaceTests {
    @Test func breakdownSumsToCapacity() {
        let root = RootNode(path: "/vol", title: "Vol")
        root.children = [FileNode(name: "data", kind: .file, size: 600, parent: root)]
        root.finalizeFromChildren()
        let snapshot = SnapshotInfo(name: "com.apple.TimeMachine.2026-01-01-120000.local", xid: 7,
                                    volumePath: "/vol", created: nil, size: 50)
        let space = VolumeSpace(total: 1000, available: 200, availableForImportantUsage: 300)
        root.updateVolumeSpace(space, snapshots: [snapshot], purgeable: 100)

        #expect(root.size == 1000)
        let hidden = root.children.first { $0.kind == .hiddenSpace }
        #expect(hidden?.size == 200)
        #expect(hidden?.children.first { $0.kind == .snapshotGroup }?.size == 50)
        #expect(hidden?.children.first { $0.kind == .purgeable }?.size == 100)
        #expect(hidden?.children.first { $0.kind == .otherHidden }?.size == 50)
        #expect(root.children.last?.kind == .freeSpace)
        #expect(hidden?.canDrillDown == true)
    }

    @Test func snapshotNaming() {
        let tm = SnapshotInfo(name: "com.apple.TimeMachine.2026-11-08-165915.local", xid: 1, volumePath: "/", created: nil, size: nil)
        #expect(tm.timeMachineDate == "2026-11-08-165915")
        #expect(tm.deletionCommand == ["/usr/bin/tmutil", "deletelocalsnapshots", "2026-11-08-165915"])
        let other = SnapshotInfo(name: "com.bombich.ccc.123", xid: 99, volumePath: "/Volumes/X", created: nil, size: nil)
        #expect(other.isThirdParty)
        #expect(other.deletionCommand == ["/usr/sbin/diskutil", "apfs", "deleteSnapshot", "/Volumes/X", "-xid", "99"])
    }

    @Test func systemQueriesDoNotCrash() {
        _ = APFSSnapshots.list(volumePath: "/System/Volumes/Data")
        #expect(PurgeableSpace.estimate(volumePath: "/") != nil)
        #expect(StorageMedium.detect(path: "/") == .solidState)
        #expect(StorageMedium.detect(path: "/nonexistent-path-xyz") == .unknown)
    }
}

@Suite("Privileged helper")
struct PrivilegedHelperTests {
    /// Runs the helper side in-process (as the current user) to check the
    /// request → scan → archive → response round trip.
    @Test func scanRequestProducesArchive() throws {
        let tree = try TempTree()
        try tree.file("secret/a.bin", bytes: 4096)
        let work = try TempTree()
        var request = Privileged.Request(command: .scan)
        request.paths = [tree.path + "/secret", tree.path + "/missing"]
        request.useAllocatedSize = false
        let requestPath = work.path + "/request.json"
        try JSONEncoder().encode(request).write(to: URL(fileURLWithPath: requestPath))

        #expect(Privileged.runHelper(requestPath: requestPath) == 0)

        let response = try JSONDecoder().decode(Privileged.Response.self,
                                                from: Data(contentsOf: URL(fileURLWithPath: work.path + "/response.json")))
        // A folder that disappeared since the scan is skipped, not reported as an error.
        #expect(response.failures.isEmpty)
        let archive = try #require(response.archiveFile)
        let entries = try TreeArchive.decode(Data(contentsOf: URL(fileURLWithPath: archive)))
        #expect(entries.count == 1)
        #expect(entries.first?.children.first?.size == 4096)
    }

    @Test func refusesArbitrarySnapshotCommands() throws {
        let work = try TempTree()
        var request = Privileged.Request(command: .deleteSnapshots)
        request.commands = [["/bin/rm", "-rf", "/tmp/nothing"]]
        let requestPath = work.path + "/request.json"
        try JSONEncoder().encode(request).write(to: URL(fileURLWithPath: requestPath))
        _ = Privileged.runHelper(requestPath: requestPath)
        let response = try JSONDecoder().decode(Privileged.Response.self,
                                                from: Data(contentsOf: URL(fileURLWithPath: work.path + "/response.json")))
        #expect(response.failures.values.contains("command not allowed"))
    }

    @Test func appleScriptQuoting() {
        #expect(Privileged.appleScriptString(#"a "b" \c"#) == #""a \"b\" \\c""#)
    }
}

@Suite("Watcher")
struct WatcherTests {
    @Test func reportsChangedDirectory() async throws {
        let tree = try TempTree()
        try tree.directory("sub")
        let received = Mutex<[String]>([])
        let watcher = DirectoryWatcher(path: tree.path, latency: 0.1) { changes in
            received.withLock { $0.append(contentsOf: changes.map(\.path)) }
        }
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))
        try tree.file("sub/new.bin", bytes: 10)
        for _ in 0..<50 {
            if received.withLock({ $0.contains { $0.hasSuffix("/sub") } }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(received.withLock { $0.contains { $0.hasSuffix("/sub") } })
    }
}

@Suite("Privacy protection")
struct PrivacyProtectionTests {
    @Test func permissionDeniedIsNotPrivacyProtected() throws {
        let tree = try TempTree()
        try tree.file("locked/x.bin", bytes: 1)
        let locked = tree.url.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let root = try DiskScanner().scanBlocking(path: tree.path).root
        #expect(root.adminReadableRestrictedDescendants().count == 1)
        #expect(root.privacyProtectedDescendants().isEmpty)
    }

    /// ~/.Trash is TCC protected unless the test runner has Full Disk Access.
    /// The helper must report it as protected, not as a failure.
    @Test func helperReportsPrivacyProtectedPathsSeparately() throws {
        let trash = NSHomeDirectory() + "/.Trash"
        let fd = open(trash, O_RDONLY | O_DIRECTORY)
        let code = errno
        if fd >= 0 { close(fd) }
        try #require(fd < 0 && code == EPERM, "~/.Trash is readable here (Full Disk Access); nothing to check")

        let work = try TempTree()
        var request = Privileged.Request(command: .scan)
        request.paths = [trash]
        let requestPath = work.path + "/request.json"
        try JSONEncoder().encode(request).write(to: URL(fileURLWithPath: requestPath))
        _ = Privileged.runHelper(requestPath: requestPath)
        let response = try JSONDecoder().decode(Privileged.Response.self,
                                                from: Data(contentsOf: URL(fileURLWithPath: work.path + "/response.json")))
        #expect(response.protectedPaths == [trash])
        #expect(response.failures.isEmpty)
    }

    @Test func markPrivacyProtectedMovesNodeOutOfAdminList() {
        let root = RootNode(path: "/r", title: "R")
        let dir = FileNode(name: "d", kind: .restricted, parent: root)
        root.children = [dir]
        #expect(root.adminReadableRestrictedDescendants().count == 1)
        dir.markPrivacyProtected()
        #expect(root.adminReadableRestrictedDescendants().isEmpty)
        #expect(root.privacyProtectedDescendants().count == 1)
    }
}

@Suite("Stale nodes")
struct StaleNodeTests {
    /// Reproduces the "Users shows 255 GB but its children add up to 300 MB"
    /// class of bug: an operation finishing on a node that was replaced in the
    /// meantime must not change the live tree.
    @Test func replacedNodeCannotCorruptAncestors() throws {
        let tree = try TempTree()
        try tree.file("home/big.bin", bytes: 9000)
        try tree.file("shared/s.bin", bytes: 100)
        let root = try DiskScanner().scanBlocking(path: tree.path).root
        let staleHome = try #require(root.node(atPath: tree.path + "/home"))

        // A rescan of the parent replaces "home" with a fresh node…
        let fresh = FileNode(name: "home", kind: .directory, parent: nil)
        fresh.replaceContents(with: [FileNode(name: "big.bin", kind: .file, size: 9000, parent: nil)])
        let shared = try #require(root.node(atPath: tree.path + "/shared"))
        root.replaceContents(with: [fresh, shared])
        let sizeAfterRescan = root.size

        // …then a late operation lands on the old node.
        staleHome.replaceContents(with: [])
        staleHome.detach()

        #expect(root.size == sizeAfterRescan)
        #expect(root.children.contains { $0 === fresh })
        #expect(root.size == root.children.reduce(0) { $0 + $1.size })
        #expect(!staleHome.isAttached(to: root))
        #expect(fresh.isAttached(to: root))
    }
}

@Suite("System Data")
struct SystemDataTests {
    @Test func catalogOnlyListsExistingFolders() throws {
        let home = try TempTree()
        try home.file("Library/Caches/com.example/blob", bytes: 10)
        try home.file("Library/Developer/Xcode/DerivedData/App-abc/Build/x", bytes: 10)
        let kinds = Set(SystemDataCatalog.categories(home: home.path).map(\.kind))
        #expect(kinds.contains(.userCaches))
        #expect(kinds.contains(.xcodeDerivedData))
        #expect(kinds.contains(.purgeable))          // not tied to a folder
        #expect(!kinds.contains(.userLogs))          // folder doesn't exist
        #expect(!kinds.contains(.npmCache))
    }

    @Test func safetyLevels() throws {
        let home = try TempTree()
        try home.directory("Library/Caches")
        try home.directory("Library/Developer/Xcode/Archives")
        let categories = SystemDataCatalog.categories(home: home.path)
        #expect(categories.first { $0.kind == .userCaches }?.safety == .safe)
        #expect(categories.first { $0.kind == .xcodeArchives }?.safety == .review)
        #expect(categories.first { $0.kind == .xcodeArchives }?.method == .trashContents)
    }

    @Test func deleteContentsKeepsTheFolder() async throws {
        let home = try TempTree()
        try home.file("Library/Caches/a/1.bin", bytes: 100)
        try home.file("Library/Caches/b.bin", bytes: 100)
        let category = try #require(SystemDataCatalog.categories(home: home.path).first { $0.kind == .userCaches })

        #expect(SystemDataCleaner.contents(of: category).count == 2)
        let outcome = await SystemDataCleaner.clean(category)
        #expect(outcome.failures.isEmpty)
        let caches = home.path + "/Library/Caches"
        #expect(FileManager.default.fileExists(atPath: caches))
        #expect(try FileManager.default.contentsOfDirectory(atPath: caches).isEmpty)
    }

    @Test func failingCommandIsReported() async {
        let category = CleanupCategory(kind: .condaPackages, safety: .review, method: .command(["/usr/bin/false"]), paths: [])
        let outcome = await SystemDataCleaner.clean(category)
        #expect(outcome.failures.count == 1)
    }
}

@Suite("Virtual groups")
struct VirtualGroupTests {
    @Test func nestedGroupRefreshDropsRemovedItems() throws {
        let tree = try TempTree()
        try tree.file("caches/a.bin", bytes: 300)
        try tree.file("logs/b.bin", bytes: 200)
        let root = try DiskScanner().scanBlocking(path: tree.path).root
        let caches = try #require(root.node(atPath: tree.path + "/caches"))
        let logs = try #require(root.node(atPath: tree.path + "/logs"))

        let group = FileNode.makeNestedGroup(named: "System Data",
                                             groups: [("Caches", [caches]), ("Logs", [logs])], parent: root)
        #expect(group.size == caches.size + logs.size)
        #expect(group.children.count == 2)

        logs.detach()
        #expect(group.refreshGroup(in: root))
        #expect(group.children.map(\.name) == ["Caches"])
        #expect(group.size == caches.size)
        // Items keep their real parent; the group doesn't adopt them.
        #expect(caches.parent === root)

        caches.detach()
        #expect(!group.refreshGroup(in: root))
    }
}

@Suite("Best-effort cleanup")
struct BestEffortCleanupTests {
    /// A cache folder with one undeletable part: everything else is removed and
    /// the protected part is reported as protected, not as a failure.
    @Test func deletesAroundProtectedItems() async throws {
        let home = try TempTree()
        try home.file("Library/Caches/app/big.bin", bytes: 1000)
        try home.file("Library/Caches/app/locked/keep.bin", bytes: 10)
        try home.file("Library/Caches/other.bin", bytes: 10)
        let locked = home.path + "/Library/Caches/app/locked"
        // Read-only folder: its file can't be unlinked (EACCES).
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }

        let category = try #require(SystemDataCatalog.categories(home: home.path).first { $0.kind == .userCaches })
        let outcome = await SystemDataCleaner.clean(category)

        #expect(outcome.failures.isEmpty)
        #expect(outcome.protectedPaths == [locked + "/keep.bin"])
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: home.path + "/Library/Caches/other.bin"))
        #expect(!fm.fileExists(atPath: home.path + "/Library/Caches/app/big.bin"))
        #expect(fm.fileExists(atPath: locked + "/keep.bin"))
    }
}
