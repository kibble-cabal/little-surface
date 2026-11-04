import Foundation
import simd

/// A point on the source surface, with its smooth normal. Positions handed to topology are always
/// built from these, never from screen-space guesses.
public struct SurfaceHit {
    public var position: Vec3
    public var normal: Vec3
    /// Distance along the ray, or distance from the query point for closest-point queries.
    public var distance: Float

    public init(position: Vec3, normal: Vec3, distance: Float = 0) {
        self.position = position
        self.normal = normal
        self.distance = distance
    }

    public func offsetPosition(_ offset: Float) -> Vec3 { position + normal * offset }
}

/// Immutable query layer over the snap-target source objects. Threads can share one freely.
public final class SurfaceProjector {
    private let bvhs: [TriangleBVH]
    public let bounds: AABB
    public var surfaceOffset: Float

    public init(bvhs: [TriangleBVH], surfaceOffset: Float = 0) {
        self.bvhs = bvhs
        self.surfaceOffset = surfaceOffset
        var box = AABB.empty
        for bvh in bvhs where bvh.triangleCount > 0 { box.grow(bvh.bounds) }
        bounds = box
    }

    public var isEmpty: Bool { bvhs.isEmpty }

    /// First surface the ray meets, across all snap targets.
    public func raycast(_ ray: Ray, tMax: Float = .infinity) -> SurfaceHit? {
        var best: TriangleBVH.Hit?
        var limit = tMax
        for bvh in bvhs {
            if let hit = bvh.raycast(ray, tMax: limit) {
                best = hit
                limit = hit.distance
            }
        }
        return best.map { SurfaceHit(position: $0.position, normal: $0.normal, distance: $0.distance) }
    }

    /// Closest surface point. With a hint, surfaces facing away from it are ignored.
    public func closest(to p: Vec3, normalHint: Vec3? = nil, minDot: Float = 0.1, maxDistance: Float = .infinity) -> SurfaceHit? {
        var best: TriangleBVH.Hit?
        var limit = maxDistance
        for bvh in bvhs {
            if let hit = bvh.closestPoint(to: p, maxDistance: limit, normalHint: normalHint, minDot: minDot) {
                best = hit
                limit = hit.distance
            }
        }
        return best.map { SurfaceHit(position: $0.position, normal: $0.normal, distance: $0.distance) }
    }

    /// Where a vertex near `p` should sit: on the surface, lifted by the surface offset.
    /// When nothing facing the hint is in reach the hint is dropped only if `strict` is false.
    public func project(_ p: Vec3, normalHint: Vec3? = nil, maxDistance: Float = .infinity, strict: Bool = false) -> (position: Vec3, normal: Vec3)? {
        if let hit = closest(to: p, normalHint: normalHint, maxDistance: maxDistance) {
            return (hit.offsetPosition(surfaceOffset), hit.normal)
        }
        if strict || normalHint == nil { return nil }
        guard let hit = closest(to: p, maxDistance: maxDistance) else { return nil }
        return (hit.offsetPosition(surfaceOffset), hit.normal)
    }

    /// Whether the source surface hides `p` when seen from `eye`. The tolerance lets a point sitting
    /// on the surface count as visible.
    public func isOccluded(_ p: Vec3, from eye: Vec3, tolerance: Float) -> Bool {
        let d = p - eye
        let len = simd_length(d)
        guard len > tolerance else { return false }
        let ray = Ray(origin: eye, direction: d / len)
        let limit = len - tolerance
        for bvh in bvhs where bvh.anyHit(ray, tMax: limit) { return true }
        return false
    }
}
