import Foundation
import XCTest
import simd
@testable import LittleSurfaceCore

enum Fixtures {
    /// A UV sphere of triangles, closed and outward-facing.
    static func sphere(radius: Float = 1, center: Vec3 = .zero, rings: Int = 48, segments: Int = 64) -> SourceObject {
        var positions: [Vec3] = []
        var normals: [Vec3] = []
        var indices: [UInt32] = []
        for r in 0...rings {
            let phi = Float.pi * Float(r) / Float(rings)
            for s in 0..<segments {
                let theta = 2 * Float.pi * Float(s) / Float(segments)
                let n = Vec3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
                normals.append(n)
                positions.append(center + n * radius)
            }
        }
        func id(_ r: Int, _ s: Int) -> UInt32 { UInt32(r * segments + (s % segments)) }
        for r in 0..<rings {
            for s in 0..<segments {
                let a = id(r, s), b = id(r, s + 1), c = id(r + 1, s + 1), d = id(r + 1, s)
                if r > 0 { indices += [a, b, d] }
                if r < rings - 1 { indices += [b, c, d] }
            }
        }
        return SourceObject(name: "Sphere", positions: positions, normals: normals, indices: indices)
    }

    /// A flat rectangle in the XY plane facing +Z, split into triangles.
    static func plane(size: Float = 4, divisions: Int = 40, z: Float = 0) -> SourceObject {
        var positions: [Vec3] = []
        var indices: [UInt32] = []
        for y in 0...divisions {
            for x in 0...divisions {
                positions.append(Vec3(size * (Float(x) / Float(divisions) - 0.5), size * (Float(y) / Float(divisions) - 0.5), z))
            }
        }
        let stride = UInt32(divisions + 1)
        for y in 0..<UInt32(divisions) {
            for x in 0..<UInt32(divisions) {
                let a = y * stride + x, b = a + 1, c = a + stride + 1, d = a + stride
                indices += [a, b, c, a, c, d]
            }
        }
        return SourceObject(name: "Plane", positions: positions, indices: indices)
    }

    static func projector(_ object: SourceObject, offset: Float = 0) -> SurfaceProjector {
        SurfaceProjector(bvhs: [TriangleBVH(object: object)!], surfaceOffset: offset)
    }

    /// A camera looking straight at the origin down -Z, so the screen maps simply onto the XY plane.
    static func frontCamera(distance: Float = 5, sceneRadius: Float = 2, projection: ProjectionMode = .perspective) -> Camera {
        var camera = Camera()
        camera.viewSize = Vec2(1000, 1000)
        camera.distance = distance
        camera.sceneRadius = sceneRadius
        camera.projection = projection
        return camera
    }

    /// A quad grid as an editable mesh, wound to face +Z.
    static func grid(columns: Int, rows: Int, spacing: Float = 1) -> (mesh: Mesh, vertices: [[VertexID]]) {
        var mesh = Mesh()
        var ids: [[VertexID]] = []
        for r in 0...rows {
            var row: [VertexID] = []
            for c in 0...columns {
                row.append(mesh.addVertex(Vec3(Float(c) * spacing, Float(r) * spacing, 0)))
            }
            ids.append(row)
        }
        for r in 0..<rows {
            for c in 0..<columns {
                try! mesh.addFace([ids[r][c], ids[r][c + 1], ids[r + 1][c + 1], ids[r + 1][c]])
            }
        }
        return (mesh, ids)
    }

    static func engine(with source: SourceObject, camera: Camera? = nil) -> RetopoEngine {
        let engine = RetopoEngine(name: "Test")
        engine.addSources([source], bvhs: RetopoEngine.buildBVHs(for: [source]))
        if let camera { engine.camera = camera }
        return engine
    }

    /// Drives a whole Pencil stroke through the engine as UIKit would.
    static func draw(_ engine: RetopoEngine, from a: Vec2, to b: Vec2, steps: Int = 40, bend: Vec2 = .zero) {
        engine.pencilBegan(at: a)
        for i in 1...steps {
            let t = Float(i) / Float(steps)
            let curve = bend * (4 * t * (1 - t))
            engine.pencilMoved(to: simd_mix(a, b, Vec2(repeating: t)) + curve)
        }
        engine.pencilEnded(at: b)
    }

    static func drawPath(_ engine: RetopoEngine, _ points: [Vec2]) {
        engine.pencilBegan(at: points[0])
        for p in points.dropFirst() { engine.pencilMoved(to: p) }
        engine.pencilEnded(at: points[points.count - 1])
    }

    static func circle(center: Vec2, radius: Float, steps: Int = 64, closes: Bool = true) -> [Vec2] {
        (0...(closes ? steps : steps - 8)).map { i in
            let a = 2 * Float.pi * Float(i) / Float(steps)
            return center + Vec2(cos(a), sin(a)) * radius
        }
    }
}

func assertValid(_ mesh: Mesh, file: StaticString = #filePath, line: UInt = #line) {
    if let problem = mesh.firstInvariantViolation() {
        XCTFail("Mesh invariant broken: \(problem)", file: file, line: line)
    }
}

/// Every interior edge is traversed in opposite directions by its two faces.
func assertConsistentWinding(_ mesh: Mesh, file: StaticString = #filePath, line: UInt = #line) {
    for e in mesh.aliveEdges where mesh.faceCountOf(edge: e) == 2 {
        let faces = mesh.facesOf(edge: e)
        let (a, b) = mesh.ends(e)
        XCTAssertNotEqual(mesh.faceTraverses(faces[0], from: a, to: b), mesh.faceTraverses(faces[1], from: a, to: b), "Edge \(e) has inconsistent winding", file: file, line: line)
    }
}
