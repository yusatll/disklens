import AppKit
import DiskLensCore
import QuartzCore

/// The interactive sunburst ("wheel").
///
/// Drawing follows the classic approach: every segment is an annular sector
/// built with `NSBezierPath` (outer arc → line → inner arc reversed → close)
/// and filled in `draw(_:)`. Hit-testing converts the mouse position to a
/// radius (→ ring) and an angle (→ normalized position), then binary-searches
/// the ring's segments.
///
/// Transitions: *blossom* (rings sweep open one after another), *zoom in*
/// (the clicked slice expands to become the whole wheel) and *zoom out* (the
/// old wheel shrinks back into its slice while the rest fades in).
final class SunburstNSView: NSView, NSDraggingSource {
    // MARK: Callbacks

    var onHover: (FileNode?) -> Void = { _ in }
    var onDrillDown: (FileNode) -> Void = { _ in }
    var onOpenSmallerItems: (FileNode) -> Void = { _ in }
    var onGoUp: () -> Void = {}
    var onSelect: (FileNode) -> Void = { _ in }
    var onQuickLook: (FileNode) -> Void = { _ in }
    var menuProvider: (FileNode) -> NSMenu? = { _ in nil }

    /// When false (live preview during a scan) the wheel only shows hover info.
    var isInteractive = true

    // MARK: State

    private var layout: SunburstLayout?
    private var focusGeneration = -1
    private var treeGeneration = -1
    private var highlighted: FileNode?
    private var transition: FocusTransition = .blossom

    private var hoverIndex: Int?
    private var hoverCenter = false

    private var animationStart: CFTimeInterval = 0
    private var animationDuration: CFTimeInterval = 0.55
    private var animationProgress: Double = 1
    private var displayLinkRef: CADisplayLink?

    private var mouseDownLocation: NSPoint?
    private var dragStarted = false

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { isInteractive }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Disk usage wheel"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Updates

    func update(layout: SunburstLayout?, focusGeneration: Int, treeGeneration: Int,
                highlighted: FileNode?, transition: FocusTransition) {
        if focusGeneration != self.focusGeneration {
            let first = self.focusGeneration == -1
            self.layout = layout
            self.focusGeneration = focusGeneration
            self.treeGeneration = treeGeneration
            self.transition = first ? .blossom : transition
            hoverIndex = nil
            hoverCenter = false
            startAnimation()
        } else if treeGeneration != self.treeGeneration {
            self.layout = layout
            self.treeGeneration = treeGeneration
            if let hoverIndex, hoverIndex >= (layout?.segments.count ?? 0) { self.hoverIndex = nil }
            needsDisplay = true
        }
        if highlighted !== self.highlighted {
            self.highlighted = highlighted
            needsDisplay = true
        }
    }

    private var geometry: SunburstGeometry {
        let outer = max(40, min(bounds.width, bounds.height) / 2 - 18)
        return SunburstGeometry(outerRadius: outer, ringCount: max(3, layout?.ringCount ?? 1))
    }

    private var center: NSPoint {
        NSPoint(x: bounds.midX, y: bounds.midY)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    // MARK: Animation

    private func startAnimation() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || window == nil {
            animationProgress = 1
            needsDisplay = true
            return
        }
        animationDuration = transition == .blossom ? 0.55 : 0.42
        animationProgress = 0
        animationStart = CACurrentMediaTime()
        if displayLinkRef == nil {
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLinkRef = link
        }
        needsDisplay = true
    }

    @objc private func tick(_ link: CADisplayLink) {
        let t = (CACurrentMediaTime() - animationStart) / animationDuration
        animationProgress = min(1, max(0, t))
        needsDisplay = true
        if animationProgress >= 1 {
            displayLinkRef?.invalidate()
            displayLinkRef = nil
        }
    }

    private var isAnimating: Bool { animationProgress < 1 }

    /// Blossom: rings open one after another, each sweeping clockwise from 12 o'clock.
    private func ringProgress(_ ring: Int, ringCount: Int) -> Double {
        if animationProgress >= 1 { return 1 }
        let stagger = min(0.09, 0.5 / Double(max(1, ringCount)))
        let window = 1 - stagger * Double(max(0, ringCount - 1))
        let local = (animationProgress - stagger * Double(ring)) / window
        let clamped = min(1, max(0, local))
        return 1 - pow(1 - clamped, 3) // ease-out cubic
    }

    private var easedProgress: Double {
        let t = animationProgress
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 // ease-in-out cubic
    }

