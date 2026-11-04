import Foundation
import simd

/// Finds the line an artist has just drawn another one beside.
public enum NeighborChains {
    /// Past this, scanning every line after every stroke would be felt, and meshes this far along
    /// aren't built by drawing pairs of lines.
    private static let edgeLimit = 40_000

    private static func freeChains(in mesh: Mesh) -> [BoundaryChain] {
        var chains: [BoundaryChain] = []
        var visited = Set<EdgeID>()
        for e in mesh.aliveEdges where !visited.contains(e) && mesh.faceCountOf(edge: e) < 2 {
            guard let chain = ChainFinder.chain(through: e, in: mesh) else { continue }
            chain.edges.forEach { visited.insert($0) }
            chains.append(chain)
        }
        return chains
    }

    public static func openChains(in mesh: Mesh) -> [BoundaryChain] {
        freeChains(in: mesh).filter { !$0.isClosed }
    }

    /// The nearest chain that runs alongside `chain`: of similar length, about as far apart at both
    /// ends as in the middle, and on the same side of the model. A finished patch's edge counts, as
    /// the part of it beside the line. A closed chain looks for a loop around it, or inside it.
    /// `mirror` rules out the chain's own reflection, which symmetry draws with it.
    public static func neighbor(of chain: BoundaryChain, in mesh: Mesh, projector: SurfaceProjector?, mirror: MirrorPlane?) -> BoundaryChain? {
        guard chain.segmentCount >= 2, mesh.edgeCount <= edgeLimit else { return nil }
        if chain.isClosed { return ringPartner(of: chain, in: mesh, projector: projector, mirror: mirror) }
        let line = polyline(chain, in: mesh)
        let length = polylineLength(line)
        guard length > 0 else { return nil }
        let own = Set(chain.vertices)

        var best: (chain: BoundaryChain, gap: Float)?
        for whole in freeChains(in: mesh) where own.isDisjoint(with: whole.vertices) {
            let hasFaces = whole.edges.contains { !mesh.isWire($0) }
            guard !whole.isClosed || hasFaces else { continue }
            let candidate = hasFaces ? section(of: whole, beside: line, in: mesh) : whole
            guard let candidate, candidate.segmentCount >= 2 else { continue }
            let other = polyline(candidate, in: mesh)
            let otherLength = polylineLength(other)
            guard otherLength > 0, min(length, otherLength) / max(length, otherLength) >= 0.5 else { continue }

            let reversed = simd_length(line[0] - other[other.count - 1]) + simd_length(line[line.count - 1] - other[0])
                < simd_length(line[0] - other[0]) + simd_length(line[line.count - 1] - other[other.count - 1])
            let fractions: [Float] = [0, 0.25, 0.5, 0.75, 1]
            let gaps = fractions.map { t in simd_length(sample(line, at: t) - sample(other, at: reversed ? 1 - t : t)) }
            let mean = gaps.reduce(0, +) / Float(gaps.count)
            let nearest = gaps.min()!, farthest = gaps.max()!
            guard nearest > 0, farthest <= nearest * 3, mean <= max(length, otherLength) * 0.8 else { continue }
            guard mean >= mesh.averageEdgeLength * 0.5 else { continue }

            if let plane = mirror, simd_length(plane.reflect(sample(other, at: 0.5)) - sample(line, at: 0.5)) < mean * 0.5 { continue }
            if let projector,
               let a = projector.closest(to: sample(line, at: 0.5), maxDistance: length),
               let b = projector.closest(to: sample(other, at: 0.5), maxDistance: length),
               simd_dot(a.normal, b.normal) < 0.2 { continue }

            if best == nil || mean < best!.gap { best = (candidate, mean) }
        }
        return best?.chain
    }

