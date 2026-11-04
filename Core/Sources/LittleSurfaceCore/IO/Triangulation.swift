import Foundation
import simd

public enum Triangulation {
    /// Triangulates a polygon given by its 3D corner positions, returning index triples into the
    /// corner list. Winding is preserved. Quads split along their shorter diagonal, and n-gons are
    /// ear-clipped after flattening onto their best-fit plane.
    public static func triangulate(_ points: [Vec3]) -> [SIMD3<Int32>] {
        let n = points.count
        guard n >= 3 else { return [] }
        if n == 3 { return [SIMD3<Int32>(0, 1, 2)] }
        if n == 4 {
            let d02 = simd_length_squared(points[0] - points[2])
            let d13 = simd_length_squared(points[1] - points[3])
            // A concave quad has one diagonal outside: choose the one that keeps both triangles upright.
            let normal = GeometryMath.newellNormal(points)
            let split02Valid = simd_dot(simd_cross(points[1] - points[0], points[2] - points[0]), normal) > 0
                && simd_dot(simd_cross(points[2] - points[0], points[3] - points[0]), normal) > 0
            let split13Valid = simd_dot(simd_cross(points[2] - points[1], points[3] - points[1]), normal) > 0
                && simd_dot(simd_cross(points[3] - points[1], points[0] - points[1]), normal) > 0
            let use02 = split02Valid && (!split13Valid || d02 <= d13)
            if use02 { return [SIMD3<Int32>(0, 1, 2), SIMD3<Int32>(0, 2, 3)] }
            return [SIMD3<Int32>(1, 2, 3), SIMD3<Int32>(1, 3, 0)]
        }

        let normal = GeometryMath.safeNormalize(GeometryMath.newellNormal(points))
        let u = GeometryMath.perpendicular(to: normal)
        let v = simd_cross(normal, u)
        let flat = points.map { Vec2(simd_dot($0, u), simd_dot($0, v)) }

        var remaining = Array(0..<n)
        var out: [SIMD3<Int32>] = []
        out.reserveCapacity(n - 2)
        func cross(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Float {
            let ab = b - a, ac = c - a
            return ab.x * ac.y - ab.y * ac.x
        }
        var guardCounter = 0
        while remaining.count > 3 && guardCounter < n * n {
            guardCounter += 1
            var clipped = false
            var bestEar = -1
            var bestQuality = -Float.infinity
            for i in 0..<remaining.count {
                let ia = remaining[(i + remaining.count - 1) % remaining.count]
                let ib = remaining[i]
                let ic = remaining[(i + 1) % remaining.count]
                let a = flat[ia], b = flat[ib], c = flat[ic]
                let area = cross(a, b, c)
                guard area > 1e-12 else { continue }
                var containsPoint = false
                for j in remaining where j != ia && j != ib && j != ic {
                    let p = flat[j]
                    if cross(a, b, p) >= 0 && cross(b, c, p) >= 0 && cross(c, a, p) >= 0 {
                        containsPoint = true
                        break
                    }
                }
                guard !containsPoint else { continue }
                // Prefer the fattest ear, which avoids slivers.
                let longest = max(simd_length_squared(a - b), max(simd_length_squared(b - c), simd_length_squared(c - a)))
                let quality = area / max(longest, 1e-12)
                if quality > bestQuality {
                    bestQuality = quality
                    bestEar = i
                }
            }
            if bestEar >= 0 {
                let i = bestEar
                let ia = remaining[(i + remaining.count - 1) % remaining.count]
                let ib = remaining[i]
                let ic = remaining[(i + 1) % remaining.count]
                out.append(SIMD3<Int32>(Int32(ia), Int32(ib), Int32(ic)))
                remaining.remove(at: i)
                clipped = true
            }
            if !clipped { break }
        }
        if remaining.count == 3 {
            out.append(SIMD3<Int32>(Int32(remaining[0]), Int32(remaining[1]), Int32(remaining[2])))
        } else if remaining.count > 3 {
            // A self-overlapping outline has no valid ears: fan what's left rather than losing faces.
            for i in 1..<(remaining.count - 1) {
                out.append(SIMD3<Int32>(Int32(remaining[0]), Int32(remaining[i]), Int32(remaining[i + 1])))
            }
        }
        return out
    }
}

/// A triangle mesh with per-vertex normals, used for GLB export and for the viewport.
public struct TriangleMeshData {
    public var positions: [Vec3] = []
    public var normals: [Vec3] = []
    public var indices: [UInt32] = []

    public init() {}

    public var triangleCount: Int { indices.count / 3 }
}

public extension Mesh {
    /// Triangulated copy with smooth vertex normals. The editable topology is untouched. Wire-only
    /// vertices are left out, since triangle output has nothing to attach them to.
    func triangulated() -> TriangleMeshData {
        let (poly, _) = polygonMesh()
        return poly.triangulated()
    }
}

public extension PolygonMesh {
    func triangulated() -> TriangleMeshData {
        var out = TriangleMeshData()
        out.positions = positions
        out.indices.reserveCapacity(faceIndices.count * 2)
        var sums = [Vec3](repeating: Vec3(repeating: 0), count: positions.count)
        for f in 0..<faceCount {
            let loop = Array(face(f))
            let corners = loop.map { positions[Int($0)] }
            let n = GeometryMath.newellNormal(corners)
            for v in loop { sums[Int(v)] += n }
            if loop.count == 3 {
                out.indices.append(contentsOf: loop)
            } else {
                for t in Triangulation.triangulate(corners) {
                    out.indices.append(loop[Int(t.x)])
                    out.indices.append(loop[Int(t.y)])
                    out.indices.append(loop[Int(t.z)])
                }
            }
        }
        out.normals = sums.map { GeometryMath.safeNormalize($0) }
        return out
    }
}
