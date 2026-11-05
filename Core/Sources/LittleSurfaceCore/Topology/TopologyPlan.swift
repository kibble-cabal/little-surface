import Foundation
import simd

/// A vertex a plan will use, whether it exists yet or not.
public enum PlanNode: Equatable {
    case existing(VertexID)
    /// A new vertex placed on an existing edge, at fraction `t` from the edge's first end.
    case split(edge: EdgeID, t: Float, position: Vec3)
    case new(position: Vec3, normal: Vec3)
}

/// A proposed change to the topology: previewable before commit, and applied in one place.
/// Drawn strokes, quad strips, quad patches and manual faces all reduce to this, so snapping, edge
/// splitting and symmetry only have one implementation.
public struct TopologyPlan {
    public var nodes: [PlanNode] = []
    public var edges: [SIMD2<Int32>] = []
    public var faces: [[Int32]] = []
    /// Wire edges that this plan replaces. Vertices they leave with no edges go with them.
    public var removeEdges: [EdgeID] = []
    /// Nodes that only shape a drawn line. Every other node this plan touches is a real point.
    public var bends: Set<Int32> = []
    /// Plain-language notes for the artist, such as "stopped at existing faces".
    public var notes: [String] = []

    public init() {}

    public var isEmpty: Bool { edges.isEmpty && faces.isEmpty }

    public func position(of index: Int, in mesh: Mesh) -> Vec3 {
        switch nodes[index] {
        case .existing(let v): return mesh.position(v)
        case .split(_, _, let p): return p
        case .new(let p, _): return p
        }
    }

    public func positions(in mesh: Mesh) -> [Vec3] {
        (0..<nodes.count).map { position(of: $0, in: mesh) }
    }
}

public struct PlanResult: Equatable {
    public var vertices: [VertexID] = []
    public var edges: [EdgeID] = []
    public var faces: [FaceID] = []
    /// Which real vertex each plan node became.
    public var nodeVertices: [VertexID] = []
    public init() {}
}

