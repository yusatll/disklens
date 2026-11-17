import DiskLensCore
import SwiftUI

struct ResultsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.restrictedCount > 0 {
                RestrictedBanner(count: model.restrictedCount)
            }
            HSplitView {
                SidebarView()
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 560)
                VStack(spacing: 0) {
                    BreadcrumbBar()
                    Divider()
                    SunburstView(
                        model: model,
                        layout: model.layout,
                        focusGeneration: model.focusGeneration,
                        treeGeneration: model.treeGeneration,
                        highlighted: model.hovered,
                        transition: model.transition
                    )
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        if let activity = model.activity {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(activity).font(.callout)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.bottom, 14)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: model.activity)
                }
                .frame(minWidth: 460)
                .background(Color(nsColor: .windowBackgroundColor))
            }
            Divider()
            CollectorBar()
        }
        .sheet(isPresented: Binding(get: { model.isShowingSystemData }, set: { model.isShowingSystemData = $0 })) {
            SystemDataView()
                .environment(model)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.goUp()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .disabled(!model.canGoUp)
                .help("Enclosing folder (⌘↑)")
            }
            ToolbarItemGroup {
                Button {
                    model.showSystemData()
                } label: {
                    Label("System Data", systemImage: "externaldrive.badge.minus")
                }
                .help("Review and clean System Data: caches, logs, snapshots, developer files")
                if model.canPurge {
                    Button {
                        model.purgeSpace()
                    } label: {
                        Label("Free Purgeable Space", systemImage: "sparkles")
                    }
                    .help("Ask macOS to free purgeable space (caches, local snapshots) right now")
                    .disabled(model.activity != nil)
                }
                Menu {
                    Button("Rescan Everything") { model.rescan() }
                    if let focus = model.focus, !focus.isRoot, focus.path != nil {
                        Button("Rescan “\(focus.displayName)”") { model.rescan(focus) }
                    }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                } primaryAction: {
                    if let focus = model.focus, !focus.isRoot, focus.path != nil {
                        model.rescan(focus)
                    } else {
                        model.rescan()
                    }
                }
                .help("Rescan the current folder (⌘R rescans everything)")
                Button {
                    model.showHome()
                } label: {
                    Label("Disks", systemImage: "internaldrive")
                }
                .help("Back to the list of disks (⇧⌘D)")
            }
        }
    }
}

private struct RestrictedBanner: View {
    @Environment(AppModel.self) private var model
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) folders couldn't be read, so part of the disk shows up as hidden space.")
                    .font(.callout)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(2)
            Spacer()
            if model.adminRestrictedCount > 0 {
                Button("Scan as Administrator…") { model.scanRestrictedAsAdministrator() }
                    .disabled(model.activity != nil)
            }
            if model.protectedCount > 0 {
                Button("Full Disk Access…") { model.openFullDiskAccessSettings() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }

    private var detail: String {
        var parts: [String] = []
        if model.adminRestrictedCount > 0 {
            parts.append(String(localized: "\(model.adminRestrictedCount) need administrator rights"))
        }
        if model.protectedCount > 0 {
            parts.append(String(localized: "\(model.protectedCount) are protected by macOS privacy and need Full Disk Access (then reopen DiskLens and rescan)"))
        }
        return parts.joined(separator: " · ")
    }
}

struct BreadcrumbBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.treeGeneration
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        let lineage = model.focus?.lineage ?? []
                        ForEach(Array(lineage.enumerated()), id: \.element.id) { index, node in
                            if index > 0 {
                                Image(systemName: "chevron.compact.right")
                                    .foregroundStyle(.tertiary)
                            }
                            Button {
                                model.setFocus(node)
                            } label: {
                                HStack(spacing: 4) {
                                    if index == 0 {
                                        Image(systemName: model.root?.volumeSpace != nil ? "internaldrive" : "folder")
                                    }
                                    Text(node.displayName)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(node === model.focus ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                                )
                            }
                            .buttonStyle(.plain)
                            .id(node.id)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .onChange(of: model.focusGeneration) {
                    if let focus = model.focus { proxy.scrollTo(focus.id, anchor: .trailing) }
                }
            }
            Spacer(minLength: 8)
            if let focus = model.focus {
                Text(ByteFormat.string(focus.size))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .padding(.trailing, 12)
            }
        }
        .frame(height: 34)
    }
}
