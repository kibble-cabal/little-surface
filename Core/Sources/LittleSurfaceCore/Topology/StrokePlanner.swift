import Foundation
import simd

public struct StrokePlanOptions {
    /// World radius for snapping stroke ends to existing vertices and edges.
    public var snapRadius: Float
    /// How close the stroke must pass to an existing edge to count as crossing it.
    public var crossingTolerance: Float
    public var surfaceOffset: Float = 0
    /// How far a stroke heading away from the end of a line still counts as continuing it.
    public var lineEndRadius: Float = 0
    /// Used to tell a vertex on the far side of a thin surface from one beside the stroke.
    public var projector: SurfaceProjector?

    public init(snapRadius: Float, crossingTolerance: Float, projector: SurfaceProjector? = nil) {
        self.snapRadius = snapRadius
        self.crossingTolerance = crossingTolerance
        self.projector = projector
    }
}

/// The interpreted stroke: what it would add, and whether the artist should be asked first.
public struct StrokePlan {
    public var plan: TopologyPlan
    public var splitCount = 0
    public var snappedEnds = 0
    /// Parts of the stroke lay over existing faces and were left out.
    public var droppedOverFaces = false
    public var isClosed = false
    /// An end picked up where an existing line stops, to carry on from it.
    public var extendsLine = false
    /// Existing lines the stroke crossed, when it crossed at least two and so joins them.
    public var connectedLines = 0
}

/// Converts a processed stroke into a topology plan. Behaviour where a stroke meets existing topology:
///
/// - **Ends** snap to the nearest vertex in range, otherwise split the nearest wire or boundary edge in range.
/// - **Crossing a wire or boundary edge** snaps to that edge's end if it is close, otherwise splits the
///   edge. Either way the stroke and the edge end up sharing a vertex.
/// - **Over existing faces** nothing is created. The stroke stops at the faces' boundary and resumes on
///   the far side, because an edge across a face interior isn't valid topology.
/// - **Starting at the end of a line** and heading on from it carries the line on, from further away
///   than a snap would reach.
/// - **Crossing two or more lines** joins them, and a short overshoot past the outermost is left out.
public enum StrokePlanner {
    private struct PathNode {
        var node: PlanNode
        var position: Vec3
        var normal: Vec3
        /// Distance along the path.
        var along: Float
        var isCrossing = false
    }

