import AppKit
import DiskLensCore
import Observation
import SwiftUI

enum ScanTarget: Equatable {
    case volume(VolumeInfo)
    case folder(URL)
    /// A synced cloud folder; cloud-only files are counted by their logical size.
    case cloud(CloudFolder)

    var path: String {
        switch self {
        case let .volume(volume): return volume.path
        case let .folder(url): return url.path
        case let .cloud(folder): return folder.url.path
        }
    }

    var title: String {
        switch self {
        case let .volume(volume): return volume.name
        case let .folder(url): return FileManager.default.displayName(atPath: url.path)
        case let .cloud(folder): return folder.name
        }
    }
}

/// How the wheel should animate to a new focus.
enum FocusTransition: Equatable {
    case blossom
    /// Zooming into a slice that occupied `start…start+span` on `ring` of the previous wheel.
    case zoomIn(start: Double, span: Double, ring: Int)
    /// Zooming out; the previous center now occupies `start…start+span` on `ring`.
    case zoomOut(start: Double, span: Double, ring: Int)
}

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case home
        case scanning
        case results
    }

    // MARK: State

    private(set) var phase: Phase = .home
    private(set) var volumes: [VolumeInfo] = []
    private(set) var cloudFolders: [CloudFolder] = []
    private(set) var target: ScanTarget?

    // Scanning
    private(set) var progress = ScanProgress.Snapshot(files: 0, directories: 0, bytes: 0, currentPath: "")
    private(set) var scanStartedAt = Date()
    private(set) var previewLayout: SunburstLayout?
    private(set) var previewGeneration = 0
    private(set) var scanMedium: StorageMedium = .unknown
    private var scanTask: Task<Void, Never>?
    private var progressTimer: Timer?
    private var previewTick = 0

    // Results
    private(set) var root: RootNode?
    private(set) var focus: FileNode?
    private(set) var layout: SunburstLayout?
    /// Bumped when the focus changes (wheel animates).
    private(set) var focusGeneration = 0
    private(set) var transition: FocusTransition = .blossom
    /// Bumped when the tree content changes in place (deletions, rescans, file-system changes).
    private(set) var treeGeneration = 0
    private(set) var restrictedCount = 0
    private(set) var scanDuration: TimeInterval = 0
    private(set) var colors: [ObjectIdentifier: NSColor] = [:]

    var hovered: FileNode?
    var selection: Set<ObjectIdentifier> = []

    // Collector
    private(set) var collected: [FileNode] = []

    // Background work shown in the UI
    private(set) var activity: String?

    // Alerts
    var errorMessage: String?
    var infoMessage: String?

    // Settings (persisted)
    var useAllocatedSize: Bool {
        didSet { UserDefaults.standard.set(useAllocatedSize, forKey: "useAllocatedSize") }
    }
    var deduplicateClones: Bool {
        didSet { UserDefaults.standard.set(deduplicateClones, forKey: "deduplicateClones") }
    }
    var autoRefresh: Bool {
        didSet {
            UserDefaults.standard.set(autoRefresh, forKey: "autoRefresh")
            restartWatcher()
        }
    }

    private var watcher: DirectoryWatcher?
    private var pendingChanges: Set<DirectoryWatcher.Change> = []
    private var changeTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["useAllocatedSize": true, "deduplicateClones": true, "autoRefresh": true])
        useAllocatedSize = defaults.bool(forKey: "useAllocatedSize")
        deduplicateClones = defaults.bool(forKey: "deduplicateClones")
        autoRefresh = defaults.bool(forKey: "autoRefresh")

        refreshVolumes()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolumes() }
            }
        }

        // `DiskLens --scan <folder>` opens straight into a scan.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--scan"), index + 1 < arguments.count {
            let url = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath)
            if let volume = volumes.first(where: { $0.path == url.path }) {
                scan(.volume(volume))
            } else {
                scan(.folder(url))
            }
        }
    }

    // MARK: Volumes

    func refreshVolumes() {
        volumes = VolumeInfo.mountedVolumes()
        cloudFolders = CloudFolder.discover()
    }

    func eject(_ volume: VolumeInfo) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: volume.path))
            refreshVolumes()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Scanning

    func chooseFolderAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Scan")
        panel.message = String(localized: "Choose a folder to scan")
        if panel.runModal() == .OK, let url = panel.url {
            scan(.folder(url))
        }
    }

    private func scanOptions(for target: ScanTarget) -> ScanOptions {
        var options = ScanOptions()
        options.useAllocatedSize = useAllocatedSize
        options.deduplicateClones = deduplicateClones
        switch target {
        case .volume: options.addVolumeSpaceNodes = true
        case .cloud: options.countCloudOnlyFiles = true
        case .folder: break
        }
        return options
    }

    func scan(_ target: ScanTarget) {
        cancelScan()
        stopWatcher()
        self.target = target
        resetResults()
        phase = .scanning
        scanStartedAt = Date()
        previewLayout = nil
        previewTick = 0

        let progress = ScanProgress()
        self.progress = progress.snapshot()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickProgress(progress) }
        }

        let scanner = DiskScanner(options: scanOptions(for: target))
        let path = target.path
        let title = target.title
        scanMedium = .unknown
        Task.detached { [weak self] in
            let medium = StorageMedium.detect(path: path)
            await MainActor.run { self?.scanMedium = medium }
        }

        scanTask = Task { [weak self] in
            do {
                let result = try await scanner.scan(path: path, title: title, progress: progress)
                self?.finishScan(result)
            } catch is CancellationError {
                // cancelScan() already reset the UI.
            } catch {
                self?.failScan(error)
            }
        }
    }

    private func tickProgress(_ progress: ScanProgress) {
        self.progress = progress.snapshot()
        previewTick += 1
        // Rebuild the live wheel twice a second.
        if previewTick % 5 == 1, let preview = progress.previewTree() {
            previewLayout = SunburstLayout(center: preview, maxRings: 5)
            previewGeneration += 1
        }
    }

    func rescan() {
        guard let target else { return }
        if case let .volume(volume) = target,
           let fresh = VolumeInfo.mountedVolumes().first(where: { $0.path == volume.path }) {
            scan(.volume(fresh))
        } else {
            scan(target)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        progressTimer?.invalidate()
        progressTimer = nil
        if phase == .scanning { phase = root == nil ? .home : .results }
    }

    func showHome() {
        cancelScan()
        stopWatcher()
        resetResults()
        target = nil
        phase = .home
        refreshVolumes()
    }

    private func finishScan(_ result: ScanResult) {
        progressTimer?.invalidate()
        progressTimer = nil
        progress = ScanProgress.Snapshot(files: result.root.fileCount, directories: progress.directories,
                                         bytes: result.root.size, currentPath: "")
        root = result.root
        rebuildRestrictedList()
        scanDuration = result.duration
        phase = .results
        previewLayout = nil
        setFocus(result.root, transition: .blossom)
        restartWatcher()
        if result.root.volumeSpace != nil {
            Task { await measureSystemData() }
        }
        applyDebugFocus()
        // Debug aid: `--debug-event <path>[:deep]` simulates an FSEvents change.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--debug-event"), index + 1 < arguments.count {
            let value = arguments[index + 1]
            let deep = value.hasSuffix(":deep")
            enqueue([DirectoryWatcher.Change(path: deep ? String(value.dropLast(5)) : value, mustScanSubdirectories: deep)])
        }
        if let i = arguments.firstIndex(of: "--debug-sheet"), i + 1 < arguments.count {
            if arguments[i + 1] == "system-data" { showSystemData() }
            if arguments[i + 1] == "system-data-wheel" {
                Task { await measureSystemData(); showSystemDataInWheel() }
            }
        }
        // Debug aid: `--debug-rescan focus` rescans the focused folder right away.
        if let i = arguments.firstIndex(of: "--debug-rescan"), i + 1 < arguments.count, arguments[i + 1] == "focus", let focus { rescan(focus) }
    }

    /// Debug aid: `--debug-focus "Hidden space/APFS snapshots"` opens a node by display names.
    private func applyDebugFocus() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--debug-focus"), index + 1 < arguments.count, var node = root as FileNode? else { return }
        for name in arguments[index + 1].split(separator: "/") {
            if name == "*smaller*" {
                openSmallerItems(of: node)
                return
            }
            guard let next = node.children.first(where: { $0.displayName == name }) else { break }
            node = next
        }
        if node !== root { setFocus(node) }
    }

    private func failScan(_ error: Error) {
        progressTimer?.invalidate()
        progressTimer = nil
        phase = .home
        errorMessage = error.localizedDescription
    }

    private func resetResults() {
        root = nil
        focus = nil
        layout = nil
        hovered = nil
        selection = []
        collected = []
        colors = [:]
        restrictedCount = 0
        adminRestrictedCount = 0
        protectedCount = 0
    }

    // MARK: Navigation

    func setFocus(_ node: FileNode, transition requested: FocusTransition? = nil) {
        guard node.isContainer || node.isRoot else { return }
        let previous = focus
        let previousLayout = layout
        focus = node
        hovered = nil
        selection = []
        rebuildLayout()

        if let requested {
            transition = requested
        } else if let previous, let previousLayout, node.parent === previous,
                  let index = previousLayout.segmentIndex(for: node) {
            let segment = previousLayout.segments[index]
            transition = .zoomIn(start: segment.start, span: segment.span, ring: segment.ring)
        } else if let previous, let layout, previous.parent === node,
                  let index = layout.segmentIndex(for: previous) {
            let segment = layout.segments[index]
            transition = .zoomOut(start: segment.start, span: segment.span, ring: segment.ring)
        } else {
            transition = .blossom
        }
        focusGeneration += 1
    }

    func drillDown(_ node: FileNode) {
        if node.canDrillDown { setFocus(node) }
    }

    func goUp() {
        guard let focus, let parent = focus.parent else { return }
        setFocus(parent)
    }

    var canGoUp: Bool { focus?.parent != nil }

    /// Opens the "Smaller items" slice of `parent` as a virtual folder.
    func openSmallerItems(of parent: FileNode) {
        let shown = Set((layout?.segments ?? []).compactMap { $0.node.map(ObjectIdentifier.init) })
        let items = parent.children.filter { !$0.isSpecial && $0.size > 0 && !shown.contains(ObjectIdentifier($0)) }
        guard !items.isEmpty else { return }
        let group = FileNode.makeGroup(named: String(localized: "Smaller items"), items: items, parent: parent)
        if let layout, let index = layout.segments.firstIndex(where: {
            if case let .smallerItems(p, _, _) = $0.content { return p === parent }
            return false
        }) {
            let segment = layout.segments[index]
            setFocus(group, transition: .zoomIn(start: segment.start, span: segment.span, ring: segment.ring))
        } else {
            setFocus(group)
        }
    }

    private func rebuildLayout() {
        guard let focus else {
            layout = nil
            colors = [:]
            return
        }
        let newLayout = SunburstLayout(center: focus)
        layout = newLayout
        var map: [ObjectIdentifier: NSColor] = [:]
        for segment in newLayout.segments where segment.ring == 0 {
            if let node = segment.node {
                map[ObjectIdentifier(node)] = Palette.color(for: segment)
            }
        }
        colors = map
    }

    /// The tree changed in place: refresh layout and dependent UI, keep the focus valid.
    /// - Parameter rebuilt: subtrees that were replaced or newly scanned; only
    ///   these are searched for unreadable folders (never the whole tree).
    private func treeDidChange(rebuilt: [FileNode] = []) {
        // A rescan may have replaced the focused folder with a fresh node: follow it by path.
        if let focus, let root, focus !== root, focus.kind != .group, !focus.isAttached(to: root),
           let path = focus.path, let fresh = root.node(atPath: path), fresh.isContainer {
            self.focus = fresh
        }
        if let focus, let root, focus !== root, focus.kind != .group, !(focus.isDescendant(of: root)) {
            // The focus was removed (or it was a virtual group that went stale).
            var fallback: FileNode? = focus.parent
            while let candidate = fallback, candidate !== root, !candidate.isDescendant(of: root) {
                fallback = candidate.parent
            }
            self.focus = fallback ?? root
        }
        // Virtual groups (Smaller items, System Data) stay open; they are refreshed
        // in place and only left when nothing in them remains.
        if let focus, let root, focus.kind == .group {
            var top = focus
            while let parent = top.parent, parent.kind == .group { top = parent }
            if !top.refreshGroup(in: root) || focus.children.isEmpty {
                var fallback: FileNode? = top.parent
                while let candidate = fallback, candidate !== root, !candidate.isAttached(to: root) {
                    fallback = candidate.parent
                }
                self.focus = fallback ?? root
            }
        }
        if let hovered, let root, hovered !== root, !hovered.isDescendant(of: root) { self.hovered = nil }
        collected.removeAll { node in
            guard let root else { return true }
            return node !== root && !node.isDescendant(of: root)
        }
        noteRebuilt(rebuilt)
        rebuildLayout()
        treeGeneration += 1
    }

    func color(for node: FileNode) -> NSColor {
        colors[ObjectIdentifier(node)] ?? Palette.smallerItemsColor
    }

    // MARK: Rescanning parts of the tree

    /// Scans one folder again and splices the result into the tree.
    func rescan(_ node: FileNode) {
        guard let path = node.path, node.isContainer else { return }
        if node.isRoot {
            rescan()
            return
        }
        var options = target.map(scanOptions(for:)) ?? ScanOptions()
        options.addVolumeSpaceNodes = false
        let scanner = DiskScanner(options: options)
        activity = String(localized: "Rescanning “\(node.displayName)”…")
        Task {
            defer { activity = nil }
            do {
                let result = try await scanner.scan(path: path)
                // The tree may have changed while scanning; never write into a detached node.
                guard let root = self.root, node.isAttached(to: root) else { return }
                node.replaceContents(with: result.root.children,
                                     kind: result.root.kind == .restricted ? .restricted : (node.kind == .restricted ? .directory : node.kind))
                await refreshVolumeSpace()
                treeDidChange(rebuilt: [node])
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Re-reads capacity, purgeable space and snapshots for a scanned volume.
    func refreshVolumeSpace() async {
        guard let root, root.volumeSpace != nil else { return }
        let path = root.rootPath
        let (space, snapshots, purgeable) = await Task.detached(priority: .utility) {
            (VolumeSpace.fetch(path: path),
             APFSSnapshots.snapshotVolumes(forScanOf: path).flatMap(APFSSnapshots.list(volumePath:)),
             PurgeableSpace.estimate(volumePath: path))
        }.value
        if let space {
            root.updateVolumeSpace(space, snapshots: snapshots, purgeable: purgeable)
        }
    }

    // MARK: Administrator scan

    /// Unreadable folders an administrator can read (Unix permissions, EACCES).
    private(set) var adminRestrictedCount = 0
    /// Unreadable folders blocked by macOS privacy protection (EPERM) — need Full Disk Access.
    private(set) var protectedCount = 0

    /// All unreadable folders in the tree. Built once per scan, then updated
    /// incrementally — walking millions of nodes on every change froze the UI.
    private var restrictedList: [FileNode] = []

    var restrictedNodes: [FileNode] { restrictedList.filter { !$0.flags.contains(.privacyProtected) } }

    private func rebuildRestrictedList() {
        restrictedList = root?.restrictedDescendants() ?? []
        recountRestricted()
    }

    private func noteRebuilt(_ subtrees: [FileNode]) {
        if !subtrees.isEmpty {
            var known = Set(restrictedList.map(ObjectIdentifier.init))
            for subtree in subtrees {
                for node in subtree.restrictedDescendants() where known.insert(ObjectIdentifier(node)).inserted {
                    restrictedList.append(node)
                }
            }
        }
        recountRestricted()
    }

    private func recountRestricted() {
        guard let root else {
            restrictedList = []
            adminRestrictedCount = 0
            protectedCount = 0
            restrictedCount = 0
            return
        }
        // Replaced subtrees are detached (their top node has no parent), so `root` tells.
        restrictedList.removeAll { $0.kind != .restricted || $0.root !== root }
        protectedCount = restrictedList.reduce(0) { $0 + ($1.flags.contains(.privacyProtected) ? 1 : 0) }
        adminRestrictedCount = restrictedList.count - protectedCount
        restrictedCount = restrictedList.count
    }

    /// Scans the folders that failed with "Permission denied" again as root and
    /// fills in the results. Folders blocked by macOS privacy protection are
    /// skipped: root can't read them either, only Full Disk Access helps.
    func scanRestrictedAsAdministrator() {
        guard let root else { return }
        recountRestricted()
        let paths = restrictedNodes.compactMap(\.path)
        guard !paths.isEmpty else {
            if protectedCount > 0 {
                infoMessage = String(localized: "The remaining \(protectedCount) folders are protected by macOS privacy controls, which also apply to administrators. Give DiskLens Full Disk Access, reopen it and rescan to include them.")
            }
            return
        }

        var request = Privileged.Request(command: .scan)
        request.paths = paths
        request.useAllocatedSize = useAllocatedSize
        activity = String(localized: "Scanning \(paths.count) restricted folders as administrator…")

        Task {
            defer { activity = nil }
            do {
                let (response, entries) = try await Privileged.perform(
                    request, executablePath: Bundle.main.executablePath ?? CommandLine.arguments[0],
                    prompt: String(localized: "DiskLens wants to scan folders that only an administrator can read."))
                var filledCount = 0
                var rebuilt: [FileNode] = []
                for entry in entries {
                    guard let node = root.node(atPath: entry.path) else { continue }
                    rebuilt.append(node)
                    let kind: FileNode.Kind = entry.kind == .restricted ? .restricted
                        : (PackageNames.isPackage(node.name) ? .package : .directory)
                    node.replaceContents(with: entry.children, kind: kind, flags: .scannedAsAdmin)
                    if entry.kind != .restricted { filledCount += 1 }
                }
                // Root got "Operation not permitted" too: privacy protected, don't ask again.
                for path in response.protectedPaths {
                    root.node(atPath: path)?.markPrivacyProtected()
                }
                await refreshVolumeSpace()
                treeDidChange(rebuilt: rebuilt)

                if !response.failures.isEmpty {
                    errorMessage = Self.failureText(String(localized: "Some folders could not be scanned:"), response.failures)
                } else {
                    var message = String(localized: "\(filledCount) folders were scanned as administrator.")
                    if protectedCount > 0 {
                        message += "\n\n" + String(localized: "The remaining \(protectedCount) folders are protected by macOS privacy controls, which also apply to administrators. Give DiskLens Full Disk Access, reopen it and rescan to include them.")
                    }
                    infoMessage = message
                }
            } catch Privileged.ClientError.cancelled {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: System Data

    private(set) var cleanupCategories: [CleanupCategory] = []
    private(set) var isMeasuringSystemData = false
    var isShowingSystemData = false

    /// Total of everything System Data cleanup could release (measured categories only).
    var cleanableSystemDataSize: UInt64 {
        cleanupCategories.reduce(0) { $0 &+ ($1.size ?? 0) }
    }

    func showSystemData() {
        isShowingSystemData = true
        Task { await measureSystemData() }
    }

    /// Finds the categories that apply to this Mac and measures them, reusing
    /// the scanned tree where possible.
    func measureSystemData() async {
        // Callers arriving while a measurement runs wait for it instead of skipping it.
        if let running = measuringTask {
            await running.value
            return
        }
        let task = Task { await performSystemDataMeasurement() }
        measuringTask = task
        await task.value
        measuringTask = nil
    }

    private var measuringTask: Task<Void, Never>?

    private func performSystemDataMeasurement() async {
        isMeasuringSystemData = true
        defer { isMeasuringSystemData = false }

        var categories = await Task.detached(priority: .userInitiated) { SystemDataCatalog.categories() }.value
        cleanupCategories = categories

        for index in categories.indices {
            let category = categories[index]
            switch category.kind {
            case .purgeable:
                if let node = hiddenChild(.purgeable) {
                    categories[index].size = node.size
                } else {
                    categories[index].size = await Task.detached { PurgeableSpace.estimate(volumePath: "/") ?? 0 }.value
                }
            case .localSnapshots:
                categories[index].size = await Task.detached {
                    APFSSnapshots.snapshotVolumes(forScanOf: "/").flatMap(APFSSnapshots.list(volumePath:))
                        .filter { $0.timeMachineDate != nil }
                        .reduce(UInt64(0)) { $0 &+ ($1.size ?? 0) }
                }.value
            default:
                var total: UInt64 = 0
                var unmeasured: [String] = []
                for path in category.paths {
                    if let node = root?.node(atPath: path), node.kind != .restricted {
                        total &+= node.size
                    } else {
                        unmeasured.append(path)
                    }
                }
                if !unmeasured.isEmpty {
                    let options = scanOptions(for: .folder(URL(fileURLWithPath: "/")))
                    total &+= await Task.detached(priority: .userInitiated) {
                        var measureOptions = options
                        measureOptions.threadCount = 4
                        let scanner = DiskScanner(options: measureOptions)
                        return unmeasured.reduce(UInt64(0)) { sum, path in
                            sum &+ ((try? scanner.scanBlocking(path: path).root.size) ?? 0)
                        }
                    }.value
                }
                categories[index].size = total
            }
            cleanupCategories = categories
        }
    }

    private func hiddenChild(_ kind: FileNode.Kind) -> FileNode? {
        root?.children.first { $0.kind == .hiddenSpace }?.children.first { $0.kind == kind }
    }

    /// Opens System Data as a virtual folder in the wheel: one slice per category,
    /// each containing the real folders it covers (which can go to the Collector).
    func showSystemDataInWheel() {
        guard let root else { return }
        var groups: [(name: String, items: [FileNode])] = []
        for category in cleanupCategories {
            var items: [FileNode] = []
            switch category.kind {
            case .purgeable:
                if let node = hiddenChild(.purgeable) { items = [node] }
            case .localSnapshots:
                if let node = hiddenChild(.snapshotGroup) { items = [node] }
            default:
                items = category.paths.compactMap { root.node(atPath: $0) }.filter { $0.size > 0 }
            }
            if !items.isEmpty { groups.append((CleanupText.title(category.kind), items)) }
        }
        guard !groups.isEmpty else { return }
        isShowingSystemData = false
        setFocus(FileNode.makeNestedGroup(named: String(localized: "System Data"), groups: groups, parent: root))
    }

    /// Cleans the chosen categories one after another, then refreshes the
    /// affected parts of the tree.
    func cleanSystemData(_ kinds: Set<CleanupCategory.Kind>) {
        let chosen = cleanupCategories.filter { kinds.contains($0.kind) }
        guard !chosen.isEmpty else { return }
        let before = VolumeSpace.fetch(path: "/")?.available ?? 0
        activity = String(localized: "Cleaning System Data…")

        Task {
            defer { activity = nil }
            var failures: [String: String] = [:]
            var trashedCount = 0

            var protectedCount = 0
            for category in chosen where !category.needsAdministrator {
                activity = String(localized: "Cleaning \(CleanupText.title(category.kind))…")
                let outcome = await SystemDataCleaner.clean(category)
                failures.merge(outcome.failures) { a, _ in a }
                trashedCount += outcome.trashed
                protectedCount += outcome.protectedPaths.count
            }

            // Everything that needs root goes into a single password prompt.
            let adminPaths = chosen.filter(\.needsAdministrator).flatMap(SystemDataCleaner.contents(of:))
            if !adminPaths.isEmpty {
                var request = Privileged.Request(command: .delete)
                request.paths = adminPaths
                request.bestEffort = true
                do {
                    let (response, _) = try await Privileged.perform(
                        request, executablePath: Bundle.main.executablePath ?? CommandLine.arguments[0],
                        prompt: String(localized: "DiskLens wants to clean system caches and logs."))
                    failures.merge(response.failures) { a, _ in a }
                    protectedCount += response.protectedPaths.count
                } catch Privileged.ClientError.cancelled {
                } catch {
                    failures["administrator"] = error.localizedDescription
                }
            }

            // Bring the scanned tree up to date for the folders that were touched.
            if let root {
                var options = scanOptions(for: target ?? .folder(URL(fileURLWithPath: root.rootPath)))
                options.addVolumeSpaceNodes = false
                let scanner = DiskScanner(options: options)
                var rebuilt: [FileNode] = []
                for path in Set(chosen.flatMap(\.paths)) {
                    guard let node = root.node(atPath: path), node.isContainer else { continue }
                    if let result = try? await scanner.scan(path: path), node.isAttached(to: root) {
                        node.replaceContents(with: result.root.children)
                        rebuilt.append(node)
                    }
                }
                await refreshVolumeSpace()
                treeDidChange(rebuilt: rebuilt)
            }
            await measureSystemData()

            let after = VolumeSpace.fetch(path: "/")?.available ?? before
            var message = String(localized: "\(ByteFormat.string(after > before ? after - before : 0)) of disk space was freed.")
            if trashedCount > 0 {
                message += "\n" + String(localized: "\(trashedCount) items were moved to the Trash; empty it to free their space.")
            }
            if protectedCount > 0 {
                message += "\n\n" + String(localized: "\(protectedCount) items are protected by macOS (for example Safari's and iCloud's own caches) and were left in place. This is normal; only macOS may change them.")
            }
            let failedCount = failures.count
            if failedCount > 0 {
                message += "\n\n" + String(localized: "\(failedCount) items could not be removed:")
                message += "\n" + failures.map { "• \(($0.key as NSString).lastPathComponent): \($0.value)" }
                    .sorted().prefix(8).joined(separator: "\n")
            }
            infoMessage = message
        }
    }

    // MARK: Purgeable space

    var canPurge: Bool { PurgeableSpace.isRecoveryAvailable && root?.volumeSpace != nil }

    func purgeSpace() {
        guard let root, root.volumeSpace != nil else { return }
        let path = root.rootPath
        let before = VolumeSpace.fetch(path: path)?.available ?? 0
        activity = String(localized: "Freeing purgeable space…")
        Task {
            defer { activity = nil }
            do {
                _ = try await PurgeableSpace.recover(volumePath: path)
                await refreshVolumeSpace()
                treeDidChange()
                let after = VolumeSpace.fetch(path: path)?.available ?? before
                let freed = after > before ? after - before : 0
                infoMessage = String(localized: "macOS freed \(ByteFormat.string(freed)) of purgeable space.")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Collector

    var collectedSize: UInt64 { collected.reduce(0) { $0 &+ $1.size } }
    var collectedSnapshots: [SnapshotNode] { collected.compactMap { $0 as? SnapshotNode } }

    func canCollect(_ node: FileNode) -> Bool {
        if node is SnapshotNode {
            if case .systemUpdate = (node as! SnapshotNode).snapshot.creator { return false }
            return true
        }
        return !node.isSpecial && !node.isRoot && node.path != nil
    }

    func collect(_ nodes: [FileNode]) {
        for node in nodes where canCollect(node) {
            // Already covered by a collected ancestor, or already present.
            if collected.contains(where: { $0 === node || node.isDescendant(of: $0) }) { continue }
            // Adding an ancestor supersedes collected descendants.
            collected.removeAll { $0.isDescendant(of: node) }
            collected.append(node)
        }
    }

    func collect(paths: [String]) {
        guard let root else { return }
        collect(paths.compactMap { root.node(atPath: $0) })
    }

    func uncollect(_ node: FileNode) {
        collected.removeAll { $0 === node }
    }

    func clearCollector() {
        collected = []
    }

    func isCollected(_ node: FileNode) -> Bool {
        collected.contains { $0 === node || node.isDescendant(of: $0) }
    }

    enum DeletionMode {
        case trash
        case permanent
        case administrator
    }

    func deleteCollected(_ mode: DeletionMode) {
        let snapshotNodes = collectedSnapshots
        let items = collected.filter { !($0 is SnapshotNode) }.compactMap { node in node.url.map { (node, $0) } }
        guard !items.isEmpty || !snapshotNodes.isEmpty else { return }
        activity = String(localized: "Deleting…")

        Task {
            defer { activity = nil }
            var failures: [String: String] = [:]

            // Files
            if !items.isEmpty {
                if mode == .administrator {
                    var request = Privileged.Request(command: .delete)
                    request.paths = items.map(\.1.path)
                    do {
                        let (response, _) = try await Privileged.perform(
                            request, executablePath: Bundle.main.executablePath ?? CommandLine.arguments[0],
                            prompt: String(localized: "DiskLens wants to delete items that need administrator rights."))
                        failures.merge(response.failures) { a, _ in a }
                    } catch Privileged.ClientError.cancelled {
                        return
                    } catch {
                        errorMessage = error.localizedDescription
                        return
                    }
                } else {
                    let urls = items.map(\.1)
                    let local = await Task.detached(priority: .userInitiated) { () -> [String: String] in
                        var failures: [String: String] = [:]
                        let manager = FileManager()
                        for url in urls {
                            do {
                                if mode == .trash {
                                    try manager.trashItem(at: url, resultingItemURL: nil)
                                } else {
                                    try manager.removeItem(at: url)
                                }
                            } catch {
                                failures[url.path] = error.localizedDescription
                            }
                        }
                        return failures
                    }.value
                    failures.merge(local) { a, _ in a }
                }
                for (node, url) in items where failures[url.path] == nil {
                    node.detach(reclaimToFreeSpace: mode != .trash)
                }
            }

            // Snapshots: Time Machine ones usually go without root; the rest need an administrator.
            var remainingSnapshots = snapshotNodes
            if !remainingSnapshots.isEmpty {
                let commands = remainingSnapshots.map(\.snapshot.deletionCommand)
                let results = await Task.detached(priority: .userInitiated) {
                    commands.map { $0.first == "/usr/bin/tmutil" && Privileged.runWithoutPrivileges($0) }
                }.value
                remainingSnapshots = zip(remainingSnapshots, results).filter { !$0.1 }.map(\.0)
            }
            if !remainingSnapshots.isEmpty {
                var request = Privileged.Request(command: .deleteSnapshots)
                request.commands = remainingSnapshots.map(\.snapshot.deletionCommand)
                do {
                    let (response, _) = try await Privileged.perform(
                        request, executablePath: Bundle.main.executablePath ?? CommandLine.arguments[0],
                        prompt: String(localized: "DiskLens wants to delete APFS snapshots."))
                    failures.merge(response.failures) { a, _ in a }
                } catch Privileged.ClientError.cancelled {
                } catch {
                    failures["snapshots"] = error.localizedDescription
                }
            }

            collected.removeAll { node in
                if node is SnapshotNode { return true }
                guard let path = node.path else { return true }
                return failures[path] == nil
            }
            await refreshVolumeSpace()
            treeDidChange()

            if !failures.isEmpty {
                errorMessage = Self.failureText(String(localized: "Some items could not be deleted:"), failures)
            }
        }
    }

    private static func failureText(_ title: String, _ failures: [String: String]) -> String {
        let lines = failures.map { "• \(($0.key as NSString).lastPathComponent): \($0.value)" }.sorted()
        return title + "\n" + lines.prefix(12).joined(separator: "\n") + (lines.count > 12 ? "\n…" : "")
    }

    // MARK: Watching for changes

    private func restartWatcher() {
        stopWatcher()
        guard autoRefresh, let root, phase == .results else { return }
        watcher = DirectoryWatcher(path: root.rootPath) { [weak self] changes in
            Task { @MainActor in self?.enqueue(changes) }
        }
    }

    private func stopWatcher() {
        watcher?.stop()
        watcher = nil
        pendingChanges = []
        changeTask?.cancel()
        changeTask = nil
    }

    private func enqueue(_ changes: [DirectoryWatcher.Change]) {
        pendingChanges.formUnion(changes)
        guard changeTask == nil else { return }
        changeTask = Task { [weak self] in
            await self?.processChanges()
        }
    }

    /// Brings changed directories up to date: re-lists them (keeping already
    /// scanned subfolders) or rescans the subtree when FSEvents asks for it.
    private func processChanges() async {
        defer { changeTask = nil }
        while !pendingChanges.isEmpty, !Task.isCancelled {
            guard let root, phase == .results else { pendingChanges = []; return }
            let batch = pendingChanges
            pendingChanges = []

            // Resolve to existing directory nodes, deduplicated, at most 40 per round.
            var targets: [ObjectIdentifier: (node: FileNode, deep: Bool)] = [:]
            for change in batch {
                guard var node = root.nearestNode(toPath: change.path) else { continue }
                if !node.isContainer, let parent = node.parent { node = parent }
                let key = ObjectIdentifier(node)
                targets[key] = (node, (targets[key]?.deep ?? false) || change.mustScanSubdirectories)
            }
            var options = target.map(scanOptions(for:)) ?? ScanOptions()
            options.addVolumeSpaceNodes = false
            options.threadCount = 2
            let scanner = DiskScanner(options: options)
            var changed = false
            var rebuilt: [FileNode] = []

            for (node, deep) in targets.values.prefix(40) {
                guard let path = node.path, node.isAttached(to: root) else { continue }
                if deep {
                    if node === root { continue } // Too big to do silently; the user can rescan.
                    if let result = try? await scanner.scan(path: path), node.isAttached(to: root) {
                        node.replaceContents(with: result.root.children)
                        rebuilt.append(node)
                        changed = true
                    }
                } else {
                    let known = Set(node.children.filter { $0.isContainer && !$0.isSpecial }.map(\.name))
                    let relisting = await Task.detached(priority: .utility) {
                        try? scanner.relist(path: path, knownDirectories: known)
                    }.value
                    guard node.isAttached(to: root) else { continue }
                    guard let relisting else {
                        // The folder itself is gone.
                        if node !== root, !FileManager.default.fileExists(atPath: path) {
                            node.detach()
                            changed = true
                        }
                        continue
                    }
                    let kept = node.children.filter { $0.isContainer && !$0.isSpecial && relisting.keptDirectoryNames.contains($0.name) }
                    let specials = node.children.filter(\.isSpecial)
                    let before = (node.size, node.fileCount, node.children.count)
                    node.replaceContents(with: relisting.newNodes + kept + specials)
                    rebuilt.append(contentsOf: relisting.newNodes.filter(\.isContainer))
                    if before != (node.size, node.fileCount, node.children.count) { changed = true }
                }
            }
            if changed {
                await refreshVolumeSpace()
                treeDidChange(rebuilt: rebuilt)
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: File actions

    func revealInFinder(_ nodes: [FileNode]) {
        let urls = nodes.compactMap(\.url)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func open(_ node: FileNode) {
        if let url = node.url { NSWorkspace.shared.open(url) }
    }

    func copyPath(_ node: FileNode) {
        guard let path = node.path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func quickLook(_ nodes: [FileNode]) {
        QuickLookController.shared.show(urls: nodes.compactMap(\.url))
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Selection helpers

    var focusChildren: [FileNode] { focus?.children ?? [] }

    func nodes(for ids: Set<ObjectIdentifier>) -> [FileNode] {
        focusChildren.filter { ids.contains(ObjectIdentifier($0)) }
    }

    var selectedNodes: [FileNode] { nodes(for: selection) }
}

/// Mirror of the core's package detection for UI-side decisions.
enum PackageNames {
    static func isPackage(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["app", "bundle", "framework", "plugin", "kext", "appex", "photoslibrary", "xcarchive", "sparsebundle"].contains(ext)
    }
}

/// A folder synced by a cloud storage provider (File Provider) or iCloud Drive.
struct CloudFolder: Identifiable, Equatable {
    var id: String { url.path }
    let name: String
    let provider: String
    let url: URL

    static func discover() -> [CloudFolder] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var result: [CloudFolder] = []

        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: iCloud.path) {
            result.append(CloudFolder(name: "iCloud Drive", provider: "iCloud", url: iCloud))
        }

        let storage = home.appendingPathComponent("Library/CloudStorage")
        let entries = (try? FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: [.isDirectoryKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let folder = url.lastPathComponent
            // Folder names look like "GoogleDrive-me@example.com", "OneDrive-Personal", "Dropbox", "Box-Box".
            let provider = folder.split(separator: "-", maxSplits: 1).first.map(String.init) ?? folder
            let pretty: String
            switch provider.lowercased() {
            case "googledrive": pretty = "Google Drive"
            case "onedrive": pretty = "OneDrive"
            case "dropbox": pretty = "Dropbox"
            case "box": pretty = "Box"
            default: pretty = provider
            }
            let account = folder.count > provider.count ? String(folder.dropFirst(provider.count + 1)) : ""
            result.append(CloudFolder(name: account.isEmpty ? pretty : "\(pretty) (\(account))", provider: pretty, url: url))
        }
        return result
    }
}
