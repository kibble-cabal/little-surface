import Foundation
import simd

/// One imported object from the source model, already flattened into world space. Source meshes are
/// never edited: they are only drawn and projected onto.
public struct SourceObject: Identifiable {
    public var id: UUID
    public var name: String
    public var positions: [Vec3]
    public var normals: [Vec3]
    public var indices: [UInt32]
    /// Shown in the viewport.
    public var isVisible: Bool = true
    /// Available as a surface to draw on and project to.
    public var isSnapTarget: Bool = true
    /// Changes whenever the geometry is replaced, so what's drawn from it knows to refresh.
    public var geometryRevision: UInt64 = 0

    public init(id: UUID = UUID(), name: String, positions: [Vec3], normals: [Vec3] = [], indices: [UInt32]) {
        self.id = id
        self.name = name
        self.positions = positions
        self.indices = indices
        self.normals = normals.count == positions.count ? normals : SourceObject.computeSmoothNormals(positions: positions, indices: indices)
    }

    public var triangleCount: Int { indices.count / 3 }

    /// All of these as one object, for a file that holds a sculpt in several parts.
    public static func merged(_ objects: [SourceObject], id: UUID = UUID(), name: String) -> SourceObject {
        var positions: [Vec3] = [], normals: [Vec3] = [], indices: [UInt32] = []
        for object in objects {
            let base = UInt32(positions.count)
            positions.append(contentsOf: object.positions)
            normals.append(contentsOf: object.normals)
            indices.append(contentsOf: object.indices.map { $0 + base })
        }
        return SourceObject(id: id, name: name, positions: positions, normals: normals, indices: indices)
    }
    public var bounds: AABB { AABB(points: positions) }

    /// Six times the signed volume. Only meaningful for closed meshes, which is what decides whether
    /// a model arrived inside-out.
    public var signedVolume: Float {
        var total: Float = 0
        indices.withUnsafeBufferPointer { idx in
            positions.withUnsafeBufferPointer { pos in
                var i = 0
                while i + 2 < idx.count {
                    total += simd_dot(pos[Int(idx[i])], simd_cross(pos[Int(idx[i + 1])], pos[Int(idx[i + 2])]))
                    i += 3
                }
            }
        }
        return total
    }

    /// Fraction of edges used exactly twice, weighing whether the signed volume can be trusted.
    /// Vertices are welded by position first, because glTF splits vertices at normal and UV seams.
    public var closedness: Float {
        guard !indices.isEmpty else { return 0 }
        let cell = max(bounds.diagonal * 1e-5, 1e-7)
        var welded = [SIMD3<Int32>: UInt32]()
        welded.reserveCapacity(positions.count)
        var remap = [UInt32](repeating: 0, count: positions.count)
        for (i, p) in positions.enumerated() {
            let key = SIMD3<Int32>(Int32((p.x / cell).rounded()), Int32((p.y / cell).rounded()), Int32((p.z / cell).rounded()))
            if let existing = welded[key] {
                remap[i] = existing
            } else {
                welded[key] = UInt32(i)
                remap[i] = UInt32(i)
            }
        }
        var uses = [UInt64: UInt8]()
        uses.reserveCapacity(indices.count)
        var i = 0
        while i + 2 < indices.count {
            for k in 0..<3 {
                let a = remap[Int(indices[i + k])], b = remap[Int(indices[i + (k + 1) % 3])]
                let key = (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
                uses[key, default: 0] &+= 1
            }
            i += 3
        }
        guard !uses.isEmpty else { return 0 }
        return Float(uses.values.filter { $0 == 2 }.count) / Float(uses.count)
    }

    /// Flips an inside-out closed mesh so that normals point outward, which surface offset and
    /// opposite-side protection both rely on.
    public mutating func normalizeOrientation() {
        guard closedness > 0.95, signedVolume < 0 else { return }
        var i = 0
        while i + 2 < indices.count {
            indices.swapAt(i + 1, i + 2)
            i += 3
        }
        for n in 0..<normals.count { normals[n] = -normals[n] }
    }

    /// Angle-independent area-weighted normals, welded by position so a file that splits vertices per
    /// triangle still shades and projects smoothly.
    public static func computeSmoothNormals(positions: [Vec3], indices: [UInt32]) -> [Vec3] {
        guard !positions.isEmpty else { return [] }
        let box = AABB(points: positions)
        let cell = max(box.diagonal * 1e-5, 1e-7)
        var welded = [SIMD3<Int32>: Int]()
        welded.reserveCapacity(positions.count)
        var group = [Int](repeating: 0, count: positions.count)
        for (i, p) in positions.enumerated() {
            let q = p / cell
            let key = SIMD3<Int32>(Int32(q.x.rounded()), Int32(q.y.rounded()), Int32(q.z.rounded()))
            if let g = welded[key] {
                group[i] = g
            } else {
                welded[key] = i
                group[i] = i
            }
        }
        var sums = [Vec3](repeating: Vec3(repeating: 0), count: positions.count)
        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            let n = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            sums[group[a]] += n
            sums[group[b]] += n
            sums[group[c]] += n
            i += 3
        }
        return (0..<positions.count).map { GeometryMath.safeNormalize(sums[group[$0]]) }
    }
}
