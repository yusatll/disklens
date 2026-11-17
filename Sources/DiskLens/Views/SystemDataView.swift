import DiskLensCore
import SwiftUI

/// Names, explanations and icons for System Data categories (UI side, localized).
enum CleanupText {
    static func title(_ kind: CleanupCategory.Kind) -> String {
        switch kind {
        case .userCaches: return String(localized: "App caches")
        case .userLogs: return String(localized: "Logs and crash reports")
        case .mailDownloads: return String(localized: "Mail attachment downloads")
        case .trash: return String(localized: "Trash")
        case .purgeable: return String(localized: "Purgeable space")
        case .xcodeDerivedData: return String(localized: "Xcode build data (DerivedData)")
        case .deviceSupport: return String(localized: "Xcode device support files")
        case .simulatorCaches: return String(localized: "Simulator caches")
        case .unavailableSimulators: return String(localized: "Unavailable simulators")
        case .npmCache: return String(localized: "npm cache")
        case .gradleCaches: return String(localized: "Gradle caches")
        case .condaPackages: return String(localized: "Conda package cache")
        case .localSnapshots: return String(localized: "Time Machine local snapshots")
        case .systemCaches: return String(localized: "System caches")
        case .systemLogs: return String(localized: "System logs")
        case .xcodeArchives: return String(localized: "Xcode archives")
        case .deviceBackups: return String(localized: "iPhone and iPad backups")
        case .macOSInstallers: return String(localized: "macOS installers")
        }
    }

    static func detail(_ kind: CleanupCategory.Kind) -> String {
        switch kind {
        case .userCaches:
            return String(localized: "Temporary files apps keep to work faster. Apps recreate them; quit open apps first. Items in use are skipped.")
        case .userLogs:
            return String(localized: "Diagnostic logs and crash reports. Only needed for troubleshooting.")
        case .mailDownloads:
            return String(localized: "Copies of attachments you opened in Mail. The originals stay in your mail.")
        case .trash:
            return String(localized: "Empties the Trash through Finder.")
        case .purgeable:
            return String(localized: "Space macOS can reclaim on its own (caches, local snapshots). DiskLens asks macOS to do it now.")
        case .xcodeDerivedData:
            return String(localized: "Intermediate build products and indexes. Xcode rebuilds them on the next build.")
        case .deviceSupport:
            return String(localized: "Debug symbols for devices you connected. Xcode downloads them again when needed.")
        case .simulatorCaches:
            return String(localized: "Caches of the iOS Simulator. Recreated automatically.")
        case .unavailableSimulators:
            return String(localized: "Simulators whose runtime is no longer installed. Removed with “xcrun simctl delete unavailable”.")
        case .npmCache:
            return String(localized: "Downloaded npm packages. npm downloads them again when needed.")
        case .gradleCaches:
            return String(localized: "Downloaded dependencies and build caches. The next Gradle build re-downloads what it needs, which takes time.")
        case .condaPackages:
            return String(localized: "Unused package archives. Cleaned with “conda clean --all”, which keeps your environments working.")
        case .localSnapshots:
            return String(localized: "Restore points Time Machine keeps on this disk between backups. Your backups on the backup disk are not affected.")
        case .systemCaches:
            return String(localized: "Caches shared by all users. Needs an administrator password; macOS recreates what it needs.")
        case .systemLogs:
            return String(localized: "Logs written by system services and installers. Needs an administrator password.")
        case .xcodeArchives:
            return String(localized: "Archived app builds. Keep the ones you may need to symbolicate crash reports or re-submit. Moved to the Trash.")
        case .deviceBackups:
            return String(localized: "Local backups of your devices. Make sure you don't need them (or that iCloud Backup is on). Moved to the Trash.")
        case .macOSInstallers:
            return String(localized: "Downloaded “Install macOS” apps. You can download them again from the App Store. Moved to the Trash.")
        }
    }

