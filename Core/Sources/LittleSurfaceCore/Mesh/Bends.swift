import Foundation
import simd

/// The curve a side of a quad had before it went straight.
public struct StraightenedSide {
    public var a: VertexID
    public var b: VertexID
    public var curve: [Vec3]
}

/// A drawn line keeps its shape with bends: points that only follow the stroke and aren't corners of
/// anything. A line's real points are its ends, its sharp corners and wherever another line meets it.
/// Once a face has four real corners and no side wrapping too far round, it's a quad, and its sides go
/// straight. Until then the curve stays, so nothing that was drawn is lost before it's been used.
public extension Mesh {
    func isBendVertex(_ v: VertexID) -> Bool { isBend[Int(v)] }

    mutating func setBend(_ v: VertexID, _ bend: Bool) {
        guard isBend[Int(v)] != bend else { return }
        isBend[Int(v)] = bend
        topologyVersion &+= 1
    }

    /// A face's real corners.
    func cornerCount(of f: FaceID) -> Int { loop(f).reduce(0) { $0 + (isBend[Int($1)] ? 0 : 1) } }

    /// How much longer than the straight line between its ends a side can be and still go straight. A
    /// quarter of a ring is 1.11 and a third is 1.21, while half is 1.57 and the long way round far more.
    static var straightSideLimit: Float { 1.25 }

    /// A side that climbs over a bump and comes back down is longer without wrapping around anything, so
    /// up to this much longer it only counts as wrapping if it's turned to head back the way it came.
    static var bumpySideLimit: Float { 1.6 }

    /// How far a side's heading can turn from its start to its end, each judged over a fifth of its
    /// length, before it's wrapping. A circular arc at the straight side limit turns about this far.
    static var wrappingTurn: Float { 100 * .pi / 180 }
    /// How much longer than its straight line a side can be, next to its neighbours, and still go straight whatever it does.
    static var slightSideExcess: Float { 0.25 }

    func isQuad(_ f: FaceID) -> Bool {
        guard cornerCount(of: f) == 4 else { return false }
        return curvedSides(of: f).isEmpty
    }

    /// The bends along each side of a face that wraps too far to go straight.
    func curvedSides(of f: FaceID) -> [[VertexID]] {
        let loop = self.loop(f)
        guard let first = loop.firstIndex(where: { !isBend[Int($0)] }), loop.contains(where: { isBend[Int($0)] }) else { return [] }
        var all: [[VertexID]] = []
        var side = [loop[first]]
        for offset in 1...loop.count {
            let v = loop[(first + offset) % loop.count]
            side.append(v)
            if isBend[Int(v)] { continue }
            all.append(side)
            side = [v]
        }
        func length(_ side: [VertexID]) -> Float { zip(side, side.dropFirst()).reduce(0) { $0 + simd_length(position($1.1) - position($1.0)) } }
        var curved: [[VertexID]] = []
        for (i, side) in all.enumerated() where side.count > 2 && wrapsTooFar(side) {
            // However sharply it turns, a side this small next to its neighbours hardly bends the shape.
            let before = all[(i + all.count - 1) % all.count], after = all[(i + 1) % all.count]
            let excess = length(side) - simd_length(position(side[side.count - 1]) - position(side[0]))
            if all.count == 4, excess < (length(before) + length(after)) * 0.5 * Self.slightSideExcess { continue }
            curved.append(Array(side.dropFirst().dropLast()))
        }
        return curved
    }

    private func wrapsTooFar(_ side: [VertexID]) -> Bool {
        let points = side.map { position($0) }
        var along: [Float] = [0]
        for (a, b) in zip(points, points.dropFirst()) { along.append(along[along.count - 1] + simd_length(b - a)) }
        let length = along[along.count - 1]
        let straight = simd_length(points[points.count - 1] - points[0])
        guard length > straight * Self.straightSideLimit else { return false }
        guard length <= straight * Self.bumpySideLimit else { return true }
        func point(at distance: Float) -> Vec3 {
            guard let next = along.firstIndex(where: { $0 >= distance }), next > 0 else { return points[0] }
            let t = (distance - along[next - 1]) / max(along[next] - along[next - 1], 1e-6)
            return simd_mix(points[next - 1], points[next], Vec3(repeating: t))
        }
        let setsOff = GeometryMath.safeNormalize(point(at: length * 0.2) - points[0], fallback: .zero)
        let arrives = GeometryMath.safeNormalize(points[points.count - 1] - point(at: length * 0.8), fallback: .zero)
        return simd_dot(setsOff, arrives) < cos(Self.wrappingTurn)
    }

