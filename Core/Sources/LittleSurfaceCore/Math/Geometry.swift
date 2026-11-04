import simd

public typealias Vec3 = SIMD3<Float>
public typealias Vec2 = SIMD2<Float>
public typealias Vec4 = SIMD4<Float>
public typealias Mat4 = simd_float4x4

public struct Ray {
    public var origin: Vec3
    public var direction: Vec3
    public init(origin: Vec3, direction: Vec3) {
        self.origin = origin
        self.direction = direction
    }
    public func at(_ t: Float) -> Vec3 { origin + direction * t }
}

public struct AABB: Equatable {
    public var minCorner: Vec3
    public var maxCorner: Vec3

    public static let empty = AABB(minCorner: Vec3(repeating: .infinity), maxCorner: Vec3(repeating: -.infinity))

    public init(minCorner: Vec3, maxCorner: Vec3) {
        self.minCorner = minCorner
        self.maxCorner = maxCorner
    }

    public init<S: Sequence>(points: S) where S.Element == Vec3 {
        self = .empty
        for p in points { grow(p) }
    }

    public mutating func grow(_ p: Vec3) {
        minCorner = simd_min(minCorner, p)
        maxCorner = simd_max(maxCorner, p)
    }

    public mutating func grow(_ b: AABB) {
        minCorner = simd_min(minCorner, b.minCorner)
        maxCorner = simd_max(maxCorner, b.maxCorner)
    }

    public var isEmpty: Bool { minCorner.x > maxCorner.x }
    public var center: Vec3 { (minCorner + maxCorner) * 0.5 }
    public var extent: Vec3 { maxCorner - minCorner }
    public var diagonal: Float { isEmpty ? 0 : simd_length(extent) }

    /// Half the box surface area, which is all the SAH needs.
    public var halfArea: Float {
        let e = simd_max(extent, Vec3(repeating: 0))
        return e.x * e.y + e.y * e.z + e.z * e.x
    }

    public func distanceSquared(to p: Vec3) -> Float {
        let d = simd_max(simd_max(minCorner - p, p - maxCorner), Vec3(repeating: 0))
        return simd_dot(d, d)
    }

    public func expanded(by amount: Float) -> AABB {
        AABB(minCorner: minCorner - Vec3(repeating: amount), maxCorner: maxCorner + Vec3(repeating: amount))
    }

    public func intersects(_ other: AABB) -> Bool {
        all(minCorner .<= other.maxCorner) && all(other.minCorner .<= maxCorner)
    }
}

public struct ClosestSegmentResult {
    public var s: Float
    public var t: Float
    public var distance: Float
}