    public static func plan(path: ProcessedPath, mesh: Mesh, options: StrokePlanOptions) -> StrokePlan {
        let offset = options.surfaceOffset
        var nodes: [PathNode] = []
        var along: Float = 0
        for (i, p) in path.points.enumerated() {
            if i > 0 { along += simd_length(p.position - path.points[i - 1].position) }
            let lifted = p.position + p.normal * offset
            nodes.append(PathNode(node: .new(position: lifted, normal: p.normal), position: lifted, normal: p.normal, along: along))
        }

        var out = StrokePlan(plan: TopologyPlan())
        out.isClosed = path.isClosed
        var splitCount = 0, snappedEnds = 0
        var extendsLine = false, connectedLines = 0

        let spacing = path.points.count > 1 ? path.length / Float(path.points.count - 1) : options.snapRadius

        if !path.isClosed, !mesh.isEmpty {
            let inward = min(3, nodes.count - 1)
            let startHeading = nodes[inward].position - nodes[0].position
            if let v = lineEnd(near: nodes[0].position, heading: startHeading, normal: nodes[0].normal, mesh: mesh, options: options) {
                nodes[0].node = .existing(v)
                nodes[0].position = mesh.position(v)
                snappedEnds += 1
                extendsLine = true
            } else if let snapped = snapEnd(position: nodes[0].position, normal: nodes[0].normal, mesh: mesh, options: options) {
                nodes[0].node = snapped.node
                nodes[0].position = snapped.position
                snappedEnds += 1
                if case .split = snapped.node { splitCount += 1 }
            }
            let last = nodes.count - 1
            let endHeading = nodes[last - inward].position - nodes[last].position
            if let v = lineEnd(near: nodes[last].position, heading: endHeading, normal: nodes[last].normal, mesh: mesh, options: options) {
                nodes[last].node = .existing(v)
                nodes[last].position = mesh.position(v)
                snappedEnds += 1
                extendsLine = true
            } else if let snapped = snapEnd(position: nodes[last].position, normal: nodes[last].normal, mesh: mesh, options: options) {
                nodes[last].node = snapped.node
                nodes[last].position = snapped.position
                snappedEnds += 1
                if case .split = snapped.node { splitCount += 1 }
            }
        }

        if !mesh.isEmpty {
            let crossings = findCrossings(path: path, nodes: nodes, mesh: mesh, options: options, spacing: spacing)
            if !crossings.isEmpty {
                // Remove stroke points that crowd a crossing, then merge the crossings in, in path order.
                let keepClear = spacing * 0.4
                var merged = nodes.enumerated().filter { index, node in
                    if index == 0 || index == nodes.count - 1 { return true }
                    return !crossings.contains { abs($0.along - node.along) < keepClear }
                }.map { $0.element }
                merged.append(contentsOf: crossings)
                merged.sort { $0.along < $1.along }
                nodes = merged
                if !path.isClosed, crossings.count >= 2 {
                    connectedLines = crossings.count
                    let overshoot = options.snapRadius * 1.5
                    if let first = nodes.firstIndex(where: \.isCrossing), let last = nodes.lastIndex(where: \.isCrossing) {
                        var keep = 0...(nodes.count - 1)
                        if case .new = nodes[0].node, nodes[first].along - nodes[0].along <= overshoot { keep = first...keep.upperBound }
                        if case .new = nodes[nodes.count - 1].node, nodes[nodes.count - 1].along - nodes[last].along <= overshoot { keep = keep.lowerBound...last }
                        nodes = Array(nodes[keep])
                    }
                }
            }
        }

        // Faces already cover this part of the surface: skip stroke segments over them.
        let coverage = FaceCoverage(mesh: mesh, depthTolerance: max(spacing, options.snapRadius))
        var keepSegment = [Bool](repeating: true, count: nodes.count)
        var dropped = false
        if !mesh.isEmpty && mesh.faceCount > 0 {
            let segmentCount = path.isClosed ? nodes.count : nodes.count - 1
            for i in 0..<segmentCount {
                let a = nodes[i], b = nodes[(i + 1) % nodes.count]
                let mid = (a.position + b.position) * 0.5
                if coverage.isCovered(mid, normal: a.normal) {
                    keepSegment[i] = false
                    dropped = true
                }
            }
        }

        // Dedupe nodes that resolve to the same existing vertex, and weld a stroke onto itself where it crosses.
        var canonical = Array(0..<nodes.count)
        var firstForVertex = [VertexID: Int]()
        for (i, n) in nodes.enumerated() {
            if case .existing(let v) = n.node {
                if let first = firstForVertex[v] { canonical[i] = first } else { firstForVertex[v] = i }
            }
        }
        let selfTolerance = spacing * 0.45
        if nodes.count > 4 {
            for j in 0..<nodes.count {
                guard case .new = nodes[j].node else { continue }
                for i in 0..<j where canonical[i] == i {
                    guard case .new = nodes[i].node else { continue }
                    if nodes[j].along - nodes[i].along < spacing * 2.5 { continue }
                    if path.isClosed && (path.length - nodes[j].along + nodes[i].along) < spacing * 2.5 { continue }
                    // Joining an open stroke's two ends would be closing it, which only the artist may ask for.
                    if !path.isClosed && i == 0 && j == nodes.count - 1 { continue }
                    if simd_length(nodes[i].position - nodes[j].position) < selfTolerance {
                        canonical[j] = i
                        break
                    }
                }
            }
        }

        var plan = TopologyPlan()
        var nodeIndex = [Int: Int32]()
        func index(of i: Int) -> Int32 {
            let c = canonical[i]
            if let existing = nodeIndex[c] { return existing }
            plan.nodes.append(nodes[c].node)
            let id = Int32(plan.nodes.count - 1)
            nodeIndex[c] = id
            return id
        }
        var seenEdges = Set<UInt64>()
        let segmentCount = path.isClosed ? nodes.count : nodes.count - 1
        for i in 0..<max(segmentCount, 0) where keepSegment[i] {
            let j = (i + 1) % nodes.count
            guard canonical[i] != canonical[j] else { continue }
            if simd_length(nodes[i].position - nodes[j].position) < 1e-7 { continue }
            let a = index(of: i), b = index(of: j)
            let key = (UInt64(UInt32(min(a, b))) << 32) | UInt64(UInt32(max(a, b)))
            if seenEdges.insert(key).inserted {
                plan.edges.append(SIMD2<Int32>(a, b))
            }
        }

        // Crossing nodes that ended up unused must not split anything.
        splitCount = plan.nodes.reduce(0) { total, node in
            if case .split = node { return total + 1 }
            return total
        }
        if dropped {
            plan.notes.append("Part of the stroke lay over existing faces, so it stops at their edge.")
        }
        if splitCount > 0 {
            plan.notes.append(splitCount == 1 ? "Splits 1 existing edge." : "Splits \(splitCount) existing edges.")
        }
        out.plan = plan
        out.splitCount = splitCount
        out.snappedEnds = snappedEnds
        out.droppedOverFaces = dropped
        out.extendsLine = extendsLine
        out.connectedLines = connectedLines
        return out
    }