    /// How heavy each vertex of a line looks. A line thins away where it ends in the open, over its last
    /// few bends, and carrying it on from there brings it back to its full weight.
    func lineWeightsWithLooseEndsThinned() -> [Float] {
        var weights = lineWeights
        for v in aliveVertices where vertexEdges[Int(v)].count == 1 {
            weights[Int(v)] *= LineWeight.looseEnd[0]
            var previous = v, current = otherEnd(vertexEdges[Int(v)][0], from: v)
            for thinning in LineWeight.looseEnd.dropFirst() {
                guard isBend[Int(current)] else { break }
                weights[Int(current)] *= thinning
                guard let next = vertexEdges[Int(current)].map({ otherEnd($0, from: current) }).first(where: { $0 != previous }) else { break }
                previous = current
                current = next
            }
        }
        return weights
    }

    var bendCount: Int {
        var count = 0
        for i in isBend.indices where isBend[i] && vertexAlive[i] { count += 1 }
        return count
    }

    /// Anything that isn't simply passing along a line is a real point, whatever made it so.
    mutating func settleBends() {
        for i in isBend.indices where isBend[i] && (!vertexAlive[i] || vertexEdges[i].count != 2) { setBend(VertexID(i), false) }
    }

    /// Quads have straight sides. The curve they were drawn with has done its job.
    /// Under a mirror the two sides go straight together or not at all, so they can't drift apart.
    @discardableResult
    mutating func straightenQuads(mirrored: Bool) -> [StraightenedSide] {
        var quads = aliveFaces.filter(isQuad)
        var bends = Set(quads.flatMap { loop($0).filter { isBend[Int($0)] } })
        while mirrored {
            let waiting = quads.filter { f in
                loop(f).contains { v in
                    let partner = mirrorPartner[Int(v)]
                    return isBend[Int(v)] && partner >= 0 && partner != v && !bends.contains(VertexID(partner))
                }
            }
            guard !waiting.isEmpty else { break }
            quads.removeAll(where: waiting.contains)
            bends = Set(quads.flatMap { loop($0).filter { isBend[Int($0)] } })
        }
        var sides: [StraightenedSide] = []
        var noted = Set<VertexID>()
        for f in quads {
            let loop = self.loop(f)
            guard let first = loop.firstIndex(where: { !isBend[Int($0)] }) else { continue }
            var path = [loop[first]]
            for offset in 1...loop.count {
                let v = loop[(first + offset) % loop.count]
                path.append(v)
                guard !isBend[Int(v)] else { continue }
                if path.count > 2, noted.insert(path[1]).inserted {
                    sides.append(StraightenedSide(a: path[0], b: v, curve: path.map(position)))
                }
                path = [v]
            }
        }
        for v in bends where isVertexAlive(v) { try? dissolveVertex(v) }
        return sides
    }

    /// The mesh as it leaves the app, with straight edges between real points. A shape with too few
    /// corners to stand without its curve, a side wrapping too far round, or a closed line with no
    /// corners keeps it.
    func withoutBends() -> Mesh {
        var keep = Set<VertexID>()
        for f in aliveFaces {
            if cornerCount(of: f) < 3 {
                keep.formUnion(loop(f))
            } else {
                keep.formUnion(curvedSides(of: f).joined())
            }
        }
        for start in aliveVertices where isBend[Int(start)] && !keep.contains(start) {
            var path = [start]
            var previous = start, current = otherEnd(edgesOf(start)[0], from: start)
            while isBend[Int(current)], current != start {
                path.append(current)
                let edges = edgesOf(current)
                let next = otherEnd(edges[0], from: current) == previous ? otherEnd(edges[1], from: current) : otherEnd(edges[0], from: current)
                previous = current
                current = next
            }
            if current == start { keep.formUnion(path) }
        }
        var out = self
        for v in aliveVertices where isBend[Int(v)] && !keep.contains(v) { try? out.dissolveVertex(v) }
        return out
    }

    /// What goes in an exported file. Lines that aren't part of a face yet stay in the project, but
    /// aren't part of the model until they are.
    func forExport() -> Mesh {
        var out = withoutBends()
        out.deleteEdges(Set(out.aliveEdges.filter(out.isWire)))
        out.deleteVertices(Set(out.aliveVertices.filter { out.edgesOf($0).isEmpty }))
        return out
    }
}
