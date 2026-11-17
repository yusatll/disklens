import Foundation

/// One ring slice of the sunburst. Angles are normalized: `start` and `span`
/// are fractions of a full turn (0…1), measured clockwise from 12 o'clock.
public struct SunburstSegment: Sendable {
    public enum Content: Sendable {
        /// A real node of the tree.
        case node(FileNode)
        /// Children of `parent` too small to draw individually, merged into one slice.
        case smallerItems(parent: FileNode, count: Int, size: UInt64)
    }

    public let content: Content
    /// 0 = first ring around the center.
    public let ring: Int
    public let start: Double
    public let span: Double
    /// Mid-angle of the ring-0 ancestor; drives the color family.
    public let hueAnchor: Double

    public var end: Double { start + span }

    public var node: FileNode? {
        if case let .node(node) = content { return node }
        return nil
    }

    public var size: UInt64 {
        switch content {
        case let .node(node): return node.size
        case let .smallerItems(_, _, size): return size
        }
    }

    /// The node this slice stands for when it comes to highlighting.
    public var representedNode: FileNode {
        switch content {
        case let .node(node): return node
        case let .smallerItems(parent, _, _): return parent
        }
    }

    public func contains(position: Double) -> Bool {
        position >= start && position < end
    }
}

public struct SunburstLayout: Sendable {
    public let center: FileNode
    public let segments: [SunburstSegment]
    /// Number of rings that actually contain segments.
    public let ringCount: Int
    /// Index ranges into `segments` per ring (segments are grouped by ring, sorted by start).
    public let ringRanges: [Range<Int>]

    public static let defaultMaxRings = 7
    /// Slices narrower than this fraction of a full turn are merged.
    public static let defaultMinSpan = 0.0035

    public init(center: FileNode, maxRings: Int = defaultMaxRings, minSpan: Double = defaultMinSpan) {
        var builder = Builder(maxRings: maxRings, minSpan: minSpan)
        builder.layout(directory: center, ring: 0, start: 0, span: 1, hueAnchor: nil)
        let byRing = builder.segments.enumerated().sorted { lhs, rhs in
            if lhs.element.ring != rhs.element.ring { return lhs.element.ring < rhs.element.ring }
            if lhs.element.start != rhs.element.start { return lhs.element.start < rhs.element.start }
            return lhs.offset < rhs.offset
        }.map(\.element)

        var ranges: [Range<Int>] = []
        var index = 0
        while index < byRing.count {
            let ring = byRing[index].ring
            let begin = index
            while index < byRing.count && byRing[index].ring == ring { index += 1 }
            while ranges.count < ring { ranges.append(begin..<begin) }
            ranges.append(begin..<index)
        }

        self.center = center
        self.segments = byRing
        self.ringCount = ranges.count
        self.ringRanges = ranges
    }