    static func symbol(_ kind: CleanupCategory.Kind) -> String {
        switch kind {
        case .userCaches, .systemCaches, .simulatorCaches: return "archivebox"
        case .userLogs, .systemLogs: return "doc.text.magnifyingglass"
        case .mailDownloads: return "paperclip"
        case .trash: return "trash"
        case .purgeable: return "sparkles"
        case .xcodeDerivedData, .xcodeArchives: return "hammer"
        case .deviceSupport, .deviceBackups: return "iphone"
        case .unavailableSimulators: return "ipad.and.iphone.slash"
        case .npmCache, .gradleCaches, .condaPackages: return "shippingbox"
        case .localSnapshots: return "clock.arrow.circlepath"
        case .macOSInstallers: return "arrow.down.app"
        }
    }
}

/// Sheet listing the cleanable parts of System Data with safety levels.
struct SystemDataView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<CleanupCategory.Kind> = []
    @State private var didPreselect = false
    @State private var isConfirming = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                section(String(localized: "Safe to clean"), .safe,
                        footer: String(localized: "Rebuilt or downloaded again automatically when needed."))
                section(String(localized: "Review before cleaning"), .review,
                        footer: String(localized: "Removable, but check that you don't need them."))
            }
            .listStyle(.inset)
            Divider()
            footer
        }
        .frame(width: 720, height: 620)
        .onChange(of: model.isMeasuringSystemData) { _, measuring in
            if !measuring && !didPreselect {
                didPreselect = true
                selection = Set(model.cleanupCategories.filter { $0.safety == .safe && ($0.size ?? 0) > 0 && $0.kind != .trash }.map(\.kind))
            }
        }
        .confirmationDialog(String(localized: "Clean \(selection.count) categories?"), isPresented: $isConfirming,
                            titleVisibility: .visible) {
            Button("Clean", role: .destructive) {
                model.cleanSystemData(selection)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "internaldrive")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("System Data")
                    .font(.title2.weight(.semibold))
                Text("In System Settings › Storage, “System Data” is a catch-all for files that fit no other category. These are the parts of it that can be removed safely, using each tool's own cleanup method where it has one. Swap, the system itself and app databases are never touched.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if model.isMeasuringSystemData {
                ProgressView().controlSize(.small)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func section(_ title: String, _ safety: CleanupCategory.Safety, footer: String) -> some View {
        let items = model.cleanupCategories.filter { $0.safety == safety }
        if !items.isEmpty {
            Section {
                ForEach(items) { category in
                    CategoryRow(category: category, isOn: binding(for: category.kind))
                }
            } header: {
                Label(title, systemImage: safety == .safe ? "checkmark.shield" : "exclamationmark.triangle")
                    .foregroundStyle(safety == .safe ? Color.green : Color.orange)
            } footer: {
                Text(footer).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func binding(for kind: CleanupCategory.Kind) -> Binding<Bool> {
        Binding(
            get: { selection.contains(kind) },
            set: { on in
                if on { selection.insert(kind) } else { selection.remove(kind) }
            }
        )
    }

    private var selectedSize: UInt64 {
        model.cleanupCategories.filter { selection.contains($0.kind) }.reduce(0) { $0 &+ ($1.size ?? 0) }
    }

    private var confirmationMessage: String {
        var text = String(localized: "About \(ByteFormat.string(selectedSize)) will be cleaned.")
        if model.cleanupCategories.contains(where: { selection.contains($0.kind) && $0.needsAdministrator }) {
            text += " " + String(localized: "System caches and logs need an administrator password.")
        }
        return text
    }

    private var footer: some View {
        HStack {
            Button("Show in Wheel") { model.showSystemDataInWheel() }
                .disabled(model.isMeasuringSystemData || model.root == nil)
            Spacer()
            Text("Selected: \(ByteFormat.string(selectedSize))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Clean Selected…") { isConfirming = true }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty || model.activity != nil)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}

private struct CategoryRow: View {
    @Environment(AppModel.self) private var model
    let category: CleanupCategory
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled((category.size ?? 0) == 0 && category.kind != .trash)
            Image(systemName: CleanupText.symbol(category.kind))
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(CleanupText.title(category.kind))
                        .font(.headline)
                    if category.needsAdministrator {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Needs an administrator password")
                    }
                }
                Text(CleanupText.detail(category.kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let path = category.paths.first, category.paths.count == 1 {
                    Button(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            Spacer(minLength: 8)
            Group {
                if let size = category.size {
                    Text(ByteFormat.string(size))
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.callout.monospacedDigit())
            .frame(minWidth: 80, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}
