import XCTest
import simd
@testable import LittleSurfaceCore

final class SketchTests: XCTestCase {
    private func sketching() -> RetopoEngine {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.sketch)
        return engine
    }

    func testALineLandsOnTheSurfaceInTheChosenColorAndNeverTouchesTheMesh() throws {
        let engine = sketching()
        engine.sketchColorIndex = 2
        Fixtures.draw(engine, from: Vec2(420, 380), to: Vec2(600, 420))
        XCTAssertEqual(engine.sketches.count, 1)
        let stroke = engine.sketches[0]
        XCTAssertEqual(stroke.colorIndex, 2)
        XCTAssertGreaterThan(stroke.points.count, 3)
        for p in stroke.points { XCTAssertEqual(simd_length(p), 1, accuracy: 0.02, "sits on the sphere") }
        XCTAssertEqual(engine.mesh.vertexCount, 0, "the sketch isn't topology")
        XCTAssertEqual(engine.statistics.triangleEquivalent, 0)
    }

    func testAStrayTapDrawsNothing() {
        let engine = sketching()
        engine.pencilBegan(at: Vec2(500, 400))
        engine.pencilEnded(at: Vec2(500, 400))
        XCTAssertTrue(engine.sketches.isEmpty)
        XCTAssertFalse(engine.canUndo)
    }

    func testSketchOffTheModelIsIgnored() {
        let engine = sketching()
        Fixtures.draw(engine, from: Vec2(5, 5), to: Vec2(80, 5))
        XCTAssertTrue(engine.sketches.isEmpty)
    }

    func testUndoAndRedoCoverSketchingAndTheMeshInOrder() throws {
        let engine = sketching()
        Fixtures.draw(engine, from: Vec2(420, 300), to: Vec2(600, 300))
        let oneLine = engine.sketches
        engine.setTool(.drawEdges)
        Fixtures.draw(engine, from: Vec2(420, 380), to: Vec2(600, 380))
        let vertices = engine.mesh.vertexCount
        XCTAssertGreaterThan(vertices, 0)
        engine.setTool(.sketch)
        Fixtures.draw(engine, from: Vec2(420, 460), to: Vec2(600, 460))
        XCTAssertEqual(engine.sketches.count, 2)

        engine.undo()
        XCTAssertEqual(engine.sketches, oneLine)
        XCTAssertEqual(engine.mesh.vertexCount, vertices, "the mesh stays")
        engine.undo()
        XCTAssertEqual(engine.sketches, oneLine, "the sketch stays")
        XCTAssertEqual(engine.mesh.vertexCount, 0)
        engine.undo()
        XCTAssertTrue(engine.sketches.isEmpty)
        engine.redo(); engine.redo(); engine.redo()
        XCTAssertEqual(engine.sketches.count, 2)
        XCTAssertEqual(engine.mesh.vertexCount, vertices)
    }

    func testEraseTakesOutWholeLinesItTouchesAsOneUndo() throws {
        let engine = sketching()
        Fixtures.draw(engine, from: Vec2(420, 300), to: Vec2(600, 300))
        Fixtures.draw(engine, from: Vec2(420, 460), to: Vec2(600, 460))
        let both = engine.sketches
        engine.sketchErases = true
        Fixtures.draw(engine, from: Vec2(500, 280), to: Vec2(500, 320), steps: 6)
        XCTAssertEqual(engine.sketches.count, 1)
        XCTAssertEqual(engine.sketches[0], both[1], "the other line wasn't touched")
        engine.undo()
        XCTAssertEqual(engine.sketches, both)
    }

    func testEraseMissingEverythingAddsNoUndoStep() throws {
        let engine = sketching()
        Fixtures.draw(engine, from: Vec2(420, 300), to: Vec2(600, 300))
        let depth = engine.history.undoStack.count
        engine.sketchErases = true
        Fixtures.draw(engine, from: Vec2(500, 480), to: Vec2(500, 520), steps: 6)
        XCTAssertEqual(engine.sketches.count, 1)
        XCTAssertEqual(engine.history.undoStack.count, depth)
    }

    func testEraseLeavesLinesOnTheFarSideOfTheModel() throws {
        let engine = sketching()
        Fixtures.draw(engine, from: Vec2(420, 380), to: Vec2(600, 380))
        // Turn right round, so the line is behind the model at the same place on screen.
        engine.camera.setPreset(.back)
        engine.sketchErases = true
        Fixtures.draw(engine, from: Vec2(500, 360), to: Vec2(500, 400), steps: 6)
        XCTAssertEqual(engine.sketches.count, 1)
    }

    func testCancelledEraseBringsLinesBack() throws {
        let engine = sketching()
        Fixtures.draw(engine, from: Vec2(420, 300), to: Vec2(600, 300))
        let depth = engine.history.undoStack.count
        engine.sketchErases = true
        engine.pencilBegan(at: Vec2(500, 300))
        XCTAssertTrue(engine.sketches.isEmpty)
        engine.pencilCancelled()
        XCTAssertEqual(engine.sketches.count, 1)
        XCTAssertEqual(engine.history.undoStack.count, depth)
    }

    func testClearIsOneUndo() throws {
        let engine = sketching()
        Fixtures.draw(engine, from: Vec2(420, 300), to: Vec2(600, 300))
        Fixtures.draw(engine, from: Vec2(420, 460), to: Vec2(600, 460))
        engine.clearSketch()
        XCTAssertTrue(engine.sketches.isEmpty)
        engine.undo()
        XCTAssertEqual(engine.sketches.count, 2)
    }

    func testSymmetryMirrorsTheLine() throws {
        let engine = sketching()
        engine.setSymmetryEnabled(true)
        Fixtures.draw(engine, from: Vec2(560, 300), to: Vec2(620, 420))
        XCTAssertEqual(engine.sketches.count, 2)
        for (a, b) in zip(engine.sketches[0].points, engine.sketches[1].points) {
            XCTAssertEqual(a.x, -b.x, accuracy: 1e-5)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-5)
        }
    }

    func testNeverReachesAnExport() throws {
        let engine = sketching()
        engine.setTool(.drawEdges)
        Fixtures.draw(engine, from: Vec2(420, 380), to: Vec2(600, 380))
        let plain = engine.exportData(format: .obj, options: ExportOptions())
        engine.setTool(.sketch)
        Fixtures.draw(engine, from: Vec2(420, 300), to: Vec2(600, 300))
        XCTAssertEqual(engine.exportData(format: .obj, options: ExportOptions()), plain)
    }

    func testSketchSavesWithTheProjectAndOldProjectsStillOpen() throws {
        let engine = sketching()
        engine.sketchColorIndex = 3
        Fixtures.draw(engine, from: Vec2(420, 300), to: Vec2(600, 300))
        engine.sketchColorIndex = 1
        Fixtures.draw(engine, from: Vec2(420, 460), to: Vec2(600, 460))
        engine.showsSketch = false
        let data = try ProjectCodec.encode(engine.makeSnapshot())
        let reopened = RetopoEngine(snapshot: try ProjectCodec.decode(data))
        XCTAssertEqual(reopened.sketches, engine.sketches)
        XCTAssertEqual(reopened.sketchColorIndex, 1)
        XCTAssertFalse(reopened.showsSketch)

        let old = try ProjectCodec.decode(projectData(data, withoutSettings: ["sketchColorIndex", "showsSketch"]))
        XCTAssertEqual(old.sketchColorIndex, 0)
        XCTAssertTrue(old.showsSketch)
    }

    func testLinesFollowAnUpdatedSculptAndComeBackOnUndo() throws {
        let engine = sketching()
        Fixtures.draw(engine, from: Vec2(420, 380), to: Vec2(600, 380))
        let before = engine.sketches
        let sphere = Fixtures.sphere(radius: 1.2)
        let object = SourceObject(id: engine.sources[0].id, name: "New", positions: sphere.positions, normals: sphere.normals, indices: sphere.indices)
        engine.updateSource(id: object.id, with: object, bvh: try XCTUnwrap(TriangleBVH(object: object)))
        for p in engine.sketches[0].points { XCTAssertEqual(simd_length(p), 1.2, accuracy: 0.02) }
        engine.undo()
        XCTAssertEqual(engine.sketches, before)
    }

    func testUndoMidLineCancelsJustThatLine() throws {
        let engine = sketching()
        Fixtures.draw(engine, from: Vec2(420, 300), to: Vec2(600, 300))
        engine.pencilBegan(at: Vec2(420, 460))
        engine.pencilMoved(to: Vec2(500, 460))
        engine.undo()
        XCTAssertEqual(engine.sketches.count, 1, "the finished line stays")
        engine.pencilEnded(at: Vec2(600, 460))
        XCTAssertEqual(engine.sketches.count, 1, "and lifting doesn't finish the cancelled one")
    }
}
