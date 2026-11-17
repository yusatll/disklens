import Foundation

/// One node of the in-memory disk tree.
///
/// Kept deliberately small: a scan of a full disk creates millions of these.
/// Directories hold their children sorted by size (largest first) with
/// special nodes (hidden / free space) always last.
///
/// Thread-safety: during a scan every node is written by exactly one worker
/// thread before it is published to its parent; after the scan the tree is
/// only mutated on the main thread. Hence `@unchecked Sendable`.
public class FileNode: @unchecked Sendable, Identifiable {
    public enum Kind: UInt8, Sendable {
        case file
        case directory
        /// A directory that Finder shows as a single file (.app, .bundle …).
        case package
        case symlink
        /// A directory that could not be read (permissions / TCC).
        case restricted
        /// Space that is used on the volume but not visible to the scan.
        /// May contain purgeable / snapshot / other breakdown nodes.
        case hiddenSpace
        /// Unused space on the volume.
        case freeSpace
        /// Virtual container for the "smaller items" of a directory.
        case group
        /// Purgeable space (caches the system can drop on demand).
        case purgeable
        /// Container of APFS snapshots.
        case snapshotGroup
        /// One APFS snapshot (`SnapshotNode`).
        case snapshot
        /// Part of hidden space that can't be attributed (other volumes, unreadable folders …).
        case otherHidden
    }

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        /// A second (or later) name for an already counted hard-linked file. Its size is 0.
        public static let hardLinkDuplicate = Flags(rawValue: 1 << 0)
        /// The file's data lives in the cloud only (iCloud / File Provider "dataless").
        public static let dataless = Flags(rawValue: 1 << 1)
        /// An APFS clone whose shared data was already counted elsewhere. Its size is 0.
        public static let cloneDuplicate = Flags(rawValue: 1 << 2)
        /// Size shown is the logical size of a cloud-only file (nothing occupies the local disk).
        public static let cloudOnly = Flags(rawValue: 1 << 3)
        /// Contents were filled in by a scan with administrator privileges.
        public static let scannedAsAdmin = Flags(rawValue: 1 << 4)
        /// Unreadable because of macOS privacy protection (TCC / SIP, `EPERM`),
        /// not Unix permissions. Root can't read it either; only Full Disk Access helps.
        public static let privacyProtected = Flags(rawValue: 1 << 5)
    }

    public let name: String
    public internal(set) var kind: Kind
    public internal(set) var flags: Flags
    /// Bytes on disk (allocated size) or logical size, depending on scan options.
    public internal(set) var size: UInt64
    /// Number of files (non-directories) in this subtree. 1 for a file.
    public internal(set) var fileCount: Int
    public internal(set) var children: [FileNode]
    public internal(set) weak var parent: FileNode?

    init(name: String, kind: Kind, size: UInt64 = 0, flags: Flags = [], parent: FileNode?) {
        self.name = name
        self.kind = kind
        self.size = size
        self.flags = flags
        self.fileCount = (kind == .file || kind == .symlink) ? 1 : 0
        self.children = []
        self.parent = parent
    }

    public var id: ObjectIdentifier { ObjectIdentifier(self) }

    // MARK: - Classification

    /// Can contain children.
    public var isContainer: Bool {
        switch kind {
        case .directory, .package, .restricted, .group: return true
        case .hiddenSpace, .snapshotGroup: return !children.isEmpty
        default: return false
        }
    }

    /// Not a real file system object (hidden / free space and its breakdown).
    public var isSpecial: Bool {
        switch kind {
        case .hiddenSpace, .freeSpace, .purgeable, .snapshotGroup, .snapshot, .otherHidden: return true
        default: return false
        }
    }

    /// Can the user navigate into this node?
    public var canDrillDown: Bool {
        isContainer && kind != .restricted && !children.isEmpty
    }

    public var isRoot: Bool { parent == nil }

    // MARK: - Paths

    /// Absolute file system path, or nil for virtual nodes.
    public var path: String? {
        if isSpecial || kind == .group { return nil }
        var components: [String] = []
        var node: FileNode? = self
        while let current = node {
            if let root = current as? RootNode {
                if components.isEmpty { return root.rootPath }
                let base = root.rootPath == "/" ? "" : root.rootPath
                return base + "/" + components.reversed().joined(separator: "/")
            }
            if current.kind == .group { return nil }
            components.append(current.name)
            node = current.parent
        }
        return nil
    }

    public var url: URL? {
        guard let path else { return nil }
        return URL(fileURLWithPath: path, isDirectory: isContainer)
    }

    /// Display name: root nodes show their volume / folder name.
    public var displayName: String {
        (self as? RootNode)?.title ?? name
    }

    /// Ancestors from the root down to (and including) self.
    public var lineage: [FileNode] {
        var result: [FileNode] = []
        var node: FileNode? = self
        while let current = node {
            result.append(current)
            node = current.parent
        }
        return result.reversed()
    }

    public func isDescendant(of other: FileNode) -> Bool {
        var node = parent
        while let current = node {
            if current === other { return true }
            node = current.parent
        }
        return false
    }

    public var root: FileNode {
        var node = self
        while let parent = node.parent { node = parent }
        return node
    }

    // MARK: - Aggregation

    /// Recomputes size / file count from the (already final) children and sorts them.
    func finalizeFromChildren() {
        var total: UInt64 = 0
        var count = 0
        for child in children {
            total &+= child.size
            count += child.fileCount
        }
        size = total
        fileCount = count
        sortChildren()
    }

    func sortChildren() {
        children.sort(by: FileNode.displayOrder)
    }

    /// Largest first; special nodes (hidden, free) last in a fixed order.
    static func displayOrder(_ a: FileNode, _ b: FileNode) -> Bool {
        if a.isSpecial != b.isSpecial { return !a.isSpecial }
        if a.isSpecial && b.isSpecial && a.kind != b.kind
            && (a.kind == .hiddenSpace || a.kind == .freeSpace || b.kind == .hiddenSpace || b.kind == .freeSpace) {
            return a.kind.rawValue < b.kind.rawValue
        }
        if a.size != b.size { return a.size > b.size }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    // MARK: - Mutation (main thread, after scanning)

    /// Applies a size / file-count change to every ancestor and keeps sibling
    /// lists sorted. On a volume root, the hidden-space node absorbs the change
    /// so the wheel still adds up to the volume capacity.
    func propagate(sizeDelta: Int64, countDelta: Int) {
        guard sizeDelta != 0 || countDelta != 0 else { return }
        // A node that is no longer in its parent's list (stale reference from an
        // operation that started before the tree changed) must not touch it.
        guard isAttachedToParent else { return }
        var ancestor: FileNode? = parent
        var child: FileNode = self
        while let current = ancestor {
            if let root = current as? RootNode, root.volumeSpace != nil, sizeDelta != 0,
               let hidden = root.children.first(where: { $0.kind == .hiddenSpace }) {
                // Visible bytes changed but used space didn't (rescans) → move between visible and hidden.
                hidden.adjustHidden(by: -sizeDelta)
                root.fileCount = max(0, root.fileCount + countDelta)
                root.recomputeSizeFromChildren()
                root.sortChildren()
                return
            }
            current.size = Self.apply(sizeDelta, to: current.size)
            current.fileCount = max(0, current.fileCount + countDelta)
            current.sortChildren()
            child = current
            ancestor = current.parent
        }
        _ = child
    }

    fileprivate func recomputeSizeFromChildren() {
        size = children.reduce(0) { $0 &+ $1.size }
    }

    /// Hidden space grows/shrinks; its breakdown's "other" part absorbs it first.
    fileprivate func adjustHidden(by delta: Int64) {
        if let other = children.first(where: { $0.kind == .otherHidden }) {
            other.size = Self.apply(delta, to: other.size)
            recomputeSizeFromChildren()
        } else {
            size = Self.apply(delta, to: size)
        }
    }

    static func apply(_ delta: Int64, to value: UInt64) -> UInt64 {
        if delta >= 0 { return value &+ UInt64(delta) }
        let magnitude = UInt64(-delta)
        return value > magnitude ? value - magnitude : 0
    }

    /// Removes this node from the tree, subtracting its size from every ancestor
    /// and re-sorting the affected sibling lists.
    ///
    /// - Parameter reclaimToFreeSpace: when true and the root is a volume, the
    ///   removed bytes are added to the root's free-space node so the wheel
    ///   still sums up to the volume capacity.
    public func detach(reclaimToFreeSpace: Bool = false) {
        guard let parent, isAttachedToParent else {
            self.parent = nil
            return
        }
        let removedSize = size
        let removedFiles = fileCount
        let rootNode = parent.root as? RootNode
        parent.children.removeAll { $0 === self }

        var ancestor: FileNode? = parent
        while let current = ancestor {
            current.size = current.size >= removedSize ? current.size - removedSize : 0
            current.fileCount = max(0, current.fileCount - removedFiles)
            current.parent?.sortChildren()
            ancestor = current.parent
        }
        self.parent = nil

        if reclaimToFreeSpace, let rootNode,
           let free = rootNode.children.first(where: { $0.kind == .freeSpace }) {
            free.size &+= removedSize
            rootNode.size &+= removedSize
        }
    }

    /// Replaces this directory's contents (after a rescan, an admin scan or a
    /// file-system change) and updates all ancestors.
    /// True when this node is still listed by its parent (or is a root).
    public var isAttachedToParent: Bool {
        guard let parent else { return true }
        return parent.children.contains { $0 === self }
    }

    /// True when this node is part of the tree that `root` heads.
    public func isAttached(to root: FileNode) -> Bool {
        if self === root { return true }
        var node: FileNode = self
        while let parent = node.parent {
            guard parent.children.contains(where: { $0 === node }) else { return false }
            if parent === root { return true }
            node = parent
        }
        return false
    }

    public func replaceContents(with newChildren: [FileNode], kind newKind: Kind? = nil, flags extraFlags: Flags = []) {
        let oldSize = size
        let oldCount = fileCount
        // Children that are replaced get detached, so late operations on them are no-ops.
        let kept = Set(newChildren.map(ObjectIdentifier.init))
        for old in children where !kept.contains(ObjectIdentifier(old)) && old.parent === self {
            old.parent = nil
        }
        for child in newChildren { child.parent = self }
        children = newChildren
        if let newKind { kind = newKind }
        flags.formUnion(extraFlags)
        finalizeFromChildren()
        propagate(sizeDelta: Int64(bitPattern: size &- oldSize), countDelta: fileCount - oldCount)
    }

    /// Finds a descendant by absolute path.
    public func node(atPath target: String) -> FileNode? {
        guard let base = path else { return nil }
        if target == base { return self }
        let prefix = base == "/" ? "/" : base + "/"
        guard target.hasPrefix(prefix) else { return nil }
        let rest = target.dropFirst(prefix.count)
        var node: FileNode = self
        for component in rest.split(separator: "/", omittingEmptySubsequences: true) {
            guard let next = node.children.first(where: { $0.name == component && !$0.isSpecial }) else { return nil }
            node = next
        }
        return node
    }

    /// Deepest existing node on the way to `target` (for file-system events
    /// about paths that are new or already gone).
    public func nearestNode(toPath target: String) -> FileNode? {
        guard let base = path else { return nil }
        if target == base { return self }
        let prefix = base == "/" ? "/" : base + "/"
        guard target.hasPrefix(prefix) else { return nil }
        var node: FileNode = self
        for component in target.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: true) {
            guard let next = node.children.first(where: { $0.name == component && !$0.isSpecial }) else { break }
            node = next
        }
        return node
    }

    /// Restricted directories that an administrator (root) could read: blocked
    /// by Unix permissions (`EACCES`), not by macOS privacy protection.
    public func adminReadableRestrictedDescendants() -> [FileNode] {
        restrictedDescendants().filter { !$0.flags.contains(.privacyProtected) }
    }

    /// Restricted directories blocked by macOS privacy protection (`EPERM`).
    public func privacyProtectedDescendants() -> [FileNode] {
        restrictedDescendants().filter { $0.flags.contains(.privacyProtected) }
    }

    /// Marks a restricted directory as privacy protected (after root also got `EPERM`).
    public func markPrivacyProtected() {
        kind = .restricted
        flags.insert(.privacyProtected)
    }

    /// All restricted (unreadable) directories below this node.
    public func restrictedDescendants() -> [FileNode] {
        var result: [FileNode] = []
        var stack: [FileNode] = [self]
        while let node = stack.popLast() {
            if node.kind == .restricted { result.append(node) }
            for child in node.children where child.kind == .directory || child.kind == .package || child.kind == .restricted {
                stack.append(child)
            }
        }
        return result
    }

    /// Brings a virtual group up to date after the tree changed: drops items
    /// that are no longer in the tree (nested groups are refreshed first) and
    /// recomputes sizes. Returns false when nothing is left.
    @discardableResult
    public func refreshGroup(in root: FileNode) -> Bool {
        guard kind == .group else { return isAttached(to: root) }
        children = children.filter { child in
            child.kind == .group ? child.refreshGroup(in: root) : child.isAttached(to: root)
        }
        finalizeFromChildren()
        return !children.isEmpty
    }

    /// A virtual directory whose children are virtual groups of real nodes
    /// (e.g. "System Data" › "User caches" › ~/Library/Caches).
    public static func makeNestedGroup(named name: String, groups: [(name: String, items: [FileNode])], parent: FileNode) -> FileNode {
        let outer = FileNode(name: name, kind: .group, parent: parent)
        outer.children = groups.filter { !$0.items.isEmpty }.map { group in
            let inner = FileNode(name: group.name, kind: .group, parent: outer)
            inner.children = group.items
            inner.finalizeFromChildren()
            return inner
        }
        outer.finalizeFromChildren()
        return outer
    }

    /// A virtual directory that shows `items` (which keep their real parent).
    public static func makeGroup(named name: String, items: [FileNode], parent: FileNode) -> FileNode {
        let group = FileNode(name: name, kind: .group, parent: parent)
        group.children = items
        group.finalizeFromChildren()
        return group
    }
}

/// The node a scan starts from. Knows its absolute path and a display title.
public final class RootNode: FileNode, @unchecked Sendable {
    public let rootPath: String
    public let title: String
    /// Capacity information, present when a whole volume was scanned.
    public internal(set) var volumeSpace: VolumeSpace?

    init(path: String, title: String) {
        self.rootPath = path
        self.title = title
        super.init(name: (path as NSString).lastPathComponent, kind: .directory, parent: nil)
    }

    public static func make(path: String, title: String) -> RootNode {
        RootNode(path: path, title: title)
    }
}

/// One APFS snapshot shown inside hidden space.
public final class SnapshotNode: FileNode, @unchecked Sendable {
    public let snapshot: SnapshotInfo

    init(snapshot: SnapshotInfo, parent: FileNode?) {
        self.snapshot = snapshot
        super.init(name: snapshot.displayName, kind: .snapshot, size: snapshot.size ?? 0, parent: parent)
    }
}
