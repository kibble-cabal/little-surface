import XCTest
import simd
@testable import LittleSurfaceCore

/// Picking is a step you can go back through.
final class PickingTests: XCTestCase {
    private func pencil() -> RetopoEngine {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.pencil)
        return engine
    }

    private func straight(_ a: Vec2, _ b: Vec2, steps: Int = 24) -> [Vec2] {
        (0...steps).map { simd_mix(a, b, Vec2(repeating: Float($0) / Float(steps))) }
    }

    private func tap(_ engine: RetopoEngine, at p: Vec2) {
        engine.pencilBegan(at: p)
        engine.pencilEnded(at: p)
    }

    private func drag(_ engine: RetopoEngine, from a: Vec2, to b: Vec2) {
        engine.pencilBegan(at: a)
        for p in straight(a, b).dropFirst() { engine.pencilMoved(to: p) }
        engine.pencilEnded(at: b)
    }

    /// One shape with a quad's four corners, from (400, 420) to (600, 580).
    private func drawQuad(_ engine: RetopoEngine) {
        for y: Float in [420, 580] { Fixtures.drawPath(engine, straight(Vec2(390, y), Vec2(610, y))) }
        for x: Float in [400, 600] { Fixtures.drawPath(engine, straight(Vec2(x, 410), Vec2(x, 590))) }
    }

    private func screen(_ engine: RetopoEngine, of v: VertexID) throws -> Vec2 {
        try XCTUnwrap(engine.camera.project(engine.mesh.position(v))).screen
    }

    // MARK: Undoing picks

    func testPickingCanBeUndoneAndRedone() {
        let engine = pencil()
        drawQuad(engine)
        let drawn = engine.mesh.positionVersion
        tap(engine, at: Vec2(500, 500))
        XCTAssertEqual(engine.selection.faces.count, 1)

        engine.undo()
        XCTAssertTrue(engine.selection.isEmpty, "undo takes back the pick")
        XCTAssertEqual(engine.mesh.faceCount, 1, "and nothing that was drawn")
        XCTAssertEqual(engine.mesh.positionVersion, drawn)

        engine.redo()
        XCTAssertEqual(engine.selection.faces.count, 1)
    }

    func testUndoingAnEditGoesBackToWhatWasPicked() {
        let engine = pencil()
        drawQuad(engine)
        tap(engine, at: Vec2(500, 500))
        engine.deletePick()
        XCTAssertEqual(engine.mesh.faceCount, 0)
        engine.undo()
        XCTAssertEqual(engine.mesh.faceCount, 1)
        XCTAssertEqual(engine.selection.faces.count, 1, "back to the moment before the delete, still picked")
        engine.undo()
        XCTAssertTrue(engine.selection.isEmpty)
    }

    func testTappingNothingWithNothingPickedIsNoStep() {
        let engine = pencil()
        drawQuad(engine)
        let steps = engine.history.undoStack.count
        tap(engine, at: Vec2(30, 30))
        XCTAssertEqual(engine.history.undoStack.count, steps)
    }

    func testPickingDoesNotReachTheTimelapse() {
        let engine = pencil()
        drawQuad(engine)
        let frames = engine.makeSnapshot().timelapse.count
        tap(engine, at: Vec2(500, 500))
        engine.undo()
        engine.redo()
        XCTAssertEqual(engine.makeSnapshot().timelapse.count, frames)
    }

    func testAPickedMarkComesBackWithUndo() {
        let engine = pencil()
        engine.setTool(.sketch)
        Fixtures.draw(engine, from: Vec2(450, 400), to: Vec2(550, 400))
        engine.setTool(.pencil)
        tap(engine, at: Vec2(500, 400))
        XCTAssertEqual(engine.pickedMark, 0)
        engine.undo()
        XCTAssertNil(engine.pickedMark)
        engine.redo()
        XCTAssertEqual(engine.pickedMark, 0)
    }
}