public enum PlanApplier {
    /// Applies a plan to the mesh. On throw the caller's mesh is untouched, because the work happens
    /// on a copy; mirroring happens here so every tool gets it the same way.
    public static func apply(
        _ plan: TopologyPlan,
        to mesh: inout Mesh,
        symmetry: SymmetrySettings = SymmetrySettings(),
        projector: SurfaceProjector? = nil
    ) throws -> PlanResult {
        var work = mesh
        var result = PlanResult()
        let plane = symmetry.activePlane
        let searchRadius = max(max(work.bounds.diagonal, projector?.bounds.diagonal ?? 0) * 0.05, symmetry.centerTolerance * 4)

        var leftBehind = Set<VertexID>()
        func remove(_ e: EdgeID) {
            let (a, b) = work.ends(e)
            leftBehind.formUnion([a, b])
            work.removeEdge(e)
        }
        for e in plan.removeEdges where work.isEdgeAlive(e) {
            guard work.isWire(e) else {
                throw MeshError.invalid("This would replace an edge that belongs to a face.")
            }
            let mirror = plane != nil ? Symmetry.mirrorEdge(of: e, in: work) : nil
            remove(e)
            if let mirror, mirror != e, work.isEdgeAlive(mirror), work.isWire(mirror) { remove(mirror) }
        }

        var nodeVertices = [VertexID](repeating: invalidID, count: plan.nodes.count)

        // Splits on one edge run from the far end back, because the original edge keeps its first end.
        var splitsByEdge = [EdgeID: [(node: Int, t: Float, position: Vec3)]]()
        for (i, node) in plan.nodes.enumerated() {
            switch node {
            case .existing(let v):
                guard work.isVertexAlive(v) else { throw MeshError.staleElement }
                nodeVertices[i] = v
            case .split(let e, let t, let p):
                splitsByEdge[e, default: []].append((i, t, p))
            case .new:
                break
            }
        }
        for edge in splitsByEdge.keys.sorted() {
            let splits = splitsByEdge[edge]!.sorted { $0.t > $1.t }
            var upper: Float = 1
            for split in splits {
                let local = split.t / max(upper, 1e-6)
                let v = try splitWithMirror(edge: edge, t: local, position: split.position, mesh: &work, plane: plane, tolerance: symmetry.centerTolerance, projector: projector, searchRadius: searchRadius)
                nodeVertices[split.node] = v
                result.vertices.append(v)
                upper = split.t
            }
        }

        var freshNodes: [Int] = []
        for (i, node) in plan.nodes.enumerated() {
            guard case .new(let p, _) = node else { continue }
            var position = p
            var onPlane = false
            if let plane, abs(plane.signedDistance(p)) <= symmetry.centerTolerance {
                position = plane.snap(p)
                onPlane = true
            }
            let v = work.addVertex(position)
            if onPlane { work.setMirrorPartner(v, v) }
            nodeVertices[i] = v
            result.vertices.append(v)
            freshNodes.append(i)
        }

        if let plane {
            // A plan may span the plane, as a patch between mirrored chains does. Its own nodes can
            // then be each other's mirror image, and pairing them avoids a doubled half.
            pairFreshNodes(freshNodes, plan: plan, nodeVertices: nodeVertices, mesh: &work, plane: plane, tolerance: max(symmetry.centerTolerance * 2, spacing(of: plan, in: work) * 0.2))
        }

        for pair in plan.edges {
            let a = nodeVertices[Int(pair.x)], b = nodeVertices[Int(pair.y)]
            guard a != b else { continue }
            let existed = work.edge(between: a, b) != nil
            let e = try work.ensureEdge(a, b)
            if !existed { result.edges.append(e) }
        }
        for face in plan.faces {
            result.faces.append(try work.addFace(face.map { nodeVertices[Int($0)] }))
        }

        if let plane {
            func partner(_ v: VertexID) -> VertexID {
                let existing = work.mirrorPartner[Int(v)]
                if existing >= 0 { return existing }
                let p = work.position(v)
                if abs(plane.signedDistance(p)) <= symmetry.centerTolerance {
                    work.setPosition(v, plane.snap(p))
                    work.setMirrorPartner(v, v)
                    return v
                }
                let normal = normalHint(for: v, plan: plan, nodeVertices: nodeVertices, mesh: work)
                let q = Symmetry.mirroredPosition(of: p, normal: normal, plane: plane, projector: projector, searchRadius: searchRadius)
                let m = work.addVertex(q)
                work.setMirrorPartner(v, m)
                work.setMirrorPartner(m, v)
                result.vertices.append(m)
                return m
            }
            for pair in plan.edges {
                let a = nodeVertices[Int(pair.x)], b = nodeVertices[Int(pair.y)]
                guard a != b else { continue }
                let ma = partner(a), mb = partner(b)
                guard ma != mb else { continue }
                let existed = work.edge(between: ma, mb) != nil
                let e = try work.ensureEdge(ma, mb)
                if !existed { result.edges.append(e) }
            }
            for f in result.faces {
                let loop = work.loop(f)
                let mapped = Array(loop.reversed()).map { partner($0) }
                if Set(mapped) == Set(loop) || work.findFace(withVertices: mapped) != nil { continue }
                do {
                    result.faces.append(try work.addFace(mapped))
                } catch {
                    throw MeshError.invalid("The mirrored side of this would make the mesh non-manifold, so nothing was changed. Try turning symmetry off for this part.")
                }
            }
        }

        for (i, node) in plan.nodes.enumerated() {
            if plan.bends.contains(Int32(i)) {
                work.setBend(nodeVertices[i], true)
            } else if case .existing(let v) = node {
                work.setBend(v, false)
            }
            let partner = work.mirrorPartner[Int(nodeVertices[i])]
            if partner >= 0, partner != nodeVertices[i] { work.setBend(partner, work.isBend[Int(nodeVertices[i])]) }
        }

        let stranded = leftBehind.filter { work.isVertexAlive($0) && work.edgesOf($0).isEmpty && !nodeVertices.contains($0) }
        if !stranded.isEmpty { work.deleteVertices(stranded) }

        result.nodeVertices = nodeVertices
        mesh = work
        return result
    }

    private static func normalHint(for v: VertexID, plan: TopologyPlan, nodeVertices: [VertexID], mesh: Mesh) -> Vec3? {
        if let i = nodeVertices.firstIndex(of: v), case .new(_, let n) = plan.nodes[i] { return n }
        let n = mesh.vertexNormal(v)
        return simd_length_squared(n) > 0 ? n : nil
    }