public enum GeometryMath {
    /// Closest point on triangle (a, b, c) to p, returned with barycentric weights for (a, b, c).
    /// Ericson, Real-Time Collision Detection, 5.1.5.
    @inline(__always)
    public static func closestPointOnTriangle(_ p: Vec3, _ a: Vec3, _ b: Vec3, _ c: Vec3) -> (point: Vec3, bary: Vec3) {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return (a, Vec3(1, 0, 0)) }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return (b, Vec3(0, 1, 0)) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 {
            let v = d1 / (d1 - d3)
            return (a + ab * v, Vec3(1 - v, v, 0))
        }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return (c, Vec3(0, 0, 1)) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 {
            let w = d2 / (d2 - d6)
            return (a + ac * w, Vec3(1 - w, 0, w))
        }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return (b + (c - b) * w, Vec3(0, 1 - w, w))
        }
        let denom = 1 / (va + vb + vc)
        let v = vb * denom, w = vc * denom
        return (a + ab * v + ac * w, Vec3(1 - v - w, v, w))
    }

    /// Möller–Trumbore. Two-sided: the viewport decides what counts as a back face.
    @inline(__always)
    public static func intersectTriangle(_ ray: Ray, _ a: Vec3, _ b: Vec3, _ c: Vec3, tMax: Float) -> (t: Float, u: Float, v: Float)? {
        let e1 = b - a, e2 = c - a
        let p = simd_cross(ray.direction, e2)
        let det = simd_dot(e1, p)
        if abs(det) < 1e-12 { return nil }
        let inv = 1 / det
        let s = ray.origin - a
        let u = simd_dot(s, p) * inv
        if u < 0 || u > 1 { return nil }
        let q = simd_cross(s, e1)
        let v = simd_dot(ray.direction, q) * inv
        if v < 0 || u + v > 1 { return nil }
        let t = simd_dot(e2, q) * inv
        if t <= 1e-6 || t >= tMax { return nil }
        return (t, u, v)
    }

    public static func closestPointOnSegment(_ p: Vec3, _ a: Vec3, _ b: Vec3) -> (point: Vec3, t: Float) {
        let ab = b - a
        let len2 = simd_length_squared(ab)
        if len2 < 1e-20 { return (a, 0) }
        let t = simd_clamp(simd_dot(p - a, ab) / len2, 0, 1)
        return (a + ab * t, t)
    }

    /// Closest approach between segments p1-q1 and p2-q2. Ericson 5.1.9.
    public static func closestBetweenSegments(_ p1: Vec3, _ q1: Vec3, _ p2: Vec3, _ q2: Vec3) -> ClosestSegmentResult {
        let d1 = q1 - p1, d2 = q2 - p2, r = p1 - p2
        let a = simd_dot(d1, d1), e = simd_dot(d2, d2), f = simd_dot(d2, r)
        var s: Float = 0, t: Float = 0
        let eps: Float = 1e-12
        if a <= eps && e <= eps {
            return ClosestSegmentResult(s: 0, t: 0, distance: simd_length(r))
        }
        if a <= eps {
            t = simd_clamp(f / e, 0, 1)
        } else {
            let c = simd_dot(d1, r)
            if e <= eps {
                s = simd_clamp(-c / a, 0, 1)
            } else {
                let b = simd_dot(d1, d2)
                let denom = a * e - b * b
                s = denom > eps ? simd_clamp((b * f - c * e) / denom, 0, 1) : 0
                t = (b * s + f) / e
                if t < 0 {
                    t = 0
                    s = simd_clamp(-c / a, 0, 1)
                } else if t > 1 {
                    t = 1
                    s = simd_clamp((b - c) / a, 0, 1)
                }
            }
        }
        let c1 = p1 + d1 * s, c2 = p2 + d2 * t
        return ClosestSegmentResult(s: s, t: t, distance: simd_length(c1 - c2))
    }

    /// Newell's method: stable for non-planar polygons, magnitude is twice the area.
    public static func newellNormal<C: Collection>(_ points: C) -> Vec3 where C.Element == Vec3 {
        var n = Vec3(repeating: 0)
        guard var prev = points.reversed().first else { return n }
        for p in points {
            n.x += (prev.y - p.y) * (prev.z + p.z)
            n.y += (prev.z - p.z) * (prev.x + p.x)
            n.z += (prev.x - p.x) * (prev.y + p.y)
            prev = p
        }
        return n
    }

    public static func safeNormalize(_ v: Vec3, fallback: Vec3 = Vec3(0, 1, 0)) -> Vec3 {
        let l = simd_length(v)
        return l > 1e-12 ? v / l : fallback
    }

    /// Any unit vector perpendicular to n.
    public static func perpendicular(to n: Vec3) -> Vec3 {
        let axis = abs(n.x) < 0.8 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)
        return safeNormalize(simd_cross(n, axis))
    }

    /// Triangle-triangle overlap via edge-versus-triangle ray tests, which is enough for flagging
    /// potential self-intersections. Coplanar overlaps are intentionally not reported.
    public static func trianglesIntersect(_ a: (Vec3, Vec3, Vec3), _ b: (Vec3, Vec3, Vec3)) -> Bool {
        func edgeHits(_ p: Vec3, _ q: Vec3, _ t: (Vec3, Vec3, Vec3)) -> Bool {
            let d = q - p
            let len = simd_length(d)
            if len < 1e-12 { return false }
            let ray = Ray(origin: p, direction: d / len)
            return intersectTriangle(ray, t.0, t.1, t.2, tMax: len) != nil
        }
        return edgeHits(a.0, a.1, b) || edgeHits(a.1, a.2, b) || edgeHits(a.2, a.0, b)
            || edgeHits(b.0, b.1, a) || edgeHits(b.1, b.2, a) || edgeHits(b.2, b.0, a)
    }

    /// Point-in-polygon on a 2D ring (even-odd).
    public static func pointInPolygon(_ p: Vec2, _ ring: [Vec2]) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}

public extension Mat4 {
    static let identity = matrix_identity_float4x4

    /// Right-handed perspective with Metal's 0...1 clip depth.
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> Mat4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return Mat4(columns: (
            Vec4(x, 0, 0, 0),
            Vec4(0, y, 0, 0),
            Vec4(0, 0, z, -1),
            Vec4(0, 0, z * near, 0)
        ))
    }

    static func orthographic(halfHeight: Float, aspect: Float, near: Float, far: Float) -> Mat4 {
        let y = 1 / halfHeight
        let x = y / aspect
        let z = 1 / (near - far)
        return Mat4(columns: (
            Vec4(x, 0, 0, 0),
            Vec4(0, y, 0, 0),
            Vec4(0, 0, z, 0),
            Vec4(0, 0, z * near, 1)
        ))
    }

    func transformPoint(_ p: Vec3) -> Vec3 {
        let v = self * Vec4(p.x, p.y, p.z, 1)
        return Vec3(v.x, v.y, v.z)
    }

    func transformDirection(_ d: Vec3) -> Vec3 {
        let v = self * Vec4(d.x, d.y, d.z, 0)
        return Vec3(v.x, v.y, v.z)
    }

    var upperLeft3x3: simd_float3x3 {
        simd_float3x3(
            Vec3(columns.0.x, columns.0.y, columns.0.z),
            Vec3(columns.1.x, columns.1.y, columns.1.z),
            Vec3(columns.2.x, columns.2.y, columns.2.z)
        )
    }
}
