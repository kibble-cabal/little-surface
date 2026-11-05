import XCTest
import simd
@testable import LittleSurfaceCore

private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Random but realistic sessions. Each step must leave a structurally valid mesh, whatever the tool
/// decided, and undoing everything must return to the start.
final class RobustnessTests: XCTestCase {
    private func session(seed: UInt64, symmetric: Bool, steps: Int) throws {
        var rng = SeededRandom(state: seed)
        let engine = Fixtures.engine(with: Fixtures.sphere(rings: 32, segments: 48), camera: Fixtures.frontCamera())
        if symmetric { engine.setSymmetryEnabled(true) }
        func point() -> Vec2 { Vec2(Float.random(in: 280...720, using: &rng), Float.random(in: 280...720, using: &rng)) }
        func tapOnMesh() -> Vec2 {
            let vertices = engine.mesh.aliveVertices
            guard !vertices.isEmpty else { return point() }
            let v = vertices[Int.random(in: 0..<vertices.count, using: &rng)]
            return engine.camera.project(engine.mesh.position(v))?.screen ?? point()
        }
        for step in 0..<steps {
            let op = Int.random(in: 0..<20, using: &rng)
            switch op {
            case 0, 1, 2:
                engine.setTool(.drawEdges)
                engine.tools.stroke.edgeLength = Float.random(in: 0.06...0.2, using: &rng)
                Fixtures.draw(engine, from: Int.random(in: 0..<3, using: &rng) == 0 ? tapOnMesh() : point(), to: point(), steps: 16)
                if engine.pendingStroke != nil { engine.commitPendingStroke(close: Bool.random(using: &rng)) }
            case 3:
                engine.setTool(.edgeLoop)
                Fixtures.drawPath(engine, Fixtures.circle(center: point(), radius: Float.random(in: 40...120, using: &rng), steps: 32))
                if engine.pendingStroke != nil { engine.commitPendingStroke(close: Bool.random(using: &rng)) }
            case 4:
                engine.setTool(.quadStrip)
                engine.tools.strip.width = Float.random(in: 0.05...0.4, using: &rng)
                engine.tools.strip.segments = Int.random(in: 0...12, using: &rng)
                engine.tools.strip.vertexSpacing = 0.1
                Fixtures.draw(engine, from: point(), to: point(), steps: 16)
                engine.commitPendingStrip()
            case 5, 6:
                engine.setTool(.quadPatch)
                engine.clearPatchPicks()
                for _ in 0..<Int.random(in: 2...4, using: &rng) { engine.patchTap(at: tapOnMesh()) }
                engine.tools.patch.rows = Int.random(in: 0...5, using: &rng)
                engine.updatePatchPreview()
                let before = engine.mesh.topologyVersion
                let error = engine.patchError
                engine.commitPatch()
                if error != nil { XCTAssertEqual(engine.mesh.topologyVersion, before, "a refused patch leaves the mesh alone") }
            case 7:
                engine.setTool(.face)
                for _ in 0..<Int.random(in: 3...4, using: &rng) { engine.faceToolTap(at: tapOnMesh()) }
                engine.commitFaceBuilder()
                engine.cancelFaceBuilder()
            case 8, 9:
                engine.setTool(.select)
                engine.setSelectionMode(SelectionMode.allCases.randomElement(using: &rng)!)
                engine.clearSelection()
                for _ in 0..<Int.random(in: 1...6, using: &rng) {
                    let p = tapOnMesh()
                    engine.selectionOperation = .add
                    engine.pencilBegan(at: p)
                    engine.pencilEnded(at: p)
                }
                engine.selectionOperation = .replace
            case 10: engine.deleteSelection()
            case 11: engine.dissolveSelection()
            case 12: engine.splitSelectedEdges(cuts: Int.random(in: 1...3, using: &rng))
            case 13: engine.extrudeSelectedEdges()
            case 14:
                switch Int.random(in: 0..<6, using: &rng) {
                case 0: engine.fillHoles()
                case 1: engine.weldSelected()
                case 2: engine.flipSelectedEdges()
                case 3: engine.connectSelectedVertices()
                case 4: engine.makeFaceFromSelection()
                default: engine.weldByDistance(0.01)
                }
            case 15:
                switch Int.random(in: 0..<5, using: &rng) {
                case 0: engine.relaxSelection()
                case 1: engine.reverseNormals()
                case 2: engine.recalculateNormals()
                case 3: engine.reproject()
                default: if engine.mesh.faceCount < 800 { engine.subdivideSelection() }
                }
            case 16:
                engine.setTool(.select)
                engine.setSelectionMode(.vertex)
                let from = tapOnMesh()
                Fixtures.draw(engine, from: from, to: from + Vec2(Float.random(in: -40...40, using: &rng), Float.random(in: -40...40, using: &rng)), steps: 6)
            case 17:
                engine.setTool([Tool.moveBrush, .relaxBrush, .erase].randomElement(using: &rng)!)
                engine.tools.brush.radiusPoints = Float.random(in: 10...50, using: &rng)
                Fixtures.draw(engine, from: tapOnMesh(), to: point(), steps: 8)
            case 18: engine.undo()
            default: engine.redo()
            }
            if let problem = engine.mesh.firstInvariantViolation() {
                XCTFail("seed \(seed), step \(step), op \(op): \(problem)")
                return
            }
            for f in engine.selection.faces { XCTAssertTrue(engine.mesh.isFaceAlive(f), "selection points at a dead face after op \(op)") }
            for v in engine.selection.vertices { XCTAssertTrue(engine.mesh.isVertexAlive(v), "selection points at a dead vertex after op \(op)") }
            for e in engine.selection.edges { XCTAssertTrue(engine.mesh.isEdgeAlive(e), "selection points at a dead edge after op \(op)") }
        }
        print("FUZZ seed \(seed):", MeshStatistics(engine.mesh).vertices, "v", MeshStatistics(engine.mesh).faces, "f", engine.history.undoStack.count, "undo")
        // The session must survive saving, reloading and every exporter.
        let back = try ProjectCodec.decode(try ProjectCodec.encode(engine.makeSnapshot()))
        XCTAssertEqual(back.mesh.faceLoops, engine.mesh.faceLoops)
        let document = try OBJImporter.parse(data: engine.exportData(format: .obj, options: ExportOptions()))
        XCTAssertEqual(document.positions.count, engine.mesh.vertexCount)
        _ = try CatmullClark.preview(engine.mesh, levels: 1)
        _ = MeshValidator.analyze(engine.mesh)
        while engine.canUndo { engine.undo() }
        assertValid(engine.mesh)
    }

