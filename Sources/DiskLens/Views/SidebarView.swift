import DiskLensCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let generation = model.treeGeneration
        let focus = model.focus
        let children = model.focusChildren

        VStack(spacing: 0) {
            if let focus {
                header(for: focus)
                Divider()
                if focus.isRoot, model.root?.volumeSpace != nil {
                    SystemDataCard()
                    Divider()
                }
            }
            List(selection: $model.selection) {
                ForEach(children) { node in
                    FileRow(
                        node: node,
                        parentSize: focus?.size ?? 1,
                        color: Color(nsColor: model.color(for: node)),
                        isHovered: model.hovered === node,
                        isCollected: model.isCollected(node),
                        generation: generation
                    )
                    .tag(node.id)
                    .onHover { inside in
                        if inside {
                            model.hovered = node
                        } else if model.hovered === node {
                            model.hovered = nil
                        }
                    }
                    .onDrag {
                        if let url = node.url { return NSItemProvider(object: url as NSURL) }
                        return NSItemProvider()
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .contextMenu(forSelectionType: ObjectIdentifier.self) { ids in
                let nodes = model.nodes(for: ids)
                if !nodes.isEmpty {
                    NodeMenuItems(nodes: nodes)
                }
            } primaryAction: { ids in
                guard let node = model.nodes(for: ids).first else { return }
                if node.canDrillDown {
                    model.drillDown(node)
                } else {
                    model.open(node)
                }
            }
            .onKeyPress(.space) {
                let nodes = model.selectedNodes
                guard !nodes.isEmpty else { return .ignored }
                model.quickLook(nodes)
                return .handled
            }
            .onKeyPress(.return) {
                guard let node = model.selectedNodes.first, node.canDrillDown else { return .ignored }
                model.drillDown(node)
                return .handled
            }
            .onDeleteCommand {
                model.collect(model.selectedNodes)
            }
        }
    }

    private func header(for focus: FileNode) -> some View {
        HStack(spacing: 10) {
            Image(systemName: focus.isRoot ? (model.root?.volumeSpace != nil ? "internaldrive.fill" : "folder.fill") : NodeIcon.symbol(for: focus))
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(focus.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(ByteFormat.string(focus.size)) · \(SunburstNSView.detail(for: focus))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// SwiftUI version of `NodeMenu` for the list's context menu.
struct NodeMenuItems: View {
    @Environment(AppModel.self) private var model
    let nodes: [FileNode]

    var body: some View {
        let real = nodes.filter { $0.path != nil }
        let collectable = nodes.filter(model.canCollect)
        if nodes.count == 1, let node = nodes.first, node.canDrillDown {
            Button("Zoom In", systemImage: "plus.magnifyingglass") { model.drillDown(node) }
        }
        if !real.isEmpty {
            Button("Reveal in Finder", systemImage: "folder") { model.revealInFinder(real) }
            Button("Quick Look", systemImage: "eye") { model.quickLook(real) }
            if real.count == 1, let node = real.first {
                Button("Open", systemImage: "arrow.up.forward.app") { model.open(node) }
                Button("Copy Path", systemImage: "doc.on.doc") { model.copyPath(node) }
                if node.isContainer {
                    Button("Rescan This Folder", systemImage: "arrow.clockwise") { model.rescan(node) }
                }
            }
        }
        if nodes.count == 1, let node = nodes.first {
            if node.kind == .restricted || node.kind == .otherHidden, !model.restrictedNodes.isEmpty {
                Button("Scan Restricted Folders as Administrator…", systemImage: "lock.open") {
                    model.scanRestrictedAsAdministrator()
                }
            }
            if node.kind == .restricted, node.flags.contains(.privacyProtected) {
                Button("Full Disk Access…", systemImage: "hand.raised") { model.openFullDiskAccessSettings() }
            }
            if node.kind == .purgeable || node.kind == .hiddenSpace, model.canPurge {
                Button("Free Purgeable Space", systemImage: "sparkles") { model.purgeSpace() }
            }
        }
        if !collectable.isEmpty {
            Divider()
            if collectable.allSatisfy({ node in model.collected.contains { $0 === node } }) {
                Button("Remove from Collector", systemImage: "tray.and.arrow.up") {
                    collectable.forEach(model.uncollect)
                }
            } else {
                Button("Add to Collector", systemImage: "tray.and.arrow.down") { model.collect(collectable) }
            }
        }
    }
}

private struct FileRow: View {
    let node: FileNode
    let parentSize: UInt64
    let color: Color
    let isHovered: Bool
    let isCollected: Bool
    let generation: Int


    var body: some View {
        let fraction = parentSize > 0 ? Double(node.size) / Double(parentSize) : 0
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 10, height: 10)
            Image(systemName: NodeIcon.symbol(for: node))
                .foregroundStyle(node.isContainer ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(isCollected, color: .secondary)
                if node.isContainer && node.fileCount > 0 {
                    Text(SunburstNSView.detail(for: node))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text(ByteFormat.string(node.size))
                    .font(.callout.monospacedDigit())
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 60, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(color).frame(width: max(1, 60 * fraction), height: 4)
                    }
            }
            if node.canDrillDown {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .opacity(isCollected ? 0.55 : 1)
        .listRowBackground(isHovered ? RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.18)) : nil)
        .help(node.path ?? node.displayName)
    }
}

/// Entry point to System Data cleanup on the disk overview.
private struct SystemDataCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.showSystemData()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.minus")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("System Data")
                        .font(.headline)
                    Group {
                        if model.isMeasuringSystemData && model.cleanableSystemDataSize == 0 {
                            Text("Measuring caches, logs and snapshots…")
                        } else {
                            Text("\(ByteFormat.string(model.cleanableSystemDataSize)) can be cleaned")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Review…")
                    .font(.callout)
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.tint.opacity(0.08))
    }
}
