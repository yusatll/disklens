import DiskLensCore
import SwiftUI

/// Progress plus a live wheel that fills in as folders finish scanning.
struct ScanningView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                Spacer()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Scanning “\(model.target?.title ?? "")”")
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                    Text(model.progress.currentPath.isEmpty ? " " : model.progress.currentPath)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let fraction {
                    ProgressView(value: fraction) {
                        Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit()
                    }
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                    GridRow {
                        stat(model.progress.files.formatted(), String(localized: "files"))
                        stat(model.progress.directories.formatted(), String(localized: "folders"))
                    }
                    GridRow {
                        stat(ByteFormat.string(model.progress.bytes), String(localized: "found"))
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            stat(elapsed(at: context.date), String(localized: "elapsed"))
                        }
                    }
                }

                if let mediumText {
                    Label(mediumText, systemImage: model.scanMedium == .rotational ? "opticaldiscdrive" : "bolt.horizontal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Cancel") { model.cancelScan() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)

                Spacer()
            }
            .frame(width: 320)
            .padding(32)

            Divider()

            SunburstView(
                model: model,
                layout: model.previewLayout,
                focusGeneration: 0,
                treeGeneration: model.previewGeneration,
                highlighted: model.hovered,
                isInteractive: false
            )
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    /// For whole volumes we know roughly how much is used, so progress is determinate.
    private var fraction: Double? {
        guard case let .volume(volume) = model.target, volume.space.used > 0 else { return nil }
        return min(0.99, Double(model.progress.bytes) / Double(volume.space.used))
    }

    private var mediumText: String? {
        switch model.scanMedium {
        case .solidState: return String(localized: "SSD – scanning in parallel")
        case .rotational: return String(localized: "Spinning disk – scanning sequentially to avoid seeking")
        case .network: return String(localized: "Network volume – limited parallelism")
        case .unknown: return nil
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func elapsed(at date: Date) -> String {
        let seconds = Int(date.timeIntervalSince(model.scanStartedAt))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