    func testRandomSessions() throws {
        for seed in 1...12 { try session(seed: UInt64(seed), symmetric: false, steps: 120) }
    }

    func testRandomSymmetricSessions() throws {
        for seed in 101...112 { try session(seed: UInt64(seed), symmetric: true, steps: 120) }
    }

    func testAllEditsOnAnEmptyMeshAreHarmless() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(rings: 8, segments: 8), camera: Fixtures.frontCamera())
        engine.deleteSelection(); engine.dissolveSelection(); engine.splitSelectedEdges(cuts: 1); engine.connectSelectedVertices()
        engine.extrudeSelectedEdges(); engine.fillHoles(); engine.weldSelected(); engine.weldByDistance(0.01); engine.flipSelectedEdges()
        engine.subdivideSelection(); engine.applySubdivision(); engine.relaxSelection(); engine.reverseNormals(); engine.recalculateNormals()
        engine.makeFaceFromSelection(); engine.reproject(); engine.mergeCenterline(); engine.applySymmetry(); engine.undo(); engine.redo()
        engine.selectEdgeLoop(); engine.selectEdgeRing(); engine.selectConnected(); engine.selectBoundary(); engine.selectAll(); engine.frameSelection()
        XCTAssertTrue(engine.mesh.isEmpty)
        _ = engine.exportData(format: .glb, options: ExportOptions())
        _ = engine.exportData(format: .obj, options: ExportOptions())
    }
}

final class BrushTests: XCTestCase {
    private func gridEngine() -> RetopoEngine {
        let engine = Fixtures.engine(with: Fixtures.plane(), camera: Fixtures.frontCamera())
        engine.perform("seed") { mesh, _ in
            mesh = Fixtures.grid(columns: 10, rows: 10, spacing: 0.1).mesh
            for v in mesh.aliveVertices { mesh.setPosition(v, mesh.position(v) - Vec3(0.5, 0.5, 0)) }
        }
        return engine
    }

    func testMoveBrushFollowsDragWithFalloff() throws {
        let engine = gridEngine()
        engine.setTool(.moveBrush)
        engine.tools.brush.radiusPoints = 40
        engine.tools.brush.strength = 1
        let start = engine.mesh.positions
        Fixtures.draw(engine, from: Vec2(500, 500), to: Vec2(540, 500), steps: 10)
        var near: Float = 0, far: Float = 0
        for v in engine.mesh.aliveVertices {
            let moved = simd_length(engine.mesh.position(v) - start[Int(v)])
            if simd_length(start[Int(v)]) < 0.02 { near = moved }
            if simd_length(start[Int(v)]) > 0.45 { far = max(far, moved) }
        }
        XCTAssertGreaterThan(near, 0.05, "the vertex under the brush moves")
        XCTAssertEqual(far, 0, accuracy: 1e-6, "vertices outside the radius don't")
        for v in engine.mesh.aliveVertices where engine.mesh.position(v) != start[Int(v)] {
            XCTAssertEqual(engine.mesh.position(v).z, engine.tools.surfaceOffset, accuracy: 1e-3, "stays on the surface")
        }
        assertValid(engine.mesh)
    }

