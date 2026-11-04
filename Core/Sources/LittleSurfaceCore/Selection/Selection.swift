import Foundation
import simd

public enum SelectionMode: String, Codable, CaseIterable {
    case vertex, edge, face
}

public struct Selection: Equatable {
    public var mode = SelectionMode.vertex
    public var vertices = Set<VertexID>()
    public var edges = Set<EdgeID>()
    public var faces = Set<FaceID>()

    public init() {}

    public var isEmpty: Bool { vertices.isEmpty && edges.isEmpty && faces.isEmpty }
    public var activeCount: Int {
        switch mode {
        case .vertex: return vertices.count
        case .edge: return edges.count
        case .face: return faces.count
        }
    }

    public mutating func clear() {
        vertices.removeAll()
        edges.removeAll()
        faces.removeAll()
    }

    /// Drops anything that no longer exists, after edits that removed elements.
    public mutating func prune(in mesh: Mesh) {
        vertices = vertices.filter(mesh.isVertexAlive)
        edges = edges.filter(mesh.isEdgeAlive)
        faces = faces.filter(mesh.isFaceAlive)
    }

    /// All the vertices touched by the current selection, whichever mode made it.
    public func touchedVertices(in mesh: Mesh) -> Set<VertexID> {
        var out = vertices.filter(mesh.isVertexAlive)
        for e in edges where mesh.isEdgeAlive(e) {
            let (a, b) = mesh.ends(e)
            out.insert(a)
            out.insert(b)
        }
        for f in faces where mesh.isFaceAlive(f) { out.formUnion(mesh.loop(f)) }
        return out
    }

    public func bounds(in mesh: Mesh) -> AABB {
        AABB(points: touchedVertices(in: mesh).map { mesh.position($0) })
    }
}

public enum SelectionCommand: String, CaseIterable {
    case edgeLoop, edgeRing, connected, boundary
}

public enum SelectionTools {
    /// Follows `start` straight through vertices where the way ahead is unambiguous: valence 4 in a
    /// quad mesh, or valence 2 on a wire or along a boundary. Stops, or closes, otherwise.
    public static func edgeLoop(from start: EdgeID, in mesh: Mesh) -> Set<EdgeID> {
        guard mesh.isEdgeAlive(start) else { return [] }
        var out: Set<EdgeID> = [start]
        let (a, b) = mesh.ends(start)
        for origin in [b, a] {
            var e = start
            var v = origin
            while let next = straightContinuation(of: e, through: v, in: mesh), !out.contains(next) {
                out.insert(next)
                v = mesh.otherEnd(next, from: v)
                e = next
            }
        }
        return out
    }

    private static func straightContinuation(of e: EdgeID, through v: VertexID, in mesh: Mesh) -> EdgeID? {
        let edges = mesh.edgesOf(v)
        let faceCount = mesh.faceCountOf(edge: e)
        if faceCount < 2 {
            // Along a boundary or a wire, stay on edges of the same kind.
            let candidates = edges.filter { $0 != e && mesh.faceCountOf(edge: $0) == faceCount }
            return candidates.count == 1 ? candidates[0] : nil
        }
        guard edges.count == 4 else { return nil }
        // The straight-through edge is the one sharing no face with e.
        let faces = Set(mesh.facesOf(edge: e))
        let candidates = edges.filter { $0 != e && Set(mesh.facesOf(edge: $0)).isDisjoint(with: faces) }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Edges side by side across a strip of quads.
    public static func edgeRing(from start: EdgeID, in mesh: Mesh) -> Set<EdgeID> {
        guard mesh.isEdgeAlive(start) else { return [] }
        var out: Set<EdgeID> = [start]
        for f in mesh.facesOf(edge: start) {
            var e = start
            var face = f
            while mesh.loop(face).count == 4 {
                let edges = mesh.edgeLoop(face)
                guard let i = edges.firstIndex(of: e) else { break }
                let opposite = edges[(i + 2) % 4]
                guard out.insert(opposite).inserted else { break }
                guard let next = mesh.oppositeFace(across: opposite, from: face) else { break }
                e = opposite
                face = next
            }
        }
        return out
    }

    /// Every vertex connected to the seeds by any path of edges.
    public static func connectedVertices(from seeds: Set<VertexID>, in mesh: Mesh) -> Set<VertexID> {
        var out = seeds.filter(mesh.isVertexAlive)
        var stack = Array(out)
        while let v = stack.popLast() {
            for n in mesh.neighbors(of: v) where out.insert(n).inserted {
                stack.append(n)
            }
        }
        return out
    }

    /// Fills in `selection` for `mode` from a set of connected vertices.
    public static func select(vertices: Set<VertexID>, in mesh: Mesh, mode: SelectionMode, into selection: inout Selection, additive: Bool) {
        if !additive { selection.clear() }
        switch mode {
        case .vertex:
            selection.vertices.formUnion(vertices)
        case .edge:
            for e in mesh.aliveEdges {
                let (a, b) = mesh.ends(e)
                if vertices.contains(a) && vertices.contains(b) { selection.edges.insert(e) }
            }
        case .face:
            for f in mesh.aliveFaces where mesh.loop(f).allSatisfy(vertices.contains) {
                selection.faces.insert(f)
            }
        }
    }

    public static func boundaryEdges(in mesh: Mesh) -> Set<EdgeID> {
        Set(mesh.aliveEdges.filter { mesh.isBoundary($0) })
    }
}
