import Foundation
import simd

/// Finds the line an artist has just drawn another one beside.
public enum NeighborChains {
    /// Past this, scanning every line after every stroke would be felt, and meshes this far along
    /// aren't built by drawing pairs of lines.
    private static let edgeLimit = 40_000

    public static func openChains(in mesh: Mesh) -> [BoundaryChain] {
        var chains: [BoundaryChain] = []
        var visited = Set<EdgeID>()
        for e in mesh.aliveEdges where !visited.contains(e) && mesh.faceCountOf(edge: e) < 2 {
            guard let chain = ChainFinder.chain(through: e, in: mesh) else { continue }
            chain.edges.forEach { visited.insert($0) }
            if !chain.isClosed { chains.append(chain) }
        }
        return chains
    }

    /// The nearest open chain that runs alongside `chain`: of similar length, about as far apart at
    /// both ends as in the middle, and on the same side of the model. `mirror` rules out the chain's
    /// own reflection, which symmetry draws with it.
    public static func neighbor(of chain: BoundaryChain, in mesh: Mesh, projector: SurfaceProjector?, mirror: MirrorPlane?) -> BoundaryChain? {
        guard !chain.isClosed, chain.segmentCount >= 2, mesh.edgeCount <= edgeLimit else { return nil }
        let line = polyline(chain, in: mesh)
        let length = polylineLength(line)
        guard length > 0 else { return nil }
        let own = Set(chain.vertices)

        var best: (chain: BoundaryChain, gap: Float)?
        for candidate in openChains(in: mesh) where candidate.segmentCount >= 2 && own.isDisjoint(with: candidate.vertices) {
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
