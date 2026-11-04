import Foundation
import simd

public enum PickedElement: Equatable {
    case vertex(VertexID)
    case edge(EdgeID, t: Float)
    case face(FaceID)
}

/// Screen-space picking against the retopology mesh, with the source surface as occluder.
public struct MeshPicker {
    public var camera: Camera
    public var mesh: Mesh
    public var projector: SurfaceProjector?
    /// X-ray views select through the surface.
    public var ignoresOcclusion = false

    public init(camera: Camera, mesh: Mesh, projector: SurfaceProjector?) {
        self.camera = camera
        self.mesh = mesh
        self.projector = projector
    }

    private func isVisible(_ p: Vec3, normal: Vec3?) -> Bool {
        if ignoresOcclusion { return true }
        if let normal, simd_length_squared(normal) > 0 {
            let toEye = camera.occlusionEye(for: p) - p
            // Slightly past edge-on is still pickable, since silhouettes are where artists often work.
            if simd_dot(normal, simd_normalize(toEye)) < -0.25 { return false }
        }
        guard let projector, !projector.isEmpty else { return true }
        let tolerance = max(camera.worldPerPoint(at: p) * 3, max(projector.surfaceOffset * 2, projector.bounds.diagonal * 0.0015))
        return !projector.isOccluded(p, from: camera.occlusionEye(for: p), tolerance: tolerance)
    }

    public func pickVertex(at screen: Vec2, radius: Float) -> VertexID? {
        var best = invalidID
        var bestScore = radius
        for v in mesh.aliveVertices {
            let p = mesh.position(v)
            guard let projected = camera.project(p) else { continue }
            let d = simd_length(projected.screen - screen)
            if d < bestScore && isVisible(p, normal: mesh.vertexNormal(v)) {
                bestScore = d
                best = v
            }
        }
        return best >= 0 ? best : nil
    }

    public func pickEdge(at screen: Vec2, radius: Float) -> (EdgeID, t: Float)? {
        var best = invalidID
        var bestScore = radius
        var bestT: Float = 0.5
        for e in mesh.aliveEdges {
            let (a, b) = mesh.ends(e)
            let pa = mesh.position(a), pb = mesh.position(b)
            guard let sa = camera.project(pa), let sb = camera.project(pb) else { continue }
            let ab = sb.screen - sa.screen
            let len2 = simd_length_squared(ab)
            let t = len2 > 1e-6 ? simd_clamp(simd_dot(screen - sa.screen, ab) / len2, 0, 1) : 0
            let d = simd_length(sa.screen + ab * t - screen)
            guard d < bestScore else { continue }
            let mid = simd_mix(pa, pb, Vec3(repeating: t))
            let faces = mesh.facesOf(edge: e)
            var normal: Vec3? = nil
            if !faces.isEmpty { normal = faces.reduce(Vec3(repeating: 0)) { $0 + mesh.faceNormal($1) } }
            if isVisible(mid, normal: normal) {
                bestScore = d
                best = e
                bestT = t
            }
        }
        return best >= 0 ? (best, bestT) : nil
    }

    public func pickFace(at screen: Vec2) -> FaceID? {
        let ray = camera.ray(through: screen)
        var best = invalidID
        var bestT = Float.infinity
        for f in mesh.aliveFaces {
            let points = mesh.facePositions(f)
            for i in 1..<(points.count - 1) {
                if let hit = GeometryMath.intersectTriangle(ray, points[0], points[i], points[i + 1], tMax: bestT) {
                    let p = ray.at(hit.t)
                    if isVisible(p, normal: mesh.faceNormal(f)) {
                        bestT = hit.t
                        best = f
                    }
                }
            }
        }
        return best >= 0 ? best : nil
    }

    public func pick(at screen: Vec2, mode: SelectionMode, radius: Float) -> PickedElement? {
        switch mode {
        case .vertex:
            return pickVertex(at: screen, radius: radius).map { .vertex($0) }
        case .edge:
            return pickEdge(at: screen, radius: radius).map { .edge($0.0, t: $0.t) }
        case .face:
            return pickFace(at: screen).map { .face($0) }
        }
    }

    /// Elements whose screen positions fall inside a lasso or box outline.
    public func select(inside ring: [Vec2], mode: SelectionMode) -> (vertices: Set<VertexID>, edges: Set<EdgeID>, faces: Set<FaceID>) {
        var outV = Set<VertexID>(), outE = Set<EdgeID>(), outF = Set<FaceID>()
        guard ring.count >= 3 else { return (outV, outE, outF) }
        var lo = Vec2(repeating: .infinity), hi = Vec2(repeating: -.infinity)
        for p in ring {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        var insideCache = [VertexID: Bool]()
        func inside(_ v: VertexID) -> Bool {
            if let cached = insideCache[v] { return cached }
            let p = mesh.position(v)
            var result = false
            if let s = camera.project(p), s.screen.x >= lo.x, s.screen.y >= lo.y, s.screen.x <= hi.x, s.screen.y <= hi.y,
               GeometryMath.pointInPolygon(s.screen, ring), isVisible(p, normal: mesh.vertexNormal(v)) {
                result = true
            }
            insideCache[v] = result
            return result
        }
        switch mode {
        case .vertex:
            for v in mesh.aliveVertices where inside(v) { outV.insert(v) }
        case .edge:
            for e in mesh.aliveEdges {
                let (a, b) = mesh.ends(e)
                if inside(a) && inside(b) { outE.insert(e) }
            }
        case .face:
            for f in mesh.aliveFaces where mesh.loop(f).allSatisfy(inside) { outF.insert(f) }
        }
        return (outV, outE, outF)
    }
}
