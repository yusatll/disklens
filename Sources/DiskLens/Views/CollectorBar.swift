import DiskLensCore
import SwiftUI

/// Staging area for deletion: drag slices or rows here, review, then delete.
struct CollectorBar: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false
    @State private var pendingMode: AppModel.DeletionMode?

    var body: some View {
        HStack(spacing: 12) {
            Label("Collector", systemImage: model.collected.isEmpty ? "tray" : "tray.full.fill")
                .font(.headline)
                .foregroundStyle(model.collected.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 110, alignment: .leading)

            if model.collected.isEmpty {
                Text("Drag items here (or press ⌫ in the list) to collect them for deletion.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.collected) { node in
                            CollectedChip(node: node)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                Text(ByteFormat.string(model.collectedSize))
                    .font(.title3.monospacedDigit().weight(.semibold))

                if model.activity != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Clear") { model.clearCollector() }
                    Menu {
                        Button("Delete Immediately…", role: .destructive) { pendingMode = .permanent }
                        Button("Delete as Administrator…", role: .destructive) { pendingMode = .administrator }
                    } label: {
                        Text("Move to Trash")
                    } primaryAction: {
                        pendingMode = .trash
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .background(isTargeted ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.bar))
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(4)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.collect(paths: urls.map { $0.standardizedFileURL.path })
            return true
        } isTargeted: { isTargeted = $0 }
        .confirmationDialog(dialogTitle, isPresented: dialogBinding, titleVisibility: .visible) {
            if pendingMode == .permanent {
                Button("Delete Immediately", role: .destructive) { model.deleteCollected(.permanent) }
            } else if pendingMode == .administrator {
                Button("Delete as Administrator", role: .destructive) { model.deleteCollected(.administrator) }
            } else {
                Button("Move to Trash") { model.deleteCollected(.trash) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(dialogMessage)
        }
    }

    private var dialogBinding: Binding<Bool> {
        Binding(get: { pendingMode != nil }, set: { if !$0 { pendingMode = nil } })
    }

    private var itemsText: String {
        String(localized: "\(model.collected.count) items (\(ByteFormat.string(model.collectedSize)))")
    }

    private var dialogTitle: String {
        switch pendingMode {
        case .permanent, .administrator: return String(localized: "Delete \(itemsText) immediately?")
        default: return String(localized: "Move \(itemsText) to the Trash?")
        }
    }

    private var dialogMessage: String {
        var text: String
        switch pendingMode {
        case .permanent:
            text = String(localized: "This can't be undone. The space is freed right away.")
        case .administrator:
            text = String(localized: "Items are deleted with administrator rights. This can't be undone.")
        default:
            text = String(localized: "You can put them back from the Trash. The space is freed when you empty the Trash.")
        }
        if !model.collectedSnapshots.isEmpty {
            text += "\n\n" + String(localized: "APFS snapshots are deleted permanently. Snapshots not made by Time Machine need an administrator password.")
        }
        return text
    }
}

private struct CollectedChip: View {
    @Environment(AppModel.self) private var model
    let node: FileNode

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: NodeIcon.symbol(for: node))
                .foregroundStyle(.secondary)
            Text(node.displayName)
                .lineLimit(1)
                .frame(maxWidth: 160)
            Text(ByteFormat.string(node.size))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button {
                model.uncollect(node)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from Collector")
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(.quaternary))
        .help(node.path ?? "")
        .contextMenu {
            Button("Reveal in Finder") { model.revealInFinder([node]) }
            Button("Remove from Collector") { model.uncollect(node) }
        }
    }
}