    /// The part of a chain between the vertices nearest the line's two ends, on the side the line runs along.
    private static func section(of chain: BoundaryChain, beside line: [Vec3], in mesh: Mesh) -> BoundaryChain? {
        let points = polyline(chain, in: mesh)
        func nearest(_ p: Vec3) -> Int {
            points.indices.min { simd_length_squared(points[$0] - p) < simd_length_squared(points[$1] - p) }!
        }
        let i = nearest(line[0]), j = nearest(line[line.count - 1])
        guard i != j else { return nil }
        guard chain.isClosed else {
            let (lo, hi) = (min(i, j), max(i, j))
            return BoundaryChain(vertices: Array(chain.vertices[lo...hi]), edges: Array(chain.edges[lo..<hi]), isClosed: false)
        }
        func arc(from a: Int, to b: Int) -> BoundaryChain {
            var vertices = [chain.vertices[a]]
            var edges: [EdgeID] = []
            var k = a
            while k != b {
                edges.append(chain.edges[k])
                k = (k + 1) % chain.vertices.count
                vertices.append(chain.vertices[k])
            }
            return BoundaryChain(vertices: vertices, edges: edges, isClosed: false)
        }
        let middle = sample(line, at: 0.5)
        func distance(_ c: BoundaryChain) -> Float { simd_length(sample(polyline(c, in: mesh), at: 0.5) - middle) }
        let forward = arc(from: i, to: j), backward = arc(from: j, to: i)
        return distance(forward) <= distance(backward) ? forward : backward
    }

    /// The nearest closed chain a ring of quads could join to this one: the two share a centre along
    /// their axis, one inside the other or stacked like loops around a limb, and stay evenly apart.
    /// Two loops side by side, like a pair of eyes, don't qualify.
    private static func ringPartner(of loop: BoundaryChain, in mesh: Mesh, projector: SurfaceProjector?, mirror: MirrorPlane?) -> BoundaryChain? {
        func measure(_ points: [Vec3]) -> (center: Vec3, normal: Vec3, radius: Float) {
            let center = points.reduce(Vec3(repeating: 0), +) / Float(points.count)
            let normal = GeometryMath.safeNormalize(GeometryMath.newellNormal(points), fallback: Vec3(0, 0, 1))
            return (center, normal, points.reduce(0) { $0 + simd_length($1 - center) } / Float(points.count))
        }
        let line = polyline(loop, in: mesh)
        let own = measure(line)
        let vertices = Set(loop.vertices)

        var best: (chain: BoundaryChain, gap: Float)?
        for candidate in freeChains(in: mesh) where candidate.isClosed && candidate.segmentCount >= 3 && vertices.isDisjoint(with: candidate.vertices) {
            let other = polyline(candidate, in: mesh)
            let their = measure(other)
            guard abs(simd_dot(own.normal, their.normal)) >= 0.5 else { continue }
            let offset = their.center - own.center
            let sideways = offset - own.normal * simd_dot(offset, own.normal)
            guard simd_length(sideways) <= min(own.radius, their.radius) * 0.75 else { continue }

            let (from, to) = own.radius <= their.radius ? (line, other) : (other, line)
            let samples = stride(from: 0, to: from.count, by: max(1, from.count / 12)).map { from[$0] }
            let nearestPoints = samples.map { p in to.min { simd_length_squared($0 - p) < simd_length_squared($1 - p) }! }
            let gaps = zip(samples, nearestPoints).map { simd_length($0 - $1) }
            let mean = gaps.reduce(0, +) / Float(gaps.count)
            guard let nearest = gaps.min(), let farthest = gaps.max(), nearest > 0, farthest <= nearest * 3.5,
                  mean <= max(own.radius, their.radius) * 1.5, mean >= mesh.averageEdgeLength * 0.5 else { continue }

            if let plane = mirror, simd_length(plane.reflect(their.center) - own.center) < mean * 0.5, simd_length(offset) >= mean * 0.5 { continue }
            if let projector, let a = projector.closest(to: samples[0], maxDistance: mean), let b = projector.closest(to: nearestPoints[0], maxDistance: mean),
               simd_dot(a.normal, b.normal) < 0.2 { continue }

            if best == nil || mean < best!.gap { best = (candidate, mean) }
        }
        return best?.chain
    }

    private static func polyline(_ chain: BoundaryChain, in mesh: Mesh) -> [Vec3] {
        chain.vertices.map { mesh.position($0) }
    }

    private static func polylineLength(_ points: [Vec3]) -> Float {
        zip(points, points.dropFirst()).reduce(0) { $0 + simd_length($1.1 - $1.0) }
    }

    private static func sample(_ points: [Vec3], at t: Float) -> Vec3 {
        let target = polylineLength(points) * t
        var walked: Float = 0
        for (a, b) in zip(points, points.dropFirst()) {
            let step = simd_length(b - a)
            if walked + step >= target, step > 0 {
                return simd_mix(a, b, Vec3(repeating: (target - walked) / step))
            }
            walked += step
        }
        return points[points.count - 1]
    }
}