    /// Radius bounds for a fractional ring index: -1 is the center disc,
    /// rings past the last one continue outward (and get faded out).
    private func radii(forRing ring: Double, geometry: SunburstGeometry) -> (inner: Double, outer: Double) {
        func bounds(_ index: Int) -> (Double, Double) {
            if index < 0 { return (0, geometry.centerRadius) }
            if index < geometry.ringCount { return (geometry.innerRadius(ring: index), geometry.outerRadius(ring: index)) }
            let last = geometry.ringCount - 1
            let width = geometry.outerRadius(ring: last) - geometry.innerRadius(ring: last)
            let extra = Double(index - last)
            return (geometry.innerRadius(ring: last) + extra * (width + geometry.ringGap),
                    geometry.outerRadius(ring: last) + extra * (width + geometry.ringGap))
        }
        let lower = Int(floor(ring))
        let fraction = ring - Double(lower)
        let a = bounds(lower)
        let b = bounds(lower + 1)
        return (a.0 + (b.0 - a.0) * fraction, a.1 + (b.1 - a.1) * fraction)
    }

    /// Where a segment is drawn right now: (start, end, fractional ring, alpha).
    private func animatedPlacement(of segment: SunburstSegment, ringCount: Int) -> (start: Double, end: Double, ring: Double, alpha: Double)? {
        let ring = Double(segment.ring)
        guard isAnimating else { return (segment.start, segment.end, ring, 1) }
        let e = easedProgress

        switch transition {
        case .blossom:
            let progress = ringProgress(segment.ring, ringCount: ringCount)
            guard progress > 0 else { return nil }
            return (segment.start * progress, segment.end * progress, ring, min(1, progress * 1.4))

        case let .zoomIn(start, span, fromRing):
            // At t=0 the new wheel sits inside the clicked slice, one ring further out.
            let fromStart = start + segment.start * span
            let fromEnd = start + segment.end * span
            let fromRingIndex = ring + Double(fromRing) + 1
            return (fromStart + (segment.start - fromStart) * e,
                    fromEnd + (segment.end - fromEnd) * e,
                    fromRingIndex + (ring - fromRingIndex) * e,
                    0.35 + 0.65 * e)

        case let .zoomOut(start, span, focusRing):
            let inside = segment.start >= start - 1e-9 && segment.end <= start + span + 1e-9 && segment.ring >= focusRing
            guard inside, span > 0 else {
                return (segment.start, segment.end, ring, e)
            }
            // At t=0 the old center filled the whole wheel.
            let fromStart = (segment.start - start) / span
            let fromEnd = (segment.end - start) / span
            let fromRingIndex = ring - Double(focusRing) - 1
            return (fromStart + (segment.start - fromStart) * e,
                    fromEnd + (segment.end - fromEnd) * e,
                    fromRingIndex + (ring - fromRingIndex) * e,
                    1)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let layout else {
            drawEmptyState()
            return
        }
        let geometry = geometry
        let c = center
        let separator = NSColor.windowBackgroundColor
        let hasFocusHighlight = highlighted != nil

        // Faint track behind the rings.
        for ring in 0..<geometry.ringCount {
            let path = Self.sectorPath(center: c, inner: geometry.innerRadius(ring: ring),
                                       outer: geometry.outerRadius(ring: ring), start: 0, end: 1)
            NSColor.labelColor.withAlphaComponent(0.035).setFill()
            path.fill()
        }

        for (index, segment) in layout.segments.enumerated() {
            guard let placement = animatedPlacement(of: segment, ringCount: layout.ringCount) else { continue }
            var (inner, outer) = radii(forRing: placement.ring, geometry: geometry)
            var alpha = placement.alpha
            if inner > geometry.outerRadius + 1 { continue }
            if outer > geometry.outerRadius + 1 {
                alpha *= max(0, 1 - (outer - geometry.outerRadius) / 60)
                outer = min(outer, geometry.outerRadius + 40)
            }
            inner = max(0, inner)
            guard alpha > 0.01, placement.end > placement.start else { continue }

            let isHovered = index == hoverIndex && !isAnimating
            let isActive = isHovered || isHighlighted(segment)
            if isHovered {
                outer += 4
                inner = max(0, inner - 1)
            }

            let path = Self.sectorPath(center: c, inner: inner, outer: outer, start: placement.start, end: placement.end)
            var color = Palette.color(for: segment)
            if isActive {
                color = Palette.highlighted(color)
            } else if hasFocusHighlight && segment.node?.isSpecial != true {
                color = color.withAlphaComponent(color.alphaComponent * 0.82)
            }
            color.withAlphaComponent(color.alphaComponent * alpha).setFill()
            path.fill()

            // Thin separators, only where the slice is wide enough to keep its color.
            let arcLength = (placement.end - placement.start) * 2 * .pi * outer
            if arcLength > 2.5 {
                separator.setStroke()
                path.lineWidth = 0.8
                path.stroke()
            }

            if case let .node(node) = segment.content, node.kind == .freeSpace {
                path.lineWidth = 1
                path.setLineDash([3, 3], count: 2, phase: 0)
                NSColor.labelColor.withAlphaComponent(0.25 * alpha).setStroke()
                path.stroke()
            }
            if case .smallerItems = segment.content, isInteractive, arcLength > 6 {
                // Dotted texture: a cue that the slice can be opened.
                path.lineWidth = 1
                path.setLineDash([1, 3], count: 2, phase: 0)
                NSColor.white.withAlphaComponent(0.35 * alpha).setStroke()
                path.stroke()
            }
        }

        if !isAnimating {
            drawLabels(layout: layout, geometry: geometry)
        }
        drawCenter(geometry: geometry)
    }

    private func drawEmptyState() {
        let text = String(localized: "Waiting for the first folders…") as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }

    private func isHighlighted(_ segment: SunburstSegment) -> Bool {
        guard let highlighted, let node = segment.node else { return false }
        return node === highlighted || node.isDescendant(of: highlighted)
    }

    /// Names (and sizes) inside slices that are big enough to hold them.
    private func drawLabels(layout: SunburstLayout, geometry: SunburstGeometry) {
        let c = center
        let nameFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let lineHeight = ceil(nameFont.ascender - nameFont.descender) + 1
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle

        for (index, segment) in layout.segments.enumerated() where segment.ring <= 2 {
            let label: String
            switch segment.content {
            case let .node(node):
                if node.kind == .freeSpace && segment.span < 0.04 { continue }
                label = node.displayName
            case let .smallerItems(_, count, _):
                label = String(localized: "\(count) smaller")
            }

            let inner = geometry.innerRadius(ring: segment.ring)
            let outer = geometry.outerRadius(ring: segment.ring)
            let ringWidth = outer - inner
            let midRadius = (inner + outer) / 2
            let midPosition = segment.start + segment.span / 2
            let arcLength = segment.span * 2 * .pi * midRadius
            if arcLength < 18 || ringWidth < lineHeight + 2 { continue }

            // Horizontal text in an angled slice: limit width by both the arc and the ring width.
            let angle = midPosition * 2 * .pi
            let tangential = abs(cos(angle))
            let radial = abs(sin(angle))
            let maxWidth = min(tangential > 0.05 ? arcLength * 0.82 / tangential : .infinity,
                               radial > 0.05 ? ringWidth * 0.82 / radial : .infinity,
                               150)
            let availableHeight = min(radial > 0.05 ? arcLength * 0.8 / radial : .infinity,
                                      tangential > 0.05 ? ringWidth * 0.85 / tangential : .infinity)
            guard maxWidth >= 34, availableHeight >= lineHeight else { continue }

            let fill = Palette.color(for: segment).usingColorSpace(.deviceRGB) ?? .gray
            let luminance = 0.299 * fill.redComponent + 0.587 * fill.greenComponent + 0.114 * fill.blueComponent
            let textColor: NSColor = (fill.alphaComponent < 0.3 || luminance > 0.62)
                ? NSColor.black.withAlphaComponent(0.78) : NSColor.white.withAlphaComponent(0.95)

            // Only label when most of the name fits; "Co…ts" helps nobody.
            let nameAttributesForMeasure: [NSAttributedString.Key: Any] = [.font: nameFont]
            let fullWidth = (label as NSString).size(withAttributes: nameAttributesForMeasure).width
            if fullWidth > maxWidth && (maxWidth < 60 || maxWidth < fullWidth * 0.6) { continue }
            let sizeText = ByteFormat.string(segment.size)
            let sizeWidth = (sizeText as NSString).size(withAttributes: [.font: sizeFont]).width
            let showSize = availableHeight >= lineHeight * 2 + 2 && segment.ring == 0 && sizeWidth <= maxWidth
            let point = SunburstGeometry.point(position: midPosition, radius: midRadius)
            let totalHeight = showSize ? lineHeight * 2 : lineHeight
            var y = c.y + point.y + totalHeight / 2 - lineHeight
            let x = c.x + point.x - maxWidth / 2

            let nameAttributes: [NSAttributedString.Key: Any] = [.font: nameFont, .foregroundColor: textColor, .paragraphStyle: paragraph]
            (label as NSString).draw(in: NSRect(x: x, y: y, width: maxWidth, height: lineHeight), withAttributes: nameAttributes)
            if showSize {
                y -= lineHeight
                let sizeAttributes: [NSAttributedString.Key: Any] = [
                    .font: sizeFont, .foregroundColor: textColor.withAlphaComponent(textColor.alphaComponent * 0.8), .paragraphStyle: paragraph,
                ]
                (sizeText as NSString).draw(in: NSRect(x: x, y: y, width: maxWidth, height: lineHeight),
                                                                    withAttributes: sizeAttributes)
            }
            _ = index
        }
    }

    private func drawCenter(geometry: SunburstGeometry) {
        guard let layout else { return }
        let c = center
        let radius = geometry.centerRadius
        let disc = NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
        let base = NSColor.controlBackgroundColor
        (hoverCenter && layout.center.parent != nil && isInteractive ? Palette.highlighted(base) : base).setFill()
        disc.fill()
        NSColor.separatorColor.setStroke()
        disc.lineWidth = 1
        disc.stroke()

        let (title, value, detail) = centerText(layout: layout)
        let width = radius * 1.55
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle

        let titleFont = NSFont.systemFont(ofSize: max(11, min(16, radius * 0.14)), weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: max(15, min(30, radius * 0.26)), weight: .bold)
        let detailFont = NSFont.systemFont(ofSize: max(10, min(13, radius * 0.11)))

        let lines: [(String, NSFont, NSColor)] = [
            (title, titleFont, .labelColor),
            (value, valueFont, .labelColor),
            (detail, detailFont, .secondaryLabelColor),
        ]
        let heights = lines.map { ceil($0.1.ascender - $0.1.descender + $0.1.leading) + 2 }
        var y = c.y + heights.reduce(0, +) / 2
        for (line, height) in zip(lines, heights) {
            y -= height
            let attributes: [NSAttributedString.Key: Any] = [
                .font: line.1, .foregroundColor: line.2, .paragraphStyle: paragraph,
            ]
            (line.0 as NSString).draw(in: NSRect(x: c.x - width / 2, y: y, width: width, height: height),
                                      withAttributes: attributes)
        }
    }

    private func centerText(layout: SunburstLayout) -> (String, String, String) {
        if let hoverIndex, hoverIndex < layout.segments.count {
            let segment = layout.segments[hoverIndex]
            switch segment.content {
            case let .smallerItems(_, count, size):
                return (String(localized: "Smaller items"), ByteFormat.string(size),
                        isInteractive ? String(localized: "\(count) items · click to open") : String(localized: "\(count) items"))
            case let .node(node):
                return (node.displayName, ByteFormat.string(node.size), Self.detail(for: node))
            }
        }
        if let highlighted, highlighted !== layout.center {
            return (highlighted.displayName, ByteFormat.string(highlighted.size), Self.detail(for: highlighted))
        }
        let focus = layout.center
        let detail = hoverCenter && focus.parent != nil && isInteractive ? String(localized: "Click to go up") : Self.detail(for: focus)
        return (focus.displayName, ByteFormat.string(focus.size), detail)
    }

    static func detail(for node: FileNode) -> String {
        switch node.kind {
        case .hiddenSpace: return String(localized: "Not visible to scan")
        case .freeSpace: return String(localized: "Available")
        case .restricted:
            return node.flags.contains(.privacyProtected)
                ? String(localized: "Protected by macOS privacy")
                : String(localized: "No access – administrator can read")
        case .symlink: return String(localized: "Symbolic link")
        case .purgeable: return String(localized: "macOS can free this on demand")
        case .snapshotGroup: return String(localized: "\(node.children.count) snapshots")
        case .snapshot: return String(localized: "APFS snapshot")
        case .otherHidden: return String(localized: "Other volumes, unreadable folders")
        case .file:
            if node.flags.contains(.hardLinkDuplicate) { return String(localized: "Hard link (counted once)") }
            if node.flags.contains(.cloneDuplicate) { return String(localized: "APFS clone (counted once)") }
            if node.flags.contains(.cloudOnly) { return String(localized: "In the cloud") }
            return String(localized: "File")
        case .directory, .package, .group:
            return String(localized: "\(node.fileCount) files")
        }
    }

    /// Annular sector between normalized positions `start`…`end` (clockwise from 12 o'clock).
    static func sectorPath(center: NSPoint, inner: Double, outer: Double, start: Double, end: Double) -> NSBezierPath {
        let path = NSBezierPath()
        if end - start >= 0.99999 {
            path.appendOval(in: NSRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
            if inner > 0 {
                path.appendOval(in: NSRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
            }
            path.windingRule = .evenOdd
            return path
        }
        // NSBezierPath angles: degrees, counter-clockwise from +x. Ours: clockwise from +y.
        let startDegrees = 90 - start * 360
        let endDegrees = 90 - end * 360
        let outerStart = SunburstGeometry.point(position: start, radius: outer)
        path.move(to: NSPoint(x: center.x + outerStart.x, y: center.y + outerStart.y))
        path.appendArc(withCenter: center, radius: outer, startAngle: startDegrees, endAngle: endDegrees, clockwise: true)
        let innerEnd = SunburstGeometry.point(position: end, radius: inner)
        path.line(to: NSPoint(x: center.x + innerEnd.x, y: center.y + innerEnd.y))
        if inner > 0 {
            path.appendArc(withCenter: center, radius: inner, startAngle: endDegrees, endAngle: startDegrees, clockwise: false)
        }
        path.close()
        return path
    }

    // MARK: Hit testing

    private enum Target {
        case center
        case segment(Int)
        case none
    }

    private func target(at point: NSPoint) -> Target {
        guard let layout, !isAnimating else { return .none }
        let dx = point.x - center.x
        let dy = point.y - center.y
        switch geometry.hitTest(dx: dx, dy: dy) {
        case .center:
            return .center
        case let .ring(ring, position):
            if let index = layout.segmentIndex(ring: ring, position: position) { return .segment(index) }
            return .none
        case .outside:
            return .none
        }
    }

    private func node(for target: Target) -> FileNode? {
        switch target {
        case .center: return layout?.center
        case let .segment(index): return layout?.segments[index].node
        case .none: return nil
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        setHover(index: nil, center: false)
    }

    private func updateHover(at point: NSPoint) {
        switch target(at: point) {
        case .center: setHover(index: nil, center: true)
        case let .segment(index): setHover(index: index, center: false)
        case .none: setHover(index: nil, center: false)
        }
    }

    private func setHover(index: Int?, center: Bool) {
        guard index != hoverIndex || center != hoverCenter else { return }
        hoverIndex = index
        hoverCenter = center
        if let index, let layout {
            onHover(layout.segments[index].node)
        } else {
            onHover(nil)
        }
        needsDisplay = true
        guard isInteractive else { return }
        if let index, let segment = layout?.segments[index] {
            let clickable: Bool
            switch segment.content {
            case let .node(node): clickable = node.canDrillDown
            case .smallerItems: clickable = true
            }
            (clickable ? NSCursor.pointingHand : NSCursor.arrow).set()
        } else if center, layout?.center.parent != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractive else { return }
        window?.makeFirstResponder(self)
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInteractive, !dragStarted, let start = mouseDownLocation else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 5 else { return }
        if case .segment = target(at: start), let node = node(for: target(at: start)), let url = node.url {
            dragStarted = true
            beginDrag(url: url, event: event, at: point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil }
        guard isInteractive, !dragStarted, let start = mouseDownLocation else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) <= 5 else { return }

        switch target(at: point) {
        case .center:
            onGoUp()
        case let .segment(index):
            guard let segment = layout?.segments[index] else { return }
            switch segment.content {
            case let .smallerItems(parent, _, _):
                onOpenSmallerItems(parent)
            case let .node(node):
                if node.canDrillDown {
                    onDrillDown(node)
                } else {
                    onSelect(node)
                }
            }
        case .none:
            break
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard isInteractive else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard let node = node(for: target(at: point)) else { return nil }
        return menuProvider(node)
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            if let index = hoverIndex, let node = layout?.segments[index].node {
                onQuickLook(node)
            } else if let highlighted {
                onQuickLook(highlighted)
            }
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Drag & drop (drag a slice to the Collector, Finder, …)

    private func beginDrag(url: URL, event: NSEvent, at point: NSPoint) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 48, height: 48)
        item.setDraggingFrame(NSRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : [.copy, .link, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragStarted = false
        mouseDownLocation = nil
    }
}

/// `NSMenuItem` that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
