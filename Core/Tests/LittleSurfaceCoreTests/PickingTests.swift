import XCTest
import simd
@testable import LittleSurfaceCore

/// Picking is a step you can go back through, and what's picked can be picked up and moved.
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

    func testAPickLetGoSomeOtherWayTakesNoExtraUndo() {
        let engine = pencil()
        drawQuad(engine)
        let drawnLines = engine.mesh.edgeCount
        Fixtures.drawPath(engine, straight(Vec2(420, 300), Vec2(580, 300)))
        tap(engine, at: Vec2(500, 500))
        engine.clearPick()
        engine.undo()
        XCTAssertEqual(engine.mesh.edgeCount, drawnLines, "the pick had nothing to take back, so this undoes the line")
        engine.redo()
        XCTAssertGreaterThan(engine.mesh.edgeCount, drawnLines)
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

    // MARK: Picking and moving

    func testTappingAPointPicksIt() throws {
        let engine = pencil()
        Fixtures.drawPath(engine, straight(Vec2(420, 400), Vec2(580, 400)))
        tap(engine, at: Vec2(420, 400))
        XCTAssertEqual(engine.selection.vertices.count, 1)
        XCTAssertTrue(engine.selection.edges.isEmpty)
        tap(engine, at: Vec2(420, 400))
        XCTAssertTrue(engine.selection.isEmpty, "tapping it again lets it go")
    }

    func testAPickedPointCanBeDraggedWithoutHolding() throws {
        let engine = pencil()
        Fixtures.drawPath(engine, straight(Vec2(420, 400), Vec2(580, 400)))
        tap(engine, at: Vec2(420, 400))
        let v = try XCTUnwrap(engine.selection.vertices.first)
        let lines = engine.mesh.edgeCount
        drag(engine, from: Vec2(420, 400), to: Vec2(430, 450))
        XCTAssertLessThan(simd_length(try screen(engine, of: v) - Vec2(430, 450)), 3)
        XCTAssertEqual(engine.mesh.edgeCount, lines, "it moved, and drew nothing")
        XCTAssertEqual(engine.selection.vertices, [v], "and stays picked, to move again")

        engine.undo()
        XCTAssertLessThan(simd_length(try screen(engine, of: v) - Vec2(420, 400)), 3)
        XCTAssertEqual(engine.selection.vertices, [v])
    }

    func testAPickedLineMovesWhole() throws {
        let engine = pencil()
        Fixtures.drawPath(engine, straight(Vec2(420, 400), Vec2(580, 400)))
        tap(engine, at: Vec2(500, 400))
        XCTAssertFalse(engine.selection.edges.isEmpty)
        let points = engine.mesh.aliveVertices
        let before = try points.map { try screen(engine, of: $0) }
        drag(engine, from: Vec2(500, 400), to: Vec2(500, 440))
        for (v, was) in zip(points, before) {
            let now = try screen(engine, of: v)
            XCTAssertEqual(now.y - was.y, 40, accuracy: 6)
            XCTAssertEqual(now.x, was.x, accuracy: 6)
        }
    }

    func testAPickedShapeMovesWithItsCorners() throws {
        let engine = pencil()
        drawQuad(engine)
        tap(engine, at: Vec2(500, 500))
        let face = try XCTUnwrap(engine.selection.faces.first)
        let corners = engine.mesh.loop(face)
        let before = try corners.map { try screen(engine, of: $0) }
        drag(engine, from: Vec2(500, 500), to: Vec2(520, 500))
        for (v, was) in zip(corners, before) {
            XCTAssertEqual(try screen(engine, of: v).x - was.x, 20, accuracy: 8)
        }
    }

    func testALineBetweenTwoShapesCanBePickedAndMoved() throws {
        let engine = pencil()
        drawQuad(engine)
        Fixtures.drawPath(engine, straight(Vec2(500, 410), Vec2(500, 590)))
        XCTAssertEqual(engine.mesh.faceCount, 2)
        tap(engine, at: Vec2(500, 500))
        XCTAssertFalse(engine.selection.edges.isEmpty, "right on a line between two shapes picks the line")
        let line = engine.selection.edges
        drag(engine, from: Vec2(500, 500), to: Vec2(530, 500))
        XCTAssertEqual(engine.selection.edges, line)
        XCTAssertEqual(engine.mesh.faceCount, 2)
    }

    func testPressingAPickAndNotMovingIsATap() {
        let engine = pencil()
        drawQuad(engine)
        tap(engine, at: Vec2(500, 500))
        XCTAssertEqual(engine.selection.faces.count, 1)
        tap(engine, at: Vec2(500, 500))
        XCTAssertTrue(engine.selection.isEmpty)
        engine.undo()
        XCTAssertEqual(engine.selection.faces.count, 1)
    }

    func testAStrokeAwayFromThePickStillDraws() {
        let engine = pencil()
        drawQuad(engine)
        tap(engine, at: Vec2(500, 500))
        let lines = engine.mesh.edgeCount
        Fixtures.drawPath(engine, straight(Vec2(420, 300), Vec2(580, 300)))
        XCTAssertGreaterThan(engine.mesh.edgeCount, lines)
        XCTAssertTrue(engine.selection.isEmpty)
    }

    func testUndoingAMoveKeepsMarks() {
        let engine = pencil()
        Fixtures.drawPath(engine, straight(Vec2(420, 400), Vec2(580, 400)))
        engine.setTool(.sketch)
        Fixtures.draw(engine, from: Vec2(450, 300), to: Vec2(550, 300))
        engine.setTool(.pencil)
        tap(engine, at: Vec2(420, 400))
        drag(engine, from: Vec2(420, 400), to: Vec2(430, 450))
        engine.undo()
        XCTAssertEqual(engine.sketches.count, 1)

        engine.setTool(.moveBrush)
        drag(engine, from: Vec2(500, 400), to: Vec2(500, 420))
        engine.undo()
        XCTAssertEqual(engine.sketches.count, 1, "nor does a brush take them with it")
    }

    func testMovingUnderAMirrorMovesBothSides() throws {
        let engine = pencil()
        engine.setSymmetryEnabled(true)
        Fixtures.drawPath(engine, straight(Vec2(420, 400), Vec2(470, 400)))
        tap(engine, at: Vec2(420, 400))
        let v = try XCTUnwrap(engine.selection.vertices.first)
        let partner = VertexID(engine.mesh.mirrorPartner[Int(v)])
        drag(engine, from: Vec2(420, 400), to: Vec2(420, 450))
        let a = engine.mesh.position(v), b = engine.mesh.position(partner)
        XCTAssertEqual(a.x, -b.x, accuracy: 1e-3)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-3)
    }
}
