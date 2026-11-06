import Foundation
import simd

public struct BrushSettings: Equatable, Codable {
    /// Screen radius in points, so a brush always feels the same size under the Pencil.
    public var radiusPoints: Float = 36
    public var strength: Float = 0.5
    public var usesPressure = true
    public init() {}
}

/// One brush dab, already resolved to the surface.
public struct BrushStamp {
    public var center: Vec3
    public var worldRadius: Float
    public var strength: Float
    public var normal: Vec3

    public init(center: Vec3, worldRadius: Float, strength: Float, normal: Vec3) {
        self.center = center
        self.worldRadius = worldRadius
        self.strength = strength
        self.normal = normal
    }

    /// Smooth falloff from 1 at the center to 0 at the rim.
    @inline(__always)
    func weight(at p: Vec3) -> Float {
        let d = simd_length(p - center) / worldRadius
        guard d < 1 else { return 0 }
        let f = 1 - d * d
        return f * f
    }
}

/// Follows the Pencil along one stretch of surface. Where the next hit is on another part of the model,
/// such as the lower lip showing past the upper one, it holds until the Pencil comes back, so what's
/// being moved never leaps across the gap.
struct SurfaceTrack {
    /// A surface inclined 84° from the screen stretches distances about tenfold.
    private static let stretch: Float = 10
    /// How closely the Pencil has to come back, having left.
    private static let returning: Float = 2

    private(set) var position: Vec3
    private var screen: Vec2
    private var isAway = false

    init(position: Vec3, screen: Vec2) {
        self.position = position
        self.screen = screen
    }

    /// The Pencil has gone off the model.
    mutating func leave() { isAway = true }

    /// Whether a hit carries on from the last one, which it then becomes.
    mutating func follow(to hit: Vec3, screen next: Vec2, worldPerPoint: Float) -> Bool {
        let limit = isAway ? Self.returning : Self.stretch
        guard simd_length(hit - position) <= max(simd_length(next - screen), 1.5) * worldPerPoint * limit else {
            isAway = true
            return false
        }
        position = hit
        screen = next
        isAway = false
        return true
    }
}

public enum Brushes {
    /// Vertices affected by a stamp, on the same side of the surface as the stamp.
    static func affected(_ mesh: Mesh, stamp: BrushStamp) -> [(VertexID, Float)] {
        var out: [(VertexID, Float)] = []
        for v in mesh.aliveVertices {
            let p = mesh.position(v)
            let w = stamp.weight(at: p)
            guard w > 0 else { continue }
            let n = mesh.vertexNormal(v)
            if simd_length_squared(n) > 0 && simd_dot(n, stamp.normal) < -0.2 { continue }
            out.append((v, w))
        }
        return out
    }

    /// Relax brush: evens out vertex spacing under the brush, staying on the surface.
    public static func relax(_ mesh: inout Mesh, stamp: BrushStamp, projector: SurfaceProjector?, snap: Bool, symmetry: SymmetrySettings) {
        let targets = affected(mesh, stamp: stamp)
        var updates: [(VertexID, Vec3)] = []
        updates.reserveCapacity(targets.count)
        for (v, w) in targets {
            let boundary = mesh.isBoundaryVertex(v)
            var sum = Vec3(repeating: 0)
            var count: Float = 0
            for e in mesh.edgesOf(v) {
                if boundary && mesh.faceCountOf(edge: e) == 2 { continue }
                sum += mesh.position(mesh.otherEnd(e, from: v))
                count += 1
            }
            guard count > 1 else { continue }
            let p = mesh.position(v)
            let moved = p + (sum / count - p) * (stamp.strength * w)
            updates.append((v, mesh.reprojected(moved, near: v, projector: snap ? projector : nil)))
        }
        apply(updates, to: &mesh, projector: snap ? projector : nil, symmetry: symmetry, radius: stamp.worldRadius)
    }

    /// Move brush: pushes vertices along the surface by the world-space drag.
    public static func move(_ mesh: inout Mesh, stamp: BrushStamp, delta: Vec3, projector: SurfaceProjector?, snap: Bool, symmetry: SymmetrySettings) {
        let targets = affected(mesh, stamp: stamp)
        var updates: [(VertexID, Vec3)] = []
        updates.reserveCapacity(targets.count)
        for (v, w) in targets {
            let moved = mesh.position(v) + delta * w * stamp.strength
            updates.append((v, mesh.reprojected(moved, near: v, projector: snap ? projector : nil)))
        }
        apply(updates, to: &mesh, projector: snap ? projector : nil, symmetry: symmetry, radius: stamp.worldRadius)
    }

    /// Writes positions, keeping the centerline on the plane and mirror partners following.
    static func apply(_ updates: [(VertexID, Vec3)], to mesh: inout Mesh, projector: SurfaceProjector?, symmetry: SymmetrySettings, radius: Float) {
        guard let plane = symmetry.activePlane else {
            mesh.setPositions(updates)
            return
        }
        var out: [(VertexID, Vec3)] = []
        out.reserveCapacity(updates.count * 2)
        var written = Set<VertexID>()
        for (v, p) in updates {
            let partner = mesh.mirrorPartner[Int(v)]
            if partner == v {
                out.append((v, plane.snap(p)))
                written.insert(v)
                continue
            }
            if written.contains(v) { continue }
            out.append((v, p))
            written.insert(v)
            if partner >= 0 {
                let n = mesh.vertexNormal(v)
                let q = Symmetry.mirroredPosition(of: p, normal: n, plane: plane, projector: projector, searchRadius: radius * 2)
                out.append((partner, q))
                written.insert(partner)
            }
        }
        mesh.setPositions(out)
    }
}
