import AppKit
import Quartz

/// Drives the shared Quick Look panel. The app delegate (which is part of the
/// responder chain) hands the panel to this object when it asks for a controller.
@MainActor
final class QuickLookController: NSObject {
    static let shared = QuickLookController()

    private(set) var urls: [URL] = []

    func show(urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

extension QuickLookController: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }
}
