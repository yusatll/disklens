import DiskLensCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .home: HomeView()
            case .scanning: ScanningView()
            case .results: ResultsView()
            }
        }
        .navigationTitle(model.target?.title ?? "DiskLens")
        .alert("DiskLens", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("DiskLens", isPresented: infoBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.infoMessage ?? "")
        }
    }

    private var infoBinding: Binding<Bool> {
        Binding(
            get: { model.infoMessage != nil && model.errorMessage == nil },
            set: { if !$0 { model.infoMessage = nil } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Sizes") {
                Picker("Measure files by", selection: $model.useAllocatedSize) {
                    Text("Size on disk").tag(true)
                    Text("Logical size").tag(false)
                }
                .pickerStyle(.radioGroup)
                Toggle("Count APFS clones once", isOn: $model.deduplicateClones)
                Text("“Size on disk” counts allocated blocks, so compressed and sparse files show what they really occupy. Cloned files share their blocks, so counting them once matches the space actually used. Takes effect on the next scan.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Updates") {
                Toggle("Keep results up to date when files change", isOn: $model.autoRefresh)
                Text("DiskLens watches the scanned folder with FSEvents and re-reads only the folders that changed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }
}

/// Icon for a node, as an SF Symbol name.
enum NodeIcon {
    static func symbol(for node: FileNode) -> String {
        switch node.kind {
        case .directory: return "folder.fill"
        case .package: return node.name.hasSuffix(".app") ? "app.dashed" : "shippingbox.fill"
        case .symlink: return "arrow.up.forward.square"
        case .restricted: return node.flags.contains(.privacyProtected) ? "hand.raised.fill" : "lock.fill"
        case .hiddenSpace: return "eye.slash.fill"
        case .freeSpace: return "circle.dashed"
        case .group: return "square.grid.3x3.fill"
        case .purgeable: return "sparkles"
        case .snapshotGroup, .snapshot: return "clock.arrow.circlepath"
        case .otherHidden: return "questionmark.folder.fill"
        case .file: return node.flags.contains(.cloudOnly) ? "icloud" : fileSymbol(for: node.name)
        }
    }

    private static func fileSymbol(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "gif", "tiff", "raw", "dng", "webp", "psd": return "photo.fill"
        case "mov", "mp4", "m4v", "avi", "mkv": return "film.fill"
        case "mp3", "m4a", "wav", "aiff", "flac", "aac": return "music.note"
        case "zip", "gz", "tar", "xz", "7z", "rar", "bz2": return "doc.zipper"
        case "dmg", "iso", "img", "sparseimage": return "externaldrive.fill"
        case "pdf": return "doc.richtext.fill"
        case "swift", "c", "h", "m", "js", "ts", "py", "rb", "go", "rs", "java", "json", "xml", "yml", "yaml": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.fill"
        }
    }
}
