import XCTest
import simd
@testable import LittleSurfaceCore

final class PencilTests: XCTestCase {
    private func pencil() -> RetopoEngine {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.pencil)
        return engine
    }

    /// A hand-drawn ring around a point, with its ends meeting.
    private func drawLoop(_ engine: RetopoEngine, center: Vec2, radius: Float) {
        Fixtures.drawPath(engine, Fixtures.circle(center: center, radius: radius, steps: 48))
    }

    private func straight(_ a: Vec2, _ b: Vec2, steps: Int = 24) -> [Vec2] {
        (0...steps).map { simd_mix(a, b, Vec2(repeating: Float($0) / Float(steps))) }
    }

    /// A box drawn in one stroke, starting partway along a side.
    private func drawBox(_ engine: RetopoEngine, _ low: Vec2, _ high: Vec2) {
        let corners = [Vec2(high.x, low.y), high, Vec2(low.x, high.y), low]
        var path = straight(Vec2((low.x + high.x) / 2, low.y), corners[0], steps: 12)
        for i in 0..<3 { path += straight(corners[i], corners[i + 1]).dropFirst() }
        path += straight(corners[3], Vec2((low.x + high.x) / 2, low.y), steps: 12).dropFirst()
        Fixtures.drawPath(engine, path)
    }

    private func drawFourLines(_ engine: RetopoEngine) {
        Fixtures.draw(engine, from: Vec2(440, 340), to: Vec2(560, 340))
        Fixtures.draw(engine, from: Vec2(560, 340), to: Vec2(560, 460))
        Fixtures.draw(engine, from: Vec2(560, 460), to: Vec2(440, 460))
        Fixtures.draw(engine, from: Vec2(440, 460), to: Vec2(440, 340))
    }

    private func checked(_ engine: RetopoEngine, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(engine.mesh.firstInvariantViolation(), file: file, line: line)
    }

    // MARK: Points

    func testALineHasAPointAtEachEndAndKeepsItsCurve() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(420, 400), to: Vec2(580, 400), bend: Vec2(0, 40))
        XCTAssertEqual(engine.statistics.vertices, 2)
        XCTAssertEqual(engine.statistics.edges, 1)
        XCTAssertGreaterThan(engine.mesh.bendCount, 5, "the curve is still there")
        checked(engine)
    }

    func testBendsAreTheSameOnScreenAtAnyZoom() {
        let far = pencil()
        Fixtures.draw(far, from: Vec2(420, 400), to: Vec2(580, 400))
        let near = pencil()
        near.camera.distance *= 0.6
        Fixtures.draw(near, from: Vec2(420, 400), to: Vec2(580, 400))
        XCTAssertEqual(near.mesh.edgeCount, far.mesh.edgeCount, accuracy: 3)
        XCTAssertEqual(near.statistics.vertices, far.statistics.vertices)
    }

    func testACrossingAddsAPointToBothLines() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(420, 400), to: Vec2(580, 400))
        Fixtures.draw(engine, from: Vec2(500, 320), to: Vec2(500, 480))
        XCTAssertEqual(engine.statistics.vertices, 5)
        XCTAssertEqual(engine.statistics.edges, 4)
        checked(engine)
    }

    func testASharpTurnIsAPointAndACurveIsNot() {
        let engine = pencil()
        Fixtures.drawPath(engine, straight(Vec2(420, 340), Vec2(420, 460)) + straight(Vec2(420, 460), Vec2(560, 460)).dropFirst())
        XCTAssertEqual(engine.statistics.vertices, 3)
        XCTAssertEqual(engine.statistics.edges, 2)

        let curved = pencil()
        Fixtures.draw(curved, from: Vec2(420, 340), to: Vec2(560, 460), bend: Vec2(-50, 50))
        XCTAssertEqual(curved.statistics.vertices, 2)
    }

    func testAShortOvershootPastALineIsLeftOut() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(420, 400), to: Vec2(580, 400))
        Fixtures.draw(engine, from: Vec2(500, 390), to: Vec2(500, 500))
        XCTAssertEqual(engine.statistics.vertices, 4, "it starts on the line")
    }

    func testAnEndNearALinePutsAPointOnIt() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(420, 400), to: Vec2(580, 400))
        Fixtures.draw(engine, from: Vec2(500, 500), to: Vec2(500, 408))
        XCTAssertEqual(engine.statistics.vertices, 4)
        XCTAssertEqual(engine.statistics.edges, 3)
    }

    func testAnEndNearARealPointLandsOnIt() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(420, 400), to: Vec2(580, 400))
        Fixtures.draw(engine, from: Vec2(430, 500), to: Vec2(430, 410))
        XCTAssertEqual(engine.statistics.vertices, 3)
    }

    func testCarryingALineOnLeavesNoPointWhereTheyJoin() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(400, 400), to: Vec2(480, 400))
        Fixtures.draw(engine, from: Vec2(490, 400), to: Vec2(580, 400))
        XCTAssertEqual(engine.statistics.vertices, 2)
    }

    // MARK: Shapes

    func testASmoothLoopIsOneShapeWithNoPointsOfItsOwn() {
        let engine = pencil()
        drawLoop(engine, center: Vec2(500, 400), radius: 80)
        XCTAssertEqual(engine.statistics.faces, 1)
        XCTAssertEqual(engine.statistics.quads, 0)
        XCTAssertEqual(engine.statistics.vertices, 0)
        checked(engine)
    }

    func testABoxInOneStrokeIsAQuadWithStraightSides() {
        let engine = pencil()
        drawBox(engine, Vec2(440, 340), Vec2(560, 460))
        XCTAssertEqual(engine.statistics.quads, 1)
        XCTAssertEqual(engine.mesh.vertexCount, 4, "nothing left of the curve")
        XCTAssertEqual(engine.mesh.bendCount, 0)
        checked(engine)
    }

    func testFourLinesAreAQuad() {
        let engine = pencil()
        drawFourLines(engine)
        XCTAssertEqual(engine.statistics.quads, 1)
        XCTAssertEqual(engine.mesh.vertexCount, 4)
        checked(engine)
    }

    func testThreeLinesAreAShapeThatKeepsItsCurve() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(440, 460), to: Vec2(560, 460))
        Fixtures.draw(engine, from: Vec2(560, 460), to: Vec2(500, 340))
        Fixtures.draw(engine, from: Vec2(500, 340), to: Vec2(440, 460))
        XCTAssertEqual(engine.statistics.faces, 1)
        XCTAssertEqual(engine.statistics.triangles, 1)
        XCTAssertEqual(engine.statistics.quads, 0)
        XCTAssertGreaterThan(engine.mesh.bendCount, 0)
    }

    func testALineTrailingOffDoesNotStopAShapeClosing() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(500, 400), to: Vec2(560, 340))
        Fixtures.draw(engine, from: Vec2(440, 340), to: Vec2(560, 340))
        Fixtures.draw(engine, from: Vec2(560, 340), to: Vec2(560, 460))
        Fixtures.draw(engine, from: Vec2(560, 460), to: Vec2(440, 460))
        Fixtures.draw(engine, from: Vec2(440, 460), to: Vec2(440, 340))
        XCTAssertEqual(engine.statistics.faces, 1)
        checked(engine)
    }

    func testALoopAroundTheWholeModelEnclosesNothing() {
        let engine = pencil()
        drawLoop(engine, center: Vec2(500, 500), radius: 900)
        XCTAssertEqual(engine.statistics.faces, 0)
    }

    func testUndoTakesBackAWholeStrokeAndItsShape() {
        let engine = pencil()
        drawFourLines(engine)
        engine.undo()
        XCTAssertEqual(engine.statistics.faces, 0)
        XCTAssertEqual(engine.statistics.vertices, 4, "the three lines before it")
        XCTAssertGreaterThan(engine.mesh.bendCount, 0, "and their curves")
    }

    // MARK: Leaving the app

    func testBendsDoNotLeaveTheApp() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(420, 400), to: Vec2(580, 400), bend: Vec2(0, 40))
        let line = engine.mesh.withoutBends()
        XCTAssertEqual(line.vertexCount, 2)
        XCTAssertEqual(line.edgeCount, 1)
        XCTAssertNil(line.firstInvariantViolation())
    }

    func testAShapeWithTooFewCornersKeepsItsCurveOnTheWayOut() {
        let engine = pencil()
        drawLoop(engine, center: Vec2(500, 400), radius: 80)
        let out = engine.mesh.withoutBends()
        XCTAssertEqual(out.faceCount, 1)
        XCTAssertEqual(out.vertexCount, engine.mesh.vertexCount)
    }

    func testAShapeWithEnoughCornersLosesItsCurveOnTheWayOut() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(440, 460), to: Vec2(560, 460))
        Fixtures.draw(engine, from: Vec2(560, 460), to: Vec2(500, 340))
        Fixtures.draw(engine, from: Vec2(500, 340), to: Vec2(440, 460))
        let out = engine.mesh.withoutBends()
        XCTAssertEqual(out.vertexCount, 3)
        XCTAssertEqual(out.faceCount, 1)
        XCTAssertNil(out.firstInvariantViolation())
    }

    func testBendsSurviveSavingAndOpening() throws {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(420, 400), to: Vec2(580, 400))
        let bends = engine.mesh.bendCount
        XCTAssertGreaterThan(bends, 0)
        let opened = try ProjectCodec.decode(ProjectCodec.encode(engine.makeSnapshot()))
        XCTAssertEqual(opened.mesh.bendCount, bends)
        XCTAssertEqual(MeshStatistics(opened.mesh).vertices, 2)
    }

    // MARK: Picking

    func testATapPicksAWholeLineAndAnEmptyTapLetsGo() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(420, 400), to: Vec2(580, 400))
        let total = engine.mesh.edgeCount
        engine.pencilBegan(at: Vec2(500, 400))
        engine.pencilEnded(at: Vec2(500, 400))
        XCTAssertEqual(engine.selection.edges.count, total)
        engine.pencilBegan(at: Vec2(500, 250))
        engine.pencilEnded(at: Vec2(500, 250))
        XCTAssertTrue(engine.selection.edges.isEmpty)
    }

    func testHoldingAPointPicksItUpAndDraggingMovesIt() throws {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(420, 400), to: Vec2(580, 400))
        let v = engine.mesh.aliveVertices[0]
        let start = engine.mesh.position(v)
        let screen = try XCTUnwrap(engine.camera.project(start)?.screen)
        let edges = engine.mesh.edgeCount
        engine.pencilBegan(at: screen)
        engine.pencilHeld()
        engine.pencilMoved(to: screen + Vec2(0, 40))
        engine.pencilEnded(at: screen + Vec2(0, 40))
        XCTAssertGreaterThan(simd_length(engine.mesh.position(v) - start), 0.01, "it moved")
        XCTAssertEqual(engine.mesh.edgeCount, edges, "and didn't draw")
        engine.undo()
        XCTAssertEqual(simd_length(engine.mesh.position(v) - start), 0, accuracy: 1e-5)
    }

    func testHoldingABendDoesNotPickItUp() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(420, 400), to: Vec2(580, 400))
        engine.pencilBegan(at: Vec2(500, 400))
        engine.pencilHeld()
        engine.pencilEnded(at: Vec2(500, 400))
        XCTAssertTrue(engine.selection.vertices.isEmpty)
    }

    func testDrawingFromAPointWithoutHoldingStartsALine() throws {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(420, 400), to: Vec2(580, 400))
        let v = engine.mesh.aliveVertices[0]
        let start = engine.mesh.position(v)
        let screen = try XCTUnwrap(engine.camera.project(start)?.screen)
        let edges = engine.mesh.edgeCount
        Fixtures.draw(engine, from: screen, to: screen + Vec2(0, 90))
        XCTAssertEqual(simd_length(engine.mesh.position(v) - start), 0, accuracy: 1e-5)
        XCTAssertGreaterThan(engine.mesh.edgeCount, edges)
    }

    func testAMovedPointDoesNotStayPicked() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(420, 400), to: Vec2(580, 400))
        let start = Vec2(420, 400)
        engine.pencilBegan(at: start)
        engine.pencilHeld()
        engine.pencilMoved(to: start + Vec2(0, 30))
        engine.pencilEnded(at: start + Vec2(0, 30))
        XCTAssertFalse(engine.hasPick)
    }

    func testDeletingAPickedLineRemovesIt() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(420, 400), to: Vec2(580, 400))
        engine.pencilBegan(at: Vec2(500, 400))
        engine.pencilEnded(at: Vec2(500, 400))
        engine.deletePick()
        XCTAssertEqual(engine.mesh.edgeCount, 0)
    }

    // MARK: Marks

    private func drawMark(_ engine: RetopoEngine, from a: Vec2, to b: Vec2) {
        engine.setTool(.sketch)
        Fixtures.draw(engine, from: a, to: b)
        engine.setTool(.pencil)
    }

    func testTappingAMarkPicksItAndDeletingTakesItOutAndUndoes() {
        let engine = pencil()
        drawMark(engine, from: Vec2(450, 400), to: Vec2(550, 400))
        engine.pencilBegan(at: Vec2(500, 400))
        engine.pencilEnded(at: Vec2(500, 400))
        XCTAssertEqual(engine.pickedMark, 0)
        XCTAssertTrue(engine.hasPick)
        engine.deletePick()
        XCTAssertTrue(engine.sketches.isEmpty)
        XCTAssertFalse(engine.hasPick)
        engine.undo()
        XCTAssertEqual(engine.sketches.count, 1)
    }

    // MARK: The eraser

    func testTheEraserTakesOutQuadsLinesAndMarksInOneUndo() {
        let engine = pencil()
        drawFourLines(engine)
        Fixtures.draw(engine, from: Vec2(440, 560), to: Vec2(560, 560))
        drawMark(engine, from: Vec2(440, 610), to: Vec2(560, 610))
        let faces = engine.mesh.faceCount, edges = engine.mesh.edgeCount, marks = engine.sketches.count
        XCTAssertGreaterThan(faces, 0)

        engine.setTool(.erase)
        engine.setSelectionMode(.face)
        Fixtures.draw(engine, from: Vec2(500, 380), to: Vec2(500, 640))
        XCTAssertLessThan(engine.mesh.faceCount, faces)
        XCTAssertLessThan(engine.mesh.edgeCount, edges)
        XCTAssertLessThan(engine.sketches.count, marks)
        checked(engine)

        engine.undo()
        XCTAssertEqual(engine.mesh.faceCount, faces)
        XCTAssertEqual(engine.mesh.edgeCount, edges)
        XCTAssertEqual(engine.sketches.count, marks)
    }

    func testTheEraserLeavesNoBendAtTheEndOfALine() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(420, 400), to: Vec2(580, 400))
        engine.setTool(.erase)
        engine.setSelectionMode(.face)
        Fixtures.draw(engine, from: Vec2(500, 380), to: Vec2(500, 420))
        XCTAssertGreaterThan(engine.mesh.edgeCount, 0, "the two sides are left")
        XCTAssertEqual(engine.statistics.vertices, 4, "each with a point at its new end")
        XCTAssertEqual(engine.statistics.edges, 2)
    }
}