    /// Segment index at a normalized angle on a ring, via binary search.
    public func segmentIndex(ring: Int, position: Double) -> Int? {
        guard ring >= 0, ring < ringRanges.count else { return nil }
        let range = ringRanges[ring]
        var low = range.lowerBound
        var high = range.upperBound - 1
        while low <= high {
            let mid = (low + high) / 2
            let segment = segments[mid]
            if position < segment.start {
                high = mid - 1
            } else if position >= segment.end {
                low = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }

    /// First segment that represents `node` (used to sync hover from the list).
    public func segmentIndex(for node: FileNode) -> Int? {
        segments.firstIndex { segment in
            if case let .node(candidate) = segment.content { return candidate === node }
            return false
        }
    }

    private struct Builder {
        let maxRings: Int
        let minSpan: Double
        var segments: [SunburstSegment] = []

        mutating func layout(directory: FileNode, ring: Int, start: Double, span: Double, hueAnchor: Double?) {
            guard ring < maxRings, directory.size > 0, span > 0 else { return }
            let total = Double(directory.size)
            var cursor = start
            var smallCount = 0
            var smallSize: UInt64 = 0
            var specials: [FileNode] = []

            for child in directory.children {
                if child.isSpecial { specials.append(child); continue }
                guard child.size > 0 else { continue }
                let childSpan = span * Double(child.size) / total
                if childSpan < minSpan {
                    smallCount += 1
                    smallSize &+= child.size
                    continue
                }
                // Ring 0 picks a hue from its angle; deeper rings drift slightly
                // from the parent's hue so siblings stay distinguishable.
                let mid = cursor + childSpan / 2
                let anchor = hueAnchor.map { $0 + (mid - (start + span / 2)) * 0.18 } ?? mid
                segments.append(SunburstSegment(content: .node(child), ring: ring, start: cursor,
                                                 span: childSpan, hueAnchor: anchor))
                if child.isContainer && !child.children.isEmpty {
                    layout(directory: child, ring: ring + 1, start: cursor, span: childSpan, hueAnchor: anchor)
                }
                cursor += childSpan
            }

            if smallCount > 0 {
                let groupSpan = span * Double(smallSize) / total
                segments.append(SunburstSegment(
                    content: .smallerItems(parent: directory, count: smallCount, size: smallSize),
                    ring: ring, start: cursor, span: groupSpan, hueAnchor: hueAnchor ?? (cursor + groupSpan / 2)))
                cursor += groupSpan
            }

            for special in specials where special.size > 0 {
                let specialSpan = span * Double(special.size) / total
                segments.append(SunburstSegment(content: .node(special), ring: ring, start: cursor,
                                                 span: specialSpan, hueAnchor: cursor + specialSpan / 2))
                cursor += specialSpan
            }
        }
    }
}

/// Radii of the center disc and of each ring for a given outer radius.
/// Inner rings are wider than outer ones, so the coarse structure dominates.
public struct SunburstGeometry: Sendable, Equatable {
    public let outerRadius: Double
    public let centerRadius: Double
    public let ringGap: Double
    private let ringBounds: [(inner: Double, outer: Double)]

    public static func == (lhs: SunburstGeometry, rhs: SunburstGeometry) -> Bool {
        lhs.outerRadius == rhs.outerRadius && lhs.ringBounds.count == rhs.ringBounds.count
    }

    public init(outerRadius: Double, ringCount: Int, ringGap: Double = 1.5) {
        let rings = max(1, ringCount)
        self.outerRadius = outerRadius
        self.ringGap = ringGap
        self.centerRadius = outerRadius * (rings <= 2 ? 0.34 : 0.26)

        let decay = 0.88
        var weights: [Double] = []
        var weight = 1.0
        for _ in 0..<rings {
            weights.append(weight)
            weight *= decay
        }
        let available = max(0, outerRadius - centerRadius - ringGap * Double(rings))
        let totalWeight = weights.reduce(0, +)
        var bounds: [(Double, Double)] = []
        var inner = centerRadius + ringGap
        for w in weights {
            let width = available * w / totalWeight
            bounds.append((inner, inner + width))
            inner += width + ringGap
        }
        self.ringBounds = bounds
    }

    public var ringCount: Int { ringBounds.count }

    public func innerRadius(ring: Int) -> Double { ringBounds[min(ring, ringBounds.count - 1)].inner }
    public func outerRadius(ring: Int) -> Double { ringBounds[min(ring, ringBounds.count - 1)].outer }

    public enum Hit: Equatable {
        case center
        case ring(Int, position: Double)
        case outside
    }

    /// `dx`, `dy` are offsets from the center in a y-up coordinate system.
    public func hitTest(dx: Double, dy: Double) -> Hit {
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance <= centerRadius { return .center }
        for (index, bounds) in ringBounds.enumerated() where distance >= bounds.inner && distance <= bounds.outer {
            return .ring(index, position: Self.position(dx: dx, dy: dy))
        }
        return .outside
    }

    /// Normalized clockwise angle from 12 o'clock for an offset (y-up).
    public static func position(dx: Double, dy: Double) -> Double {
        var angle = atan2(dx, dy) // 0 at top, positive clockwise
        if angle < 0 { angle += 2 * .pi }
        return angle / (2 * .pi)
    }

    /// Point at a normalized angle and radius (y-up, relative to center).
    public static func point(position: Double, radius: Double) -> (x: Double, y: Double) {
        let angle = position * 2 * .pi
        return (radius * sin(angle), radius * cos(angle))
    }
}
