import AppKit
import DiskLensCore
import SwiftUI

/// SwiftUI wrapper. The parent reads the observable values and passes them
/// in, so SwiftUI re-runs `updateNSView` whenever they change.
struct SunburstView: NSViewRepresentable {
    let model: AppModel
    let layout: SunburstLayout?
    let focusGeneration: Int
    let treeGeneration: Int
    let highlighted: FileNode?
    var transition: FocusTransition = .blossom
    var isInteractive = true

    func makeNSView(context: Context) -> SunburstNSView {
        let view = SunburstNSView(frame: .zero)
        let model = model
        view.onHover = { node in
            if model.hovered !== node { model.hovered = node }
        }
        view.onDrillDown = { model.drillDown($0) }
        view.onOpenSmallerItems = { model.openSmallerItems(of: $0) }
        view.onGoUp = { model.goUp() }
        view.onSelect = { node in model.selection = [ObjectIdentifier(node)] }
        view.onQuickLook = { model.quickLook([$0]) }
        view.menuProvider = { NodeMenu.make(for: [$0], model: model) }
        return view
    }

    func updateNSView(_ view: SunburstNSView, context: Context) {
        view.isInteractive = isInteractive
        view.update(layout: layout, focusGeneration: focusGeneration, treeGeneration: treeGeneration,
                    highlighted: highlighted, transition: transition)
    }
}

/// Context menu shared by the wheel (AppKit) and mirrored by the list (SwiftUI).
@MainActor
enum NodeMenu {
    static func make(for nodes: [FileNode], model: AppModel) -> NSMenu? {
        guard let first = nodes.first else { return nil }
        let menu = NSMenu()
        let real = nodes.filter { $0.path != nil }

        if nodes.count == 1, first.canDrillDown, first !== model.focus {
            menu.addItem(ClosureMenuItem(String(localized: "Zoom In"), symbol: "plus.magnifyingglass") { model.drillDown(first) })
        }
        if nodes.count == 1, first === model.focus, model.canGoUp {
            menu.addItem(ClosureMenuItem(String(localized: "Zoom Out"), symbol: "minus.magnifyingglass") { model.goUp() })
        }
        if !real.isEmpty {
            menu.addItem(ClosureMenuItem(String(localized: "Reveal in Finder"), symbol: "folder") { model.revealInFinder(real) })
            menu.addItem(ClosureMenuItem(String(localized: "Quick Look"), symbol: "eye") { model.quickLook(real) })
            if real.count == 1 {
                menu.addItem(ClosureMenuItem(String(localized: "Open"), symbol: "arrow.up.forward.app") { model.open(first) })
                menu.addItem(ClosureMenuItem(String(localized: "Copy Path"), symbol: "doc.on.doc") { model.copyPath(first) })
            }
            if real.count == 1, first.isContainer {
                menu.addItem(ClosureMenuItem(String(localized: "Rescan This Folder"), symbol: "arrow.clockwise") { model.rescan(first) })
            }
        }
        if nodes.count == 1, first.kind == .restricted || first.kind == .otherHidden, !model.restrictedNodes.isEmpty {
            menu.addItem(ClosureMenuItem(String(localized: "Scan Restricted Folders as Administrator…"), symbol: "lock.open") {
                model.scanRestrictedAsAdministrator()
            })
        }
        if nodes.count == 1, first.kind == .restricted, first.flags.contains(.privacyProtected) {
            menu.addItem(ClosureMenuItem(String(localized: "Full Disk Access…"), symbol: "hand.raised") {
                model.openFullDiskAccessSettings()
            })
        }
        if nodes.count == 1, first.isRoot || first.kind == .hiddenSpace || first.kind == .group && first.name == String(localized: "System Data") {
            menu.addItem(ClosureMenuItem(String(localized: "Clean System Data…"), symbol: "externaldrive.badge.minus") {
                model.showSystemData()
            })
        }
        if nodes.count == 1, first.kind == .purgeable || first.kind == .hiddenSpace, model.canPurge {
            menu.addItem(ClosureMenuItem(String(localized: "Free Purgeable Space"), symbol: "sparkles") { model.purgeSpace() })
        }

        let collectable = nodes.filter(model.canCollect)
        if !collectable.isEmpty {
            menu.addItem(.separator())
            if collectable.allSatisfy({ model.collected.contains($0) }) {
                menu.addItem(ClosureMenuItem(String(localized: "Remove from Collector"), symbol: "tray.and.arrow.up") {
                    collectable.forEach(model.uncollect)
                })
            } else {
                menu.addItem(ClosureMenuItem(String(localized: "Add to Collector"), symbol: "tray.and.arrow.down") {
                    model.collect(collectable)
                })
            }
        }
        return menu.items.isEmpty ? nil : menu
    }
}

private extension Array where Element == FileNode {
    func contains(_ node: FileNode) -> Bool { contains { $0 === node } }
}