    /// The nearest free end of a wire line in reach of the stroke's end, if the stroke heads on from
    /// it rather than running back alongside. Two parallel lines drawn close together stay separate.
    private static func lineEnd(near position: Vec3, heading: Vec3, normal: Vec3, mesh: Mesh, options: StrokePlanOptions) -> VertexID? {
        guard options.lineEndRadius > 0, simd_length_squared(heading) > 0 else { return nil }
        let direction = simd_normalize(heading)
        var best: VertexID?
        var bestDistance = options.lineEndRadius
        for v in mesh.aliveVertices {
            let edges = mesh.edgesOf(v)
            guard edges.count == 1, mesh.isWire(edges[0]) else { continue }
            let p = mesh.position(v)
            let d = simd_length(p - position)
            guard d < bestDistance, sameSide(of: v, normal: normal, mesh: mesh, options: options) else { continue }
            let outward = p - mesh.position(mesh.otherEnd(edges[0], from: v))
            guard simd_length_squared(outward) > 0, simd_dot(simd_normalize(outward), direction) >= 0.3 else { continue }
            best = v
            bestDistance = d
        }
        return best
    }

    private static func snapEnd(position: Vec3, normal: Vec3, mesh: Mesh, options: StrokePlanOptions) -> (node: PlanNode, position: Vec3)? {
        var bestVertex = invalidID
        var bestDistance = options.snapRadius
        for v in mesh.aliveVertices {
            let d = simd_length(mesh.position(v) - position)
            if d < bestDistance && sameSide(of: v, normal: normal, mesh: mesh, options: options) {
                bestDistance = d
                bestVertex = v
            }
        }
        if bestVertex >= 0 { return (.existing(bestVertex), mesh.position(bestVertex)) }

        var bestEdge = invalidID
        var bestT: Float = 0
        var bestPoint = position
        bestDistance = options.snapRadius * 0.6
        for e in mesh.aliveEdges where mesh.faceCountOf(edge: e) < 2 {
            let (a, b) = mesh.ends(e)
            let q = GeometryMath.closestPointOnSegment(position, mesh.position(a), mesh.position(b))
            let d = simd_length(q.point - position)
            if d < bestDistance && q.t > 0.02 && q.t < 0.98 && sameSide(of: a, normal: normal, mesh: mesh, options: options) {
                bestDistance = d
                bestEdge = e
                bestT = q.t
                bestPoint = q.point
            }
        }
        if bestEdge >= 0 { return (.split(edge: bestEdge, t: bestT, position: bestPoint), bestPoint) }
        return nil
    }

    /// Whether a vertex is on the same side of a thin surface as a stroke with this normal.
    private static func sameSide(of v: VertexID, normal: Vec3, mesh: Mesh, options: StrokePlanOptions) -> Bool {
        let n = mesh.vertexNormal(v)
        if simd_length_squared(n) > 0 { return simd_dot(n, normal) > -0.2 }
        guard let projector = options.projector, let hit = projector.closest(to: mesh.position(v), maxDistance: options.snapRadius) else { return true }
        return simd_dot(hit.normal, normal) > -0.2
    }

