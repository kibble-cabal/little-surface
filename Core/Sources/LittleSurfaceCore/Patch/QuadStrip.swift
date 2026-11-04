import Foundation
import simd

public enum StripDirection: String, Codable, CaseIterable {
    /// The drawn path is the strip's center line.
    case centered
    /// The drawn path is the right rail, and the strip grows to its left.
    case left
    /// The drawn path is the left rail, and the strip grows to its right.
    case right
}

public struct QuadStripParameters: Equatable, Codable {
    public var width: Float = 0.1
    /// Quads along the path. 0 derives the count from `vertexSpacing`.
    public var segments: Int = 0
    public var vertexSpacing: Float = 0.05
    /// Quads across the strip.
    public var crossSegments: Int = 1
    public var direction = StripDirection.centered
    public init() {}
}

public enum QuadStripBuilder {
    public static func plan(
        path: ProcessedPath,
        parameters: QuadStripParameters,
        mesh: Mesh,
        projector: SurfaceProjector?,
        snapRadius: Float
    ) throws -> TopologyPlan {
        guard path.points.count >= 2 else {
            throw MeshError.invalid("That stroke is too short to make a quad strip.")
        }
        guard parameters.width > 0 else { throw MeshError.invalid("Strip width has to be above zero.") }

        let segments: Int
        if parameters.segments > 0 {
            segments = parameters.segments
        } else {
            segments = max(1, Int((path.length / max(parameters.vertexSpacing, 1e-5)).rounded()))
        }
        let closed = path.isClosed
        let source = closed ? path.points + [path.points[0]] : path.points
        var center = StrokeProcessor.resample(source, count: segments + 1)
        if closed { center.removeLast() }
        let columns = center.count

        // Project the center line again, because resampling can cut across curvature.
        if let projector {
            for i in 0..<columns {
                if let hit = projector.closest(to: center[i].position, normalHint: center[i].normal, maxDistance: parameters.width * 2) {
                    center[i].position = hit.position
                    center[i].normal = hit.normal
                }
            }
        }

        let cross = max(1, parameters.crossSegments)
        var plan = TopologyPlan()
        var unprojected = 0
        let offset = projector?.surfaceOffset ?? 0

        for i in 0..<columns {
            let prev = closed ? center[(i + columns - 1) % columns] : center[max(i - 1, 0)]
            let next = closed ? center[(i + 1) % columns] : center[min(i + 1, columns - 1)]
            let tangent = GeometryMath.safeNormalize(next.position - prev.position)
            let normal = center[i].normal
            // cross(tangent, normal) is the artist's right when looking down on the surface.
            let side = GeometryMath.safeNormalize(simd_cross(tangent, normal), fallback: GeometryMath.perpendicular(to: normal))
            for k in 0...cross {
                let fraction = Float(k) / Float(cross)
                let amount: Float
                switch parameters.direction {
                case .centered: amount = parameters.width * (fraction - 0.5)
                case .right: amount = parameters.width * fraction
                case .left: amount = -parameters.width * fraction
                }
                let raw = center[i].position + side * amount
                var position = raw + normal * offset
                var surfaceNormal = normal
                if let projector {
                    if let hit = projector.closest(to: raw, normalHint: normal, maxDistance: parameters.width * 2) {
                        position = hit.offsetPosition(offset)
                        surfaceNormal = hit.normal
                    } else {
                        unprojected += 1
                    }
                }
                plan.nodes.append(.new(position: position, normal: surfaceNormal))
            }
        }
        let stride = cross + 1

        // End cross-sections join nearby topology, so strips can continue each other.
        if !closed && !mesh.isEmpty && snapRadius > 0 {
            for column in [0, columns - 1] {
                var used = Set<VertexID>()
                for k in 0...cross {
                    let index = column * stride + k
                    let p = plan.position(of: index, in: mesh)
                    var best = invalidID
                    var bestDistance = snapRadius
                    for v in mesh.aliveVertices where !used.contains(v) {
                        let d = simd_length(mesh.position(v) - p)
                        if d < bestDistance {
                            bestDistance = d
                            best = v
                        }
                    }
                    if best >= 0 {
                        used.insert(best)
                        plan.nodes[index] = .existing(best)
                    }
                }
            }
        }

        // Faces follow the surface normal: counterclockwise when seen from outside.
        var votes: Float = 0
        func corner(_ i: Int, _ k: Int) -> Int32 { Int32((i % columns) * stride + k) }
        let faceColumns = closed ? columns : columns - 1
        var loops: [[Int32]] = []
        for i in 0..<faceColumns {
            for k in 0..<cross {
                let loop = [corner(i, k), corner(i + 1, k), corner(i + 1, k + 1), corner(i, k + 1)]
                loops.append(loop)
                let points = loop.map { plan.position(of: Int($0), in: mesh) }
                var normal = center[i].normal
                if case .new(_, let n) = plan.nodes[Int(loop[0])] { normal = n }
                votes += simd_dot(GeometryMath.newellNormal(points), normal)
            }
        }
        if votes < 0 { loops = loops.map { Array($0.reversed()) } }
        plan.faces = loops

        // Refuse anything that collapsed, rather than committing a broken strip.
        for loop in plan.faces {
            let ids = loop.map { plan.nodes[Int($0)] }
            let existing = ids.compactMap { node -> VertexID? in
                if case .existing(let v) = node { return v }
                return nil
            }
            if Set(existing).count != existing.count {
                throw MeshError.invalid("Both sides of the strip snapped to the same vertex. Make the strip wider or start farther from existing topology.")
            }
            if GeometryMath.newellNormal(loop.map { plan.position(of: Int($0), in: mesh) }).allSatisfy({ abs($0) < 1e-12 }) {
                throw MeshError.invalid("Part of this strip collapses to nothing. Try a narrower width or a smoother path.")
            }
        }
        if unprojected > 0 {
            plan.notes.append("\(unprojected) strip vertices found no surface nearby and stay where the strip put them.")
        }
        return plan
    }
}

private extension SIMD3 where Scalar == Float {
    func allSatisfy(_ test: (Float) -> Bool) -> Bool { test(x) && test(y) && test(z) }
}