    private static func spacing(of plan: TopologyPlan, in mesh: Mesh) -> Float {
        guard let edge = plan.edges.first else {
            guard let face = plan.faces.first, face.count > 1 else { return 0 }
            return simd_length(plan.position(of: Int(face[0]), in: mesh) - plan.position(of: Int(face[1]), in: mesh))
        }
        return simd_length(plan.position(of: Int(edge.x), in: mesh) - plan.position(of: Int(edge.y), in: mesh))
    }

    private static func pairFreshNodes(_ fresh: [Int], plan: TopologyPlan, nodeVertices: [VertexID], mesh: inout Mesh, plane: MirrorPlane, tolerance: Float) {
        guard fresh.count > 1, tolerance > 0 else { return }
        let cell = tolerance
        func key(_ p: Vec3) -> SIMD3<Int32> {
            let q = p / cell
            return SIMD3<Int32>(Int32(q.x.rounded(.down)), Int32(q.y.rounded(.down)), Int32(q.z.rounded(.down)))
        }
        var grid = [SIMD3<Int32>: [VertexID]]()
        for i in fresh where mesh.mirrorPartner[Int(nodeVertices[i])] < 0 {
            let v = nodeVertices[i]
            grid[key(mesh.position(v)), default: []].append(v)
        }
        for i in fresh {
            let v = nodeVertices[i]
            guard mesh.mirrorPartner[Int(v)] < 0 else { continue }
            let target = plane.reflect(mesh.position(v))
            let base = key(target)
            var best = invalidID
            var bestDistance = tolerance
            for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        guard let bucket = grid[base &+ SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))] else { continue }
                        for candidate in bucket where candidate != v && mesh.mirrorPartner[Int(candidate)] < 0 {
                            let d = simd_length(mesh.position(candidate) - target)
                            if d <= bestDistance {
                                bestDistance = d
                                best = candidate
                            }
                        }
                    }
                }
            }
            if best >= 0 {
                mesh.setMirrorPartner(v, best)
                mesh.setMirrorPartner(best, v)
            }
        }
    }

    /// Splits an edge and, under symmetry, its mirror image at the mirrored place.
    private static func splitWithMirror(
        edge e: EdgeID,
        t: Float,
        position: Vec3,
        mesh: inout Mesh,
        plane: MirrorPlane?,
        tolerance: Float,
        projector: SurfaceProjector?,
        searchRadius: Float
    ) throws -> VertexID {
        guard mesh.isEdgeAlive(e) else { throw MeshError.staleElement }
        guard let plane else { return try mesh.splitEdge(e, at: t, position: position).vertex }

        let (a, b) = mesh.ends(e)
        let pa = mesh.mirrorPartner[Int(a)], pb = mesh.mirrorPartner[Int(b)]
        let mirrorEdge = (pa >= 0 && pb >= 0) ? mesh.edge(between: pa, pb) : nil

        if abs(plane.signedDistance(position)) <= tolerance {
            let split = try mesh.splitEdge(e, at: t, position: plane.snap(position))
            mesh.setMirrorPartner(split.vertex, split.vertex)
            return split.vertex
        }
        let split = try mesh.splitEdge(e, at: t, position: position)
        guard let mirrorEdge else { return split.vertex }

        var targetEdge = mirrorEdge
        var targetT = t
        if mirrorEdge == e {
            // The edge crosses the plane and is its own mirror image: the partner point lies on one of
            // the two pieces the split just made.
            if t > 0.5 {
                targetT = (1 - t) / t
            } else {
                targetEdge = split.newEdge
                targetT = (1 - 2 * t) / (1 - t)
            }
        } else if mesh.ends(mirrorEdge).0 != pa {
            targetT = 1 - t
        }
        let hint = mesh.vertexNormal(split.vertex)
        let q = Symmetry.mirroredPosition(of: position, normal: hint, plane: plane, projector: projector, searchRadius: searchRadius)
        let other = try mesh.splitEdge(targetEdge, at: targetT, position: q)
        mesh.setMirrorPartner(split.vertex, other.vertex)
        mesh.setMirrorPartner(other.vertex, split.vertex)
        return split.vertex
    }
}
