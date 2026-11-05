import Foundation
import simd

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

    func isQuad(_ f: FaceID) -> Bool {
        guard cornerCount(of: f) == 4 else { return false }
        return curvedSides(of: f).isEmpty
    }

    /// The bends along each side of a face that wraps too far to go straight.
    func curvedSides(of f: FaceID) -> [[VertexID]] {
        let loop = self.loop(f)
        guard let first = loop.firstIndex(where: { !isBend[Int($0)] }), loop.contains(where: { isBend[Int($0)] }) else { return [] }
        var sides: [[VertexID]] = []
        var start = loop[first], previous = start, length: Float = 0, bends: [VertexID] = []
        for offset in 1...loop.count {
            let v = loop[(first + offset) % loop.count]
            length += simd_length(position(v) - position(previous))
            previous = v
            if isBend[Int(v)] {
                bends.append(v)
                continue
            }
            if !bends.isEmpty, length > simd_length(position(v) - position(start)) * Self.straightSideLimit { sides.append(bends) }
            start = v
            length = 0
            bends = []
        }
        return sides
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
    mutating func straightenQuads() {
        let bends = Set(aliveFaces.filter(isQuad).flatMap { loop($0).filter { isBend[Int($0)] } })
        for v in bends where isVertexAlive(v) { try? dissolveVertex(v) }
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
}
