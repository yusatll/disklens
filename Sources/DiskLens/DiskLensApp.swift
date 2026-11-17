import AppKit
import DiskLensCore
import Quartz
import SwiftUI

@main
enum Entry {
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--privileged"), index + 1 < arguments.count {
            // Root helper mode, started through the administrator authentication dialog.
            exit(Privileged.runHelper(requestPath: arguments[index + 1]))
        }
        if let index = arguments.firstIndex(of: "--benchmark") {
            let path = index + 1 < arguments.count ? arguments[index + 1] : NSHomeDirectory()
            Benchmark.run(path: path)
            return
        }
        DiskLensApp.main()
    }
}

struct DiskLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("DiskLens", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1240, height: 800)
        // Always open the window at launch; never restore a "closed" state.
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands { DiskLensCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        scheduleDebugSnapshotIfRequested()
        if !CommandLine.arguments.contains("--snapshot") {
            UpdateChecker.shared.checkIfDue()
        }
    }

    /// Debug aid: `--snapshot <file.png> [--snapshot-delay <seconds>]` renders the
    /// main window into a PNG (no screen-recording permission needed), then quits.
    private func scheduleDebugSnapshotIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return }
        let output = URL(fileURLWithPath: arguments[index + 1])
        var delay = 5.0
        if let d = arguments.firstIndex(of: "--snapshot-delay"), d + 1 < arguments.count {
            delay = Double(arguments[d + 1]) ?? delay
        }
        for t in stride(from: 5.0, to: delay, by: 5.0) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                FileHandle.standardError.write(Data("t=\(t) windows=\(NSApp.windows.map { "\(type(of: $0)) v=\($0.isVisible)" })\n".utf8))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let main = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.sheetParent == nil })
            guard let view = (main?.attachedSheet ?? main)?.contentView?.superview,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                for window in NSApp.windows {
                    FileHandle.standardError.write(Data("window \(type(of: window)) visible=\(window.isVisible) title=\(window.title) frame=\(window.frame)\n".utf8))
                }
                exit(2)
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: output)
            exit(0) // terminate(_:) can be refused while a sheet is open
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // Quick Look panel control (informal protocol, reached via the responder chain).
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = QuickLookController.shared
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
        }
    }
}

struct DiskLensCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                Task { await UpdateChecker.shared.check(userInitiated: true) }
            }
        }
        CommandGroup(replacing: .newItem) {
            Button("Scan Folder…") { model.chooseFolderAndScan() }
                .keyboardShortcut("o")
            Button("Show Disks") { model.showHome() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("Rescan") { model.rescan() }
                .keyboardShortcut("r")
                .disabled(model.target == nil)
            Button("Rescan Current Folder") {
                if let focus = model.focus { model.rescan(focus) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.focus == nil)
            Divider()
            Button("Scan Restricted Folders as Administrator…") { model.scanRestrictedAsAdministrator() }
                .disabled(model.adminRestrictedCount == 0)
            Button("Free Purgeable Space") { model.purgeSpace() }
                .disabled(!model.canPurge)
            Button("Clean System Data…") { model.showSystemData() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
        }
        CommandMenu("Go") {
            Button("Enclosing Folder") { model.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!model.canGoUp)
            Button("Top Level") {
                if let root = model.root { model.setFocus(root) }
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
            .disabled(!model.canGoUp)
            Button("Zoom Into Selection") {
                if let node = model.selectedNodes.first { model.drillDown(node) }
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
        }
    }
}

/// `DiskLens --benchmark <path>`: scan from the command line and print stats.
enum Benchmark {
    static func run(path: String) {
        let progress = ScanProgress()
        let start = Date()
        do {
            let result = try DiskScanner().scanBlocking(path: path, progress: progress)
            let elapsed = Date().timeIntervalSince(start)
            let stats = progress.snapshot()
            print("Scanned \(path)")
            print("  time:        \(String(format: "%.2f", elapsed)) s")
            print("  files:       \(stats.files.formatted())")
            print("  directories: \(stats.directories.formatted())")
            print("  size:        \(ByteFormat.string(result.root.size)) (\(result.root.size) bytes)")
            print("  restricted:  \(result.restrictedDirectoryCount)")
            print("  threads:     \(result.threadCount) (\(StorageMedium.detect(path: path)))")
            print("  rate:        \(Int(Double(stats.files) / max(elapsed, 0.001)).formatted()) files/s")
            print("Largest items:")
            for child in result.root.children.prefix(10) {
                print("  \(ByteFormat.string(child.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(child.name)")
            }
        } catch {
            print("error: \(error.localizedDescription)")
            exit(1)
        }
    }
}
