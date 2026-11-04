import Foundation
import simd

public enum MirrorAxis: Int, Codable, CaseIterable {
    case x = 0, y = 1, z = 2

    public var label: String {
        switch self {
        case .x: return "X"
        case .y: return "Y"
        case .z: return "Z"
        }
    }
}

public struct MirrorPlane: Equatable, Codable {
    public var axis: MirrorAxis
    public var offset: Float

    public init(axis: MirrorAxis = .x, offset: Float = 0) {
        self.axis = axis
        self.offset = offset
    }

    public func signedDistance(_ p: Vec3) -> Float { p[axis.rawValue] - offset }

    public func reflect(_ p: Vec3) -> Vec3 {
        var out = p
        out[axis.rawValue] = 2 * offset - p[axis.rawValue]
        return out
    }

    public func reflectDirection(_ d: Vec3) -> Vec3 {
        var out = d
        out[axis.rawValue] = -d[axis.rawValue]
        return out
    }

    public func snap(_ p: Vec3) -> Vec3 {
        var out = p
        out[axis.rawValue] = offset
        return out
    }
}

/// Document setting for live mirrored editing.
public struct SymmetrySettings: Equatable, Codable {
    public var isEnabled = false
    public var plane = MirrorPlane()
    /// Vertices closer than this to the plane snap onto it and become their own partner.
    public var centerTolerance: Float = 0.005

    public init() {}

    public var activePlane: MirrorPlane? { isEnabled ? plane : nil }
}

public enum Symmetry {
    /// Where the mirror image of a point lands: reflected, then projected onto the surface on its own
    /// side, so that a slightly asymmetrical sculpt keeps both halves on their own surface.
    public static func mirroredPosition(of p: Vec3, normal: Vec3?, plane: MirrorPlane, projector: SurfaceProjector?, searchRadius: Float) -> Vec3 {
        let reflected = plane.reflect(p)
        guard let projector, !projector.isEmpty else { return reflected }
        let hint = normal.flatMap { simd_length_squared($0) > 1e-8 ? plane.reflectDirection($0) : nil }
        if let projected = projector.project(reflected, normalHint: hint, maxDistance: searchRadius) {
            return projected.position
        }
        return reflected
    }

