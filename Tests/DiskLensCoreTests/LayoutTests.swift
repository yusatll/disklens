import Foundation
import Testing
@testable import DiskLensCore

/// Builds an in-memory tree: `spec` maps child name → size (file) or nested spec (directory).
private func makeTree(_ spec: [(String, Any)]) -> RootNode {
    let root = RootNode(path: "/test", title: "Test")
    fill(root, spec)
    return root
}

private func fill(_ node: FileNode, _ spec: [(String, Any)]) {
    for (name, value) in spec {
        if let size = value as? Int {
            node.children.append(FileNode(name: name, kind: .file, size: UInt64(size), parent: node))
        } else if let nested = value as? [(String, Any)] {
            let dir = FileNode(name: name, kind: .directory, parent: node)
            fill(dir, nested)
            node.children.append(dir)
        }
    }
    node.finalizeFromChildren()
}

@Suite("Sunburst layout")
struct LayoutTests {
    @Test func spansAreProportionalAndContiguous() throws {
        let root = makeTree([("a", 500), ("b", 300), ("c", 200)])
        let layout = SunburstLayout(center: root)

        #expect(layout.ringCount == 1)
        let spans = layout.segments.map(\.span)
        #expect(abs(spans[0] - 0.5) < 1e-9)
        #expect(abs(spans[1] - 0.3) < 1e-9)
        #expect(abs(spans[2] - 0.2) < 1e-9)
        #expect(layout.segments[0].start == 0)
        #expect(abs(layout.segments[1].start - 0.5) < 1e-9)
        #expect(abs(layout.segments.last!.end - 1) < 1e-9)
    }

    @Test func childrenNestInsideParentSpan() throws {
        let root = makeTree([
            ("dir", [("x", 600), ("y", 200)] as [(String, Any)]),
            ("file", 200),
        ])
        let layout = SunburstLayout(center: root)
        #expect(layout.ringCount == 2)

        let dir = layout.segments.first { $0.node?.name == "dir" }!
        let ring1 = layout.segments.filter { $0.ring == 1 }
        #expect(ring1.count == 2)
        #expect(abs(ring1[0].start - dir.start) < 1e-9)
        #expect(abs(ring1.last!.end - dir.end) < 1e-9)
        #expect(abs(ring1[0].span - 0.6) < 1e-9)
        // Color family stays close to the ring-0 ancestor's hue.
        #expect(ring1.allSatisfy { abs($0.hueAnchor - dir.hueAnchor) < 0.1 })
    }

    @Test func tinyItemsMergeIntoSmallerGroup() throws {
        var spec: [(String, Any)] = [("big", 10_000)]
        for i in 0..<20 { spec.append(("tiny\(i)", 1)) }
        let root = makeTree(spec)
        let layout = SunburstLayout(center: root, minSpan: 0.001)

        #expect(layout.segments.count == 2)
        guard case let .smallerItems(parent, count, size) = layout.segments[1].content else {
            Issue.record("expected smaller-items group")
            return
        }
        #expect(parent === root)
        #expect(count == 20)
        #expect(size == 20)
        #expect(abs(layout.segments[1].end - 1) < 1e-9)
    }

    @Test func respectsMaxRings() {
        var spec: [(String, Any)] = [("leaf", 10)]
        for depth in 0..<12 { spec = [("d\(depth)", spec)] }
        let root = makeTree(spec)
        let layout = SunburstLayout(center: root, maxRings: 5)
        #expect(layout.ringCount == 5)
        #expect(layout.segments.allSatisfy { $0.ring < 5 })
    }

    @Test func specialNodesComeAfterSmallerGroup() {
        let root = RootNode(path: "/v", title: "V")
        root.children = [
            FileNode(name: "data", kind: .file, size: 600, parent: root),
            FileNode(name: "crumb", kind: .file, size: 1, parent: root),
            FileNode(name: "Free space", kind: .freeSpace, size: 400, parent: root),
        ]
        root.finalizeFromChildren()
        let layout = SunburstLayout(center: root, minSpan: 0.01)
        let kinds = layout.segments.map { segment -> String in
            switch segment.content {
            case let .node(node): return node.name
            case .smallerItems: return "smaller"
            }
        }
        #expect(kinds == ["data", "smaller", "Free space"])
    }

    @Test func segmentLookupByPosition() {
        let root = makeTree([("a", 500), ("b", 300), ("c", 200)])
        let layout = SunburstLayout(center: root)
        #expect(layout.segmentIndex(ring: 0, position: 0.1).map { layout.segments[$0].node?.name } == "a")
        #expect(layout.segmentIndex(ring: 0, position: 0.6).map { layout.segments[$0].node?.name } == "b")
        #expect(layout.segmentIndex(ring: 0, position: 0.95).map { layout.segments[$0].node?.name } == "c")
        #expect(layout.segmentIndex(ring: 1, position: 0.5) == nil)
        #expect(layout.segmentIndex(for: root.children[1]) == 1)
    }

    @Test func emptyDirectoryHasNoSegments() {
        let root = makeTree([])
        let layout = SunburstLayout(center: root)
        #expect(layout.segments.isEmpty)
        #expect(layout.ringCount == 0)
    }
}

@Suite("Sunburst geometry")
struct GeometryTests {
    @Test func positionIsClockwiseFromTop() {
        #expect(abs(SunburstGeometry.position(dx: 0, dy: 1) - 0) < 1e-9)
        #expect(abs(SunburstGeometry.position(dx: 1, dy: 0) - 0.25) < 1e-9)
        #expect(abs(SunburstGeometry.position(dx: 0, dy: -1) - 0.5) < 1e-9)
        #expect(abs(SunburstGeometry.position(dx: -1, dy: 0) - 0.75) < 1e-9)
    }

    @Test func pointRoundTripsThroughPosition() {
        for p in stride(from: 0.0, to: 1.0, by: 0.07) {
            let pt = SunburstGeometry.point(position: p, radius: 50)
            #expect(abs(SunburstGeometry.position(dx: pt.x, dy: pt.y) - p) < 1e-9)
        }
    }

    @Test func ringsFillRadiusAndShrinkOutward() {
        let geometry = SunburstGeometry(outerRadius: 300, ringCount: 6)
        #expect(geometry.ringCount == 6)
        #expect(abs(geometry.outerRadius(ring: 5) - 300) < 1e-6)
        var previousWidth = Double.infinity
        for ring in 0..<6 {
            let width = geometry.outerRadius(ring: ring) - geometry.innerRadius(ring: ring)
            #expect(width > 0)
            #expect(width < previousWidth)
            previousWidth = width
            if ring > 0 {
                #expect(geometry.innerRadius(ring: ring) > geometry.outerRadius(ring: ring - 1))
            }
        }
    }

    @Test func hitTesting() {
        let geometry = SunburstGeometry(outerRadius: 300, ringCount: 4)
        #expect(geometry.hitTest(dx: 0, dy: 10) == .center)
        #expect(geometry.hitTest(dx: 0, dy: 400) == .outside)

        let middle = (geometry.innerRadius(ring: 2) + geometry.outerRadius(ring: 2)) / 2
        #expect(geometry.hitTest(dx: middle, dy: 0) == .ring(2, position: 0.25))
    }
}
