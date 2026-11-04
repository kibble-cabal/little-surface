import Foundation
import simd

/// A run of connected edges, ordered from one end to the other. A closed chain's last vertex
/// connects back to its first, and `edges.count == vertices.count`.
public struct BoundaryChain: Equatable, Codable {
    public var vertices: [VertexID]
    public var edges: [EdgeID]
    public var isClosed: Bool

    public init(vertices: [VertexID], edges: [EdgeID], isClosed: Bool) {
        self.vertices = vertices
        self.edges = edges
        self.isClosed = isClosed
    }

    public var segmentCount: Int { edges.count }
    public func reversed() -> BoundaryChain {
        if isClosed {
            // Keep the same first vertex so that the closing edge stays last.
            let verts = [vertices[0]] + vertices[1...].reversed()
            let es = Array(edges.reversed())
            return BoundaryChain(vertices: verts, edges: es, isClosed: true)
        }
        return BoundaryChain(vertices: vertices.reversed(), edges: edges.reversed(), isClosed: false)
    }

    public func isAlive(in mesh: Mesh) -> Bool {
        vertices.allSatisfy(mesh.isVertexAlive) && edges.allSatisfy(mesh.isEdgeAlive)
    }
}

public enum ChainFinder {
    /// Edges a patch can attach to: those with a free side.
    private static func isOpen(_ e: EdgeID, _ mesh: Mesh) -> Bool {
        mesh.faceCountOf(edge: e) < 2
    }

    /// The chain through `edge`, extended in both directions along free edges until it meets a
    /// junction, an end, or itself.
    public static func chain(through edge: EdgeID, in mesh: Mesh) -> BoundaryChain? {
        guard mesh.isEdgeAlive(edge), isOpen(edge, mesh) else { return nil }
        let (a, b) = mesh.ends(edge)

        func walk(from start: VertexID, avoiding first: EdgeID, stopAt stop: VertexID) -> (verts: [VertexID], edges: [EdgeID], closed: Bool) {
            var verts: [VertexID] = []
            var edges: [EdgeID] = []
            var current = start
            var previous = first
            while true {
                let open = mesh.edgesOf(current).filter { $0 != previous && isOpen($0, mesh) }
                guard open.count == 1 else { return (verts, edges, false) }
                let next = open[0]
                let other = mesh.otherEnd(next, from: current)
                edges.append(next)
                if other == stop { return (verts, edges, true) }
                verts.append(other)
                current = other
                previous = next
                if verts.count > mesh.vertexCount { return (verts, edges, false) }
            }
        }

        let forward = walk(from: b, avoiding: edge, stopAt: a)
        if forward.closed {
            return BoundaryChain(vertices: [a, b] + forward.verts, edges: [edge] + forward.edges, isClosed: true)
        }
        let backward = walk(from: a, avoiding: edge, stopAt: b)
        let vertices = Array(backward.verts.reversed()) + [a, b] + forward.verts
        let edges = Array(backward.edges.reversed()) + [edge] + forward.edges
        return BoundaryChain(vertices: vertices, edges: edges, isClosed: false)
    }

    /// Orders an arbitrary set of edges into a single chain, or nil if they don't form one.
    public static func chain(from edgeSet: Set<EdgeID>, in mesh: Mesh) -> BoundaryChain? {
        guard let seed = edgeSet.min() else { return nil }
        var uses = [VertexID: [EdgeID]]()
        for e in edgeSet {
            guard mesh.isEdgeAlive(e) else { return nil }
            let (a, b) = mesh.ends(e)
            uses[a, default: []].append(e)
            uses[b, default: []].append(e)
        }
        guard uses.values.allSatisfy({ $0.count <= 2 }) else { return nil }
        let ends = uses.filter { $0.value.count == 1 }.keys.sorted()
        guard ends.isEmpty || ends.count == 2 else { return nil }

        let isClosed = ends.isEmpty
        let startVertex = isClosed ? mesh.ends(seed).0 : ends[0]
        var vertices = [startVertex]
        var edges: [EdgeID] = []
        var current = startVertex
        var previous: EdgeID = invalidID
        while edges.count < edgeSet.count {
            guard let next = uses[current]?.first(where: { $0 != previous }) else { return nil }
            edges.append(next)
            let other = mesh.otherEnd(next, from: current)
            if edges.count == edgeSet.count && isClosed {
                guard other == startVertex else { return nil }
                break
            }
            vertices.append(other)
            current = other
            previous = next
        }
        return BoundaryChain(vertices: vertices, edges: edges, isClosed: isClosed)
    }

    /// The closed free-edge loops of the mesh: holes and outer boundaries.
    public static func boundaryLoops(in mesh: Mesh) -> [BoundaryChain] {
        var loops: [BoundaryChain] = []
        var visited = Set<EdgeID>()
        for e in mesh.aliveEdges where mesh.isBoundary(e) && !visited.contains(e) {
            guard let chain = boundaryLoop(through: e, in: mesh) else {
                visited.insert(e)
                continue
            }
            chain.edges.forEach { visited.insert($0) }
            loops.append(chain)
        }
        return loops
    }

    /// Walks boundary edges only, turning by face order at pinch points so wires can't derail it.
    public static func boundaryLoop(through edge: EdgeID, in mesh: Mesh) -> BoundaryChain? {
        guard mesh.isEdgeAlive(edge), mesh.isBoundary(edge) else { return nil }
        let (a, b) = mesh.ends(edge)
        var vertices = [a, b]
        var edges = [edge]
        var current = b
        var previous = edge
        while true {
            let next = mesh.edgesOf(current).filter { $0 != previous && mesh.isBoundary($0) }
            guard next.count == 1 else { return nil }
            let e = next[0]
            edges.append(e)
            let other = mesh.otherEnd(e, from: current)
            if other == a { return BoundaryChain(vertices: vertices, edges: edges, isClosed: true) }
            vertices.append(other)
            current = other
            previous = e
            if edges.count > mesh.edgeCount { return nil }
        }
    }
}