    /// Fills in missing partners: vertices on the plane pair with themselves, others with the nearest
    /// unpaired vertex at their mirror position. Used after set-based edits that created geometry on
    /// both sides independently, such as subdividing a mirrored selection.
    public static func repairPairs(in mesh: inout Mesh, plane: MirrorPlane, centerTolerance: Float, pairingTolerance: Float) {
        let cell = max(pairingTolerance, 1e-6)
        func key(_ p: Vec3) -> SIMD3<Int32> {
            let q = p / cell
            return SIMD3<Int32>(Int32(q.x.rounded(.down)), Int32(q.y.rounded(.down)), Int32(q.z.rounded(.down)))
        }
        var grid = [SIMD3<Int32>: [VertexID]]()
        for v in mesh.aliveVertices where mesh.mirrorPartner[Int(v)] < 0 {
            let p = mesh.position(v)
            if abs(plane.signedDistance(p)) <= centerTolerance {
                mesh.setPosition(v, plane.snap(p))
                mesh.setMirrorPartner(v, v)
            } else {
                grid[key(p), default: []].append(v)
            }
        }
        let unpaired = grid.values.flatMap { $0 }.sorted()
        for v in unpaired where mesh.mirrorPartner[Int(v)] < 0 {
            let target = plane.reflect(mesh.position(v))
            let base = key(target)
            var best: VertexID = invalidID
            var bestDistance = pairingTolerance
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

    /// Selected elements plus their mirror images.
    public static func expanded(vertices: Set<VertexID>, in mesh: Mesh) -> Set<VertexID> {
        var out = vertices
        for v in vertices where mesh.isVertexAlive(v) {
            let partner = mesh.mirrorPartner[Int(v)]
            if partner >= 0 { out.insert(partner) }
        }
        return out
    }

    public static func mirrorEdge(of e: EdgeID, in mesh: Mesh) -> EdgeID? {
        guard mesh.isEdgeAlive(e) else { return nil }
        let (a, b) = mesh.ends(e)
        let pa = mesh.mirrorPartner[Int(a)], pb = mesh.mirrorPartner[Int(b)]
        guard pa >= 0, pb >= 0 else { return nil }
        return mesh.edge(between: pa, pb)
    }

    public static func expanded(edges: Set<EdgeID>, in mesh: Mesh) -> Set<EdgeID> {
        var out = edges
        for e in edges {
            if let m = mirrorEdge(of: e, in: mesh) { out.insert(m) }
        }
        return out
    }

    public static func mirrorFace(of f: FaceID, in mesh: Mesh) -> FaceID? {
        guard mesh.isFaceAlive(f) else { return nil }
        var mapped: [VertexID] = []
        for v in mesh.loop(f) {
            let partner = mesh.mirrorPartner[Int(v)]
            guard partner >= 0 else { return nil }
            mapped.append(partner)
        }
        return mesh.findFace(withVertices: mapped)
    }

    public static func expanded(faces: Set<FaceID>, in mesh: Mesh) -> Set<FaceID> {
        var out = faces
        for f in faces {
            if let m = mirrorFace(of: f, in: mesh) { out.insert(m) }
        }
        return out
    }

    /// Makes symmetry real on the whole mesh: discards the side opposite `keepPositive`, copies the
    /// kept side across the plane with each mirrored vertex projected onto its own side of the source,
    /// and welds the centerline. The result is ordinary geometry with no further dependence on the
    /// live symmetry setting. Throws, leaving `mesh` untouched, if the result would be non-manifold.
    public static func apply(to mesh: inout Mesh, plane: MirrorPlane, centerTolerance: Float, keepPositive: Bool, projector: SurfaceProjector?) throws {
        var work = mesh
        let sign: Float = keepPositive ? 1 : -1
        let searchRadius = max(work.bounds.diagonal * 0.05, centerTolerance * 4)

        // Faces entirely on the discarded side go; so do wires and vertices left behind.
        for f in work.aliveFaces {
            let outside = work.loop(f).contains { plane.signedDistance(work.position($0)) * sign < -centerTolerance }
            if outside { work.removeFace(f) }
        }
        for e in work.aliveEdges {
            let (a, b) = work.ends(e)
            if plane.signedDistance(work.position(a)) * sign < -centerTolerance
                || plane.signedDistance(work.position(b)) * sign < -centerTolerance {
                work.removeEdge(e)
            }
        }
        for v in work.aliveVertices {
            if plane.signedDistance(work.position(v)) * sign < -centerTolerance { work.removeVertex(v) }
            else { work.setMirrorPartner(v, invalidID) }
        }

        // Snap the centerline, then create the other half.
        for v in work.aliveVertices where abs(plane.signedDistance(work.position(v))) <= centerTolerance {
            work.setPosition(v, plane.snap(work.position(v)))
            work.setMirrorPartner(v, v)
        }
        for v in work.aliveVertices where work.mirrorPartner[Int(v)] < 0 {
            let normal = work.vertexNormal(v)
            let p = mirroredPosition(of: work.position(v), normal: normal, plane: plane, projector: projector, searchRadius: searchRadius)
            let partner = work.addVertex(p)
            work.setMirrorPartner(v, partner)
            work.setMirrorPartner(partner, v)
        }
        let halfFaces = work.aliveFaces
        let halfEdges = work.aliveEdges
        for e in halfEdges where work.faceCountOf(edge: e) == 0 {
            let (a, b) = work.ends(e)
            try work.ensureEdge(work.mirrorPartner[Int(a)], work.mirrorPartner[Int(b)])
        }
        for f in halfFaces {
            let mapped = Array(work.loop(f).reversed()).map { work.mirrorPartner[Int($0)] }
            if work.findFace(withVertices: mapped) != nil { continue }
            do {
                try work.addFace(mapped, autoOrient: false)
            } catch {
                throw MeshError.invalid("Couldn't mirror this mesh without making it non-manifold. Check for faces crossing the symmetry plane; the mesh is unchanged.")
            }
        }
        mesh = work
    }
}