    private static func findCrossings(path: ProcessedPath, nodes: [PathNode], mesh: Mesh, options: StrokePlanOptions, spacing: Float) -> [PathNode] {
        var found: [PathNode] = []
        let tolerance = options.crossingTolerance
        let edges = mesh.aliveEdges
        let segmentCount = path.isClosed ? nodes.count : nodes.count - 1
        guard segmentCount > 0 else { return [] }

        for i in 0..<segmentCount {
            let a = nodes[i], b = nodes[(i + 1) % nodes.count]
            var box = AABB.empty
            box.grow(a.position)
            box.grow(b.position)
            let search = box.expanded(by: tolerance)
            for e in edges {
                let (ea, eb) = mesh.ends(e)
                let pa = mesh.position(ea), pb = mesh.position(eb)
                var edgeBox = AABB.empty
                edgeBox.grow(pa)
                edgeBox.grow(pb)
                guard search.intersects(edgeBox) else { continue }
                let c = GeometryMath.closestBetweenSegments(a.position, b.position, pa, pb)
                guard c.distance <= tolerance else { continue }
                guard sameSide(of: ea, normal: a.normal, mesh: mesh, options: options) else { continue }
                let along = a.along + (b.along - a.along) * c.s
                let hitPoint = simd_mix(pa, pb, Vec3(repeating: c.t))

                // A snapped end already deals with the topology there.
                if !path.isClosed, along < spacing * 0.5 || along > path.length - spacing * 0.5 {
                    if case .new = nodes[along < spacing ? 0 : nodes.count - 1].node {} else { continue }
                }
                if found.contains(where: { abs($0.along - along) < spacing * 0.25 }) { continue }

                let endTolerance = max(options.snapRadius * 0.5, tolerance)
                let edgeLength = simd_length(pa - pb)
                let node: PlanNode
                let position: Vec3
                if c.t * edgeLength < endTolerance {
                    node = .existing(ea)
                    position = pa
                } else if (1 - c.t) * edgeLength < endTolerance {
                    node = .existing(eb)
                    position = pb
                } else if mesh.faceCountOf(edge: e) < 2 {
                    node = .split(edge: e, t: c.t, position: hitPoint)
                    position = hitPoint
                } else {
                    // Interior edge: the segments on either side lie over faces and get dropped anyway.
                    continue
                }
                found.append(PathNode(node: node, position: position, normal: a.normal, along: along, isCrossing: true))
            }
        }
        return found
    }
}

/// Answers whether a point on the surface already lies inside an existing face.
struct FaceCoverage {
    private struct Entry {
        var box: AABB
        var points: [Vec3]
        var normal: Vec3
        /// Points this close to the outline count as running along the boundary, not over the face.
        var margin: Float
    }
    private var entries: [Entry] = []
    private let depthTolerance: Float

    init(mesh: Mesh, depthTolerance: Float) {
        self.depthTolerance = depthTolerance
        entries.reserveCapacity(mesh.faceCount)
        for f in mesh.aliveFaces {
            let points = mesh.facePositions(f)
            let box = AABB(points: points)
            entries.append(Entry(
                box: box.expanded(by: depthTolerance),
                points: points,
                normal: mesh.faceNormal(f),
                margin: box.diagonal * 0.02
            ))
        }
    }

    func isCovered(_ p: Vec3, normal: Vec3) -> Bool {
        for entry in entries {
            guard entry.box.distanceSquared(to: p) == 0 else { continue }
            guard abs(simd_dot(entry.normal, normal)) > 0.15 else { continue }
            let points = entry.points
            let n = points.count
            var insideFan = false
            for i in 1..<(n - 1) {
                let q = GeometryMath.closestPointOnTriangle(p, points[0], points[i], points[i + 1])
                if simd_length(q.point - p) < depthTolerance && q.bary.min() > 0 {
                    insideFan = true
                    break
                }
            }
            guard insideFan else {
                // On a fan diagonal both triangles report a zero weight, so test those too.
                if n > 3, isOnDiagonal(p, points: points, margin: entry.margin) { return true }
                continue
            }
            var clearOfOutline = true
            for i in 0..<n {
                let q = GeometryMath.closestPointOnSegment(p, points[i], points[(i + 1) % n])
                if simd_length(q.point - p) < entry.margin {
                    clearOfOutline = false
                    break
                }
            }
            if clearOfOutline { return true }
        }
        return false
    }

    private func isOnDiagonal(_ p: Vec3, points: [Vec3], margin: Float) -> Bool {
        let n = points.count
        for i in 2..<(n - 1) {
            let q = GeometryMath.closestPointOnSegment(p, points[0], points[i])
            if simd_length(q.point - p) < depthTolerance, q.t > 0.05, q.t < 0.95 {
                return true
            }
        }
        return false
    }
}
