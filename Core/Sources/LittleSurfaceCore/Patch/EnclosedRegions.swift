import Foundation
import simd

/// Finds the empty areas of the model that drawn lines fence in, as they'd read on paper.
public enum EnclosedRegions {
    private static let stepLimit = 5000

    /// The closed outlines of the empty areas on either side of these edges. Each area appears once.
    public static func regions(bordering edges: [EdgeID], in mesh: Mesh, projector: SurfaceProjector?) -> [BoundaryChain] {
        var found: [BoundaryChain] = []
        var walked = Set<SIMD2<UInt32>>()
        let loose = looseEdges(in: mesh)
        for edge in edges where mesh.isEdgeAlive(edge) && mesh.faceCountOf(edge: edge) < 2 && !loose.contains(edge) {
            let (a, b) = mesh.ends(edge)
            for (from, to) in [(a, b), (b, a)] where !walked.contains(SIMD2(UInt32(from), UInt32(to))) {
                guard let outline = walk(from: from, to: to, along: edge, avoiding: loose, in: mesh, projector: projector) else { continue }
                for i in outline.vertices.indices {
                    walked.insert(SIMD2(UInt32(outline.vertices[i]), UInt32(outline.vertices[(i + 1) % outline.vertices.count])))
                }
                if isEmptyPatch(outline, avoiding: loose, in: mesh, projector: projector) { found.append(outline) }
            }
        }
        return found
    }

    /// Lines that trail off into the open, which can't be part of any outline: the ends of lines, and
    /// whatever runs back from them until it reaches something that goes on.
    private static func looseEdges(in mesh: Mesh) -> Set<EdgeID> {
        var loose = Set<EdgeID>()
        func usable(_ v: VertexID) -> [EdgeID] { mesh.edgesOf(v).filter { mesh.faceCountOf(edge: $0) < 2 && !loose.contains($0) } }
        var ends = mesh.aliveVertices.filter { usable($0).count == 1 }
        while let v = ends.popLast() {
            let remaining = usable(v)
            guard remaining.count == 1 else { continue }
            loose.insert(remaining[0])
            let other = mesh.otherEnd(remaining[0], from: v)
            if usable(other).count == 1 { ends.append(other) }
        }
        return loose
    }

    private static func normal(at p: Vec3, vertex: VertexID, in mesh: Mesh, projector: SurfaceProjector?) -> Vec3 {
        projector?.closest(to: p, maxDistance: .greatestFiniteMagnitude)?.normal ?? mesh.vertexNormal(vertex)
    }

    /// Follows the outline with the area on its left, taking the sharpest left at every junction.
    private static func walk(from start: VertexID, to second: VertexID, along first: EdgeID, avoiding loose: Set<EdgeID>, in mesh: Mesh, projector: SurfaceProjector?) -> BoundaryChain? {
        var vertices = [start]
        var seen: Set<VertexID> = [start]
        var edges = [first]
        var previous = start, current = second, currentEdge = first
        for _ in 0..<stepLimit {
            guard faceIsNotOnLeft(previous, current, currentEdge, in: mesh, projector: projector) else { return nil }
            guard let next = sharpestLeft(at: current, from: previous, along: currentEdge, avoiding: loose, in: mesh, projector: projector) else { return nil }
            if current == start {
                return next == first ? BoundaryChain(vertices: vertices, edges: edges, isClosed: true) : nil
            }
            guard seen.insert(current).inserted else { return nil }
            vertices.append(current)
            edges.append(next)
            let (a, b) = mesh.ends(next)
            previous = current
            current = a == current ? b : a
            currentEdge = next
        }
        return nil
    }

    private static func faceIsNotOnLeft(_ a: VertexID, _ b: VertexID, _ edge: EdgeID, in mesh: Mesh, projector: SurfaceProjector?) -> Bool {
        guard mesh.faceCountOf(edge: edge) == 1, let face = mesh.facesOf(edge: edge).first else { return true }
        let pa = mesh.position(a), pb = mesh.position(b)
        let middle = (pa + pb) / 2
        let left = simd_cross(normal(at: middle, vertex: a, in: mesh, projector: projector), pb - pa)
        return simd_dot(left, mesh.faceCenter(face) - middle) <= 0
    }

    private static func sharpestLeft(at v: VertexID, from previous: VertexID, along arrived: EdgeID, avoiding loose: Set<EdgeID>, in mesh: Mesh, projector: SurfaceProjector?) -> EdgeID? {
        let p = mesh.position(v)
        let n = normal(at: p, vertex: v, in: mesh, projector: projector)
        func flat(_ d: Vec3) -> Vec3 { GeometryMath.safeNormalize(d - n * simd_dot(d, n), fallback: .zero) }
        let back = flat(mesh.position(previous) - p)
        var best: (edge: EdgeID, angle: Float)?
        for e in mesh.edgesOf(v) where e != arrived && mesh.faceCountOf(edge: e) < 2 && !loose.contains(e) {
            let (a, b) = mesh.ends(e)
            let direction = flat(mesh.position(a == v ? b : a) - p)
            var angle = atan2(simd_dot(n, simd_cross(direction, back)), simd_dot(direction, back))
            if angle <= 0 { angle += 2 * .pi }
            if best == nil || angle < best!.angle { best = (e, angle) }
        }
        return best?.edge
    }

    /// One side of a loop around a limb is no more enclosed than the other, and an area with other
    /// topology inside it isn't empty, though a line trailing off into it doesn't divide anything.
    private static func isEmptyPatch(_ outline: BoundaryChain, avoiding loose: Set<EdgeID>, in mesh: Mesh, projector: SurfaceProjector?) -> Bool {
        guard outline.vertices.count >= 3 else { return false }
        let points = outline.vertices.map { mesh.position($0) }
        var meanNormal = Vec3(repeating: 0)
        for (v, p) in zip(outline.vertices, points) { meanNormal += normal(at: p, vertex: v, in: mesh, projector: projector) }
        meanNormal /= Float(points.count)
        let facing = GeometryMath.newellNormal(points)
        guard simd_length(meanNormal) >= 0.5, simd_dot(facing, meanNormal) > 0 else { return false }

        let axis = simd_normalize(facing)
        let center = points.reduce(.zero, +) / Float(points.count)
        let reach = points.map { simd_length($0 - center) }.max() ?? 0
        let own = Set(outline.vertices)
        for v in mesh.aliveVertices where !own.contains(v) && !mesh.edgesOf(v).allSatisfy(loose.contains) {
            let p = mesh.position(v)
            guard simd_length(p - center) <= reach,
                  simd_dot(normal(at: p, vertex: v, in: mesh, projector: projector), meanNormal) > 0 else { continue }
            if contains(p, outline: points, axis: axis) { return false }
        }
        return true
    }

    /// Whether a point lies inside an outline, as seen along an axis.
    static func contains(_ p: Vec3, outline points: [Vec3], axis: Vec3) -> Bool {
        let u = GeometryMath.safeNormalize(points[0] - points[points.count / 2], fallback: Vec3(1, 0, 0))
        let w = simd_cross(axis, u)
        let point = Vec2(simd_dot(p, u), simd_dot(p, w))
        let polygon = points.map { Vec2(simd_dot($0, u), simd_dot($0, w)) }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
}
