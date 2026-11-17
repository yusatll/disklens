import AppKit
import Foundation

/// Minimal update check: reads a JSON feed whose URL is stored in Info.plist
/// (`DLUpdateFeedURL`, set by `scripts/build-app.sh` from `UPDATE_FEED_URL`):
///
///     { "version": "1.1.0", "downloadURL": "https://…/DiskLens-1.1.0.dmg", "notes": "…" }
///
/// Checks at most once a day on launch and on demand from the app menu.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    struct Feed: Decodable {
        let version: String
        let downloadURL: URL
        let notes: String?
    }

    private let lastCheckKey = "lastUpdateCheck"

    var feedURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "DLUpdateFeedURL") as? String,
              !value.isEmpty else { return nil }
        return URL(string: value)
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func checkIfDue() {
        guard feedURL != nil else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        guard let feedURL else {
            if userInitiated {
                alert(String(localized: "Update checks aren't configured for this build."),
                      String(localized: "Build with UPDATE_FEED_URL set to enable them."))
            }
            return
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        do {
            var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("DiskLens/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            let feed = try JSONDecoder().decode(Feed.self, from: data)
            if Self.isNewer(feed.version, than: currentVersion) {
                let alert = NSAlert()
                alert.messageText = String(localized: "DiskLens \(feed.version) is available")
                alert.informativeText = (feed.notes ?? "") + "\n\n" + String(localized: "You have version \(currentVersion).")
                alert.addButton(withTitle: String(localized: "Download"))
                alert.addButton(withTitle: String(localized: "Later"))
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(feed.downloadURL)
                }
            } else if userInitiated {
                alert(String(localized: "DiskLens is up to date."), String(localized: "You have version \(currentVersion)."))
            }
        } catch {
            if userInitiated {
                alert(String(localized: "Couldn't check for updates."), error.localizedDescription)
            }
        }
    }

    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
