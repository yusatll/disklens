import DiskLensCore
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 16)], spacing: 16) {
                        ForEach(model.volumes) { volume in
                            VolumeCard(volume: volume)
                        }
                        FolderCard(isTargeted: isDropTargeted)
                    }
                    if !model.cloudFolders.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Cloud Drives")
                                .font(.title3.weight(.semibold))
                            Text("Synced cloud folders. Files that are only in the cloud are counted by their full size and shown faded.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 16)], spacing: 16) {
                            ForEach(model.cloudFolders) { folder in
                                CloudCard(folder: folder)
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
        .background(.background)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.hasDirectoryPath || isDirectory($0) }) else { return false }
            model.scan(.folder(url))
            return true
        } isTargeted: { isDropTargeted = $0 }
        .toolbar {
            ToolbarItem {
                Button {
                    model.refreshVolumes()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh the list of disks")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Where did my space go?")
                .font(.largeTitle.weight(.bold))
            Text("Pick a disk or a folder. DiskLens maps everything on it into an interactive wheel so the big items stand out.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 24)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

private struct VolumeCard: View {
    @Environment(AppModel.self) private var model
    let volume: VolumeInfo
    @State private var medium: StorageMedium = .unknown

    private var mediumLabel: String? {
        switch medium {
        case .solidState: return "SSD"
        case .rotational: return "HDD"
        case .network: return String(localized: "Network")
        case .unknown: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: volume.isInternal ? "internaldrive.fill" : "externaldrive.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(volume.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text([volume.format.isEmpty ? volume.path : volume.format, mediumLabel].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if volume.isEjectable {
                    Button {
                        model.eject(volume)
                    } label: {
                        Image(systemName: "eject.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Eject \(volume.name)")
                }
            }

            UsageBar(space: volume.space)

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(ByteFormat.string(volume.space.available)) free of \(ByteFormat.string(volume.space.total))")
                        .font(.callout)
                    if volume.space.purgeable > 0 {
                        Text("+ \(ByteFormat.string(volume.space.purgeable)) purgeable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Scan") { model.scan(.volume(volume)) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .task(id: volume.path) {
            let path = volume.path
            medium = await Task.detached { StorageMedium.detect(path: path) }.value
        }
    }
}

private struct CloudCard: View {
    @Environment(AppModel.self) private var model
    let folder: CloudFolder

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: folder.provider == "iCloud" ? "icloud.fill" : "cloud.fill")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(folder.provider)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Scan") { model.scan(.cloud(folder)) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }
}

private struct FolderCard: View {
    @Environment(AppModel.self) private var model
    let isTargeted: Bool

    var body: some View {
        Button {
            model.chooseFolderAndScan()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                Text("Scan a Folder…")
                    .font(.title3.weight(.semibold))
                Text("or drop a folder anywhere in this window")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: isTargeted ? 2.5 : 1.5, dash: [6, 5]))
                .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator))
        )
    }
}

/// Used / purgeable / free bar.
struct UsageBar: View {
    let space: VolumeSpace

    var body: some View {
        GeometryReader { proxy in
            let total = max(1, Double(space.total))
            let purgeable = Double(min(space.purgeable, space.used))
            let used = Double(space.used) - purgeable
            HStack(spacing: 0) {
                Rectangle().fill(.tint)
                    .frame(width: proxy.size.width * used / total)
                Rectangle().fill(.tint.opacity(0.4))
                    .frame(width: proxy.size.width * purgeable / total)
                Spacer(minLength: 0)
            }
            .background(.quaternary)
            .clipShape(Capsule())
        }
        .frame(height: 10)
        .accessibilityElement()
        .accessibilityLabel("\(ByteFormat.string(space.used)) used of \(ByteFormat.string(space.total))")
    }
}