    func testRelaxBrushEvensOutADisplacedVertex() throws {
        let engine = gridEngine()
        let center = try XCTUnwrap(engine.mesh.aliveVertices.first { simd_length(engine.mesh.position($0)) < 0.01 })
        engine.perform("nudge") { mesh, _ in mesh.setPosition(center, Vec3(0.07, 0.07, 0)) }
        engine.setTool(.relaxBrush)
        engine.tools.brush.radiusPoints = 60
        engine.tools.brush.strength = 1
        Fixtures.draw(engine, from: Vec2(495, 505), to: Vec2(505, 495), steps: 20)
        XCTAssertLessThan(simd_length(engine.mesh.position(center)), 0.06)
    }

    func testEraseBrushDeletesWhatItTouchesAsOneUndo() throws {
        let engine = gridEngine()
        let depth = engine.history.undoStack.count
        let faces = engine.mesh.faceCount
        engine.setTool(.erase)
        engine.setSelectionMode(.face)
        Fixtures.draw(engine, from: Vec2(430, 500), to: Vec2(570, 500), steps: 20)
        XCTAssertLessThan(engine.mesh.faceCount, faces)
        XCTAssertEqual(engine.history.undoStack.count, depth + 1)
        assertValid(engine.mesh)
        engine.undo()
        XCTAssertEqual(engine.mesh.faceCount, faces)
    }

    func testPressureScalesSmoothing() throws {
        func moved(pressure: Float) -> Float {
            let engine = gridEngine()
            engine.tools.brush.radiusPoints = 40
            let center = engine.mesh.aliveVertices.first { simd_length(engine.mesh.position($0)) < 0.01 }!
            engine.setTool(.moveBrush)
            Fixtures.draw(engine, from: Vec2(500, 500), to: Vec2(530, 500), steps: 10)
            let before = engine.mesh.position(center)
            engine.setTool(.relaxBrush)
            engine.tools.brush.usesPressure = true
            let there = engine.camera.project(before)!.screen
            engine.pencilBegan(at: there, pressure: pressure)
            engine.pencilEnded(at: there, pressure: pressure)
            return simd_length(engine.mesh.position(center) - before)
        }
        XCTAssertGreaterThan(moved(pressure: 1), moved(pressure: 0.2))
    }

    func testTheMoveBrushKeepsUpWithThePencil() throws {
        for pressure: Float in [1, 0.2] {
            let engine = gridEngine()
            engine.setTool(.moveBrush)
            engine.tools.brush.radiusPoints = 40
            let center = engine.mesh.aliveVertices.first { simd_length(engine.mesh.position($0)) < 0.01 }!
            let before = engine.mesh.position(center)
            engine.pencilBegan(at: Vec2(500, 500), pressure: pressure)
            for i in 1...10 { engine.pencilMoved(to: Vec2(500 + Float(i) * 4, 500), pressure: pressure) }
            engine.pencilEnded(at: Vec2(540, 500), pressure: pressure)
            let drag = 40 * engine.camera.worldPerPoint(at: before)
            XCTAssertEqual(simd_length(engine.mesh.position(center) - before), drag, accuracy: drag * 0.2)
        }
    }
}

/// Real files from outside this project, when their folder is named. See tools/README.
final class RealFileTests: XCTestCase {
    func testKhronosSamples() throws {
        guard let folder = ProcessInfo.processInfo.environment["LS_SAMPLES"] else { throw XCTSkip("LS_SAMPLES is not set") }
        let expectations: [(String, Int)] = [("Avocado.glb", 682), ("Box.gltf", 12), ("Duck.glb", 4212), ("DamagedHelmet.glb", 15452), ("BrainStem.glb", 61666), ("SimpleMorph.gltf", 1)]
        for (file, triangles) in expectations {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let model = try ModelImporter.load(url: url)
            XCTAssertEqual(model.triangleCount, triangles, file)
            let object = try XCTUnwrap(model.objects.first)
            XCTAssertNotNil(TriangleBVH(object: object))
            for p in object.positions.prefix(100) { XCTAssertTrue(p.x.isFinite && p.y.isFinite && p.z.isFinite, file) }
            print("SAMPLE", file, model.objects.count, "objects", model.triangleCount, "triangles")
        }
    }
}
