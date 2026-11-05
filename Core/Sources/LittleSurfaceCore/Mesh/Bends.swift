import Foundation
import simd

/// A drawn line keeps its shape with bends: points that only follow the stroke and aren't corners of
/// anything. A line's real points are its ends, its sharp corners and wherever another line meets it.
/// Once a face has four real corners it's a quad, and its sides go straight.
public extension Mesh {
    func isBendVertex(_ v: VertexID) -> Bool { isBend[Int(v)] }

    mutating func setBend(_ v: VertexID, _ bend: Bool) { isBend[Int(v)] = bend }

    /// A face's real corners.
    func cornerCount(of f: FaceID) -> Int { loop(f).reduce(0) { $0 + (isBend[Int($1)] ? 0 : 1) } }

    func isQuad(_ f: FaceID) -> Bool { cornerCount(of: f) == 4 }

    var bendCount: Int {
        var count = 0
        for i in isBend.indices where isBend[i] && vertexAlive[i] { count += 1 }
        return count
    }

    /// Anything that isn't simply passing along a line is a real point, whatever made it so.
    mutating func settleBends() {
        for i in isBend.indices where isBend[i] && (!vertexAlive[i] || vertexEdges[i].count != 2) { isBend[i] = false }
    }

    /// Quads have straight sides. The curve they were drawn with has done its job.
    mutating func straightenQuads() {
        let bends = aliveFaces.filter(isQuad).flatMap { loop($0).filter { isBend[Int($0)] } }
        for v in bends where isVertexAlive(v) && isBend[Int(v)] { try? dissolveVertex(v) }
    }

    /// The mesh as it leaves the app, with straight edges between real points. A shape with too few
    /// corners to stand without its curve, or a closed line with none, keeps it.
    func withoutBends() -> Mesh {
        var keep = Set<VertexID>()
        for f in aliveFaces where cornerCount(of: f) < 3 { keep.formUnion(loop(f)) }
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
