import AppKit
import DiskLensCore

/// Colors for the wheel and the list. Every ring-0 slice gets its own hue from
/// its angular position; its descendants keep that hue and get lighter and
/// less saturated with depth, so a whole branch reads as one color family.
enum Palette {
    static let smallerItemsColor = NSColor(calibratedWhite: 0.62, alpha: 1)
    static let hiddenSpaceColor = NSColor(calibratedWhite: 0.48, alpha: 1)
    static let restrictedColor = NSColor(calibratedWhite: 0.40, alpha: 1)
    static let purgeableColor = NSColor(calibratedRed: 0.55, green: 0.62, blue: 0.70, alpha: 1)
    static let snapshotColor = NSColor(calibratedRed: 0.62, green: 0.55, blue: 0.68, alpha: 1)

    static var freeSpaceColor: NSColor {
        NSColor.labelColor.withAlphaComponent(0.07)
    }

    static func hue(forAnchor anchor: Double) -> CGFloat {
        // Use 92% of the color wheel so the first and last slices don't share a hue.
        CGFloat((0.56 + anchor * 0.92).truncatingRemainder(dividingBy: 1))
    }

    static func color(for segment: SunburstSegment) -> NSColor {
        let hue = hue(forAnchor: segment.hueAnchor)
        let depth = CGFloat(segment.ring)

        switch segment.content {
        case .smallerItems:
            return smallerItemsColor
        case let .node(node):
            switch node.kind {
            case .hiddenSpace, .otherHidden: return hiddenSpaceColor
            case .freeSpace: return freeSpaceColor
            case .restricted: return restrictedColor
            case .purgeable: return purgeableColor
            case .snapshotGroup, .snapshot: return snapshotColor
            case .directory, .group:
                return NSColor(calibratedHue: hue,
                               saturation: max(0.25, 0.66 - depth * 0.05),
                               brightness: min(1, 0.86 + depth * 0.02),
                               alpha: 1)
            case .package:
                return NSColor(calibratedHue: hue,
                               saturation: max(0.2, 0.50 - depth * 0.04),
                               brightness: 0.80,
                               alpha: 1)
            case .file, .symlink:
                if node.flags.contains(.cloudOnly) {
                    return NSColor(calibratedHue: hue, saturation: 0.12, brightness: 0.95, alpha: 0.55)
                }
                return NSColor(calibratedHue: hue,
                               saturation: max(0.10, 0.28 - depth * 0.02),
                               brightness: 0.78,
                               alpha: 1)
            }
        }
    }

    static func highlighted(_ color: NSColor) -> NSColor {
        color.highlight(withLevel: 0.28) ?? color
    }
}
