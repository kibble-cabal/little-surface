import XCTest
import simd
@testable import LittleSurfaceCore

/// What's been drawn stays until it's been used.
final class KeepingLinesTests: XCTestCase {
    private func pencil() -> RetopoEngine {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.pencil)
        return engine
    }

    private func drawLoop(_ engine: RetopoEngine, center: Vec2, radius: Float) {
        Fixtures.drawPath(engine, Fixtures.circle(center: center, radius: radius, steps: 48))
    }

    private func straight(_ a: Vec2, _ b: Vec2, steps: Int = 24) -> [Vec2] {
        (0...steps).map { simd_mix(a, b, Vec2(repeating: Float($0) / Float(steps))) }
    }

    private func drawRings(_ engine: RetopoEngine) {
        for radius: Float in [40, 70, 100] { drawLoop(engine, center: Vec2(500, 500), radius: radius) }
    }

    /// How far a point of the original drawing has ended up from the nearest point of the mesh.
    private func gap(_ engine: RetopoEngine, to screen: Vec2) throws -> Float {
        let hit = try XCTUnwrap(engine.projector?.raycast(engine.camera.ray(through: screen)))
        let mesh = engine.mesh
        return mesh.aliveVertices.map { simd_length(mesh.position($0) - hit.position) }.min() ?? .infinity
    }

    func testALineAcrossRingsKeepsThem() throws {
        let engine = pencil()
        drawRings(engine)
        Fixtures.drawPath(engine, straight(Vec2(500, 380), Vec2(500, 620)))
        for radius: Float in [40, 70, 100] {
            for side: Float in [-1, 1] {
                XCTAssertLessThan(try gap(engine, to: Vec2(500 + side * radius, 500)), 0.03)
            }
        }
        assertValid(engine.mesh)
    }

    func testTwoCutsAcrossRingsMakeQuadsOnlyWhereTheyPass() throws {
        let engine = pencil()
        drawRings(engine)
        Fixtures.drawPath(engine, straight(Vec2(485, 385), Vec2(485, 475)))
        Fixtures.drawPath(engine, straight(Vec2(515, 385), Vec2(515, 475)))
        // Between the cuts, each band of ring has gone straight. The long way round is still there, curved.
        XCTAssertEqual(engine.statistics.quads, 2)
        for radius: Float in [40, 70, 100] {
            XCTAssertLessThan(try gap(engine, to: Vec2(500, 500 + radius)), 0.03)
            XCTAssertLessThan(try gap(engine, to: Vec2(500 - radius, 500)), 0.03)
        }
        XCTAssertLessThan(try gap(engine, to: Vec2(500, 400)), 0.1)
        assertValid(engine.mesh)
    }

    func testARingCutIntoFourBecomesQuads() {
        let engine = pencil()
        drawLoop(engine, center: Vec2(500, 500), radius: 100)
        drawLoop(engine, center: Vec2(500, 500), radius: 50)
        let center = Vec2(500, 500)
        for way in [Vec2(1, 0), Vec2(0, 1), Vec2(-1, 0), Vec2(0, -1)] {
            Fixtures.drawPath(engine, straight(center + way * 40, center + way * 110))
        }
        // Four around the ring, and the middle now has four points as well.
        XCTAssertEqual(engine.statistics.quads, 5)
        assertValid(engine.mesh)
    }

    func testAFaceWithFourCornersAndALongCurveKeepsItsCurveOnExport() {
        let engine = pencil()
        drawRings(engine)
        Fixtures.drawPath(engine, straight(Vec2(485, 385), Vec2(485, 475)))
        Fixtures.drawPath(engine, straight(Vec2(515, 385), Vec2(515, 475)))
        let out = engine.mesh.withoutBends()
        XCTAssertGreaterThan(out.bendCount, 0)
        assertValid(out)
    }

    // MARK: Points only where they're meant

    private func realPoints(_ engine: RetopoEngine) -> Int { engine.mesh.vertexCount - engine.mesh.bendCount }

    func testAFlickAsThePencilLiftsIsNotAPoint() {
        let engine = pencil()
        Fixtures.drawPath(engine, straight(Vec2(400, 500), Vec2(600, 500)) + straight(Vec2(600, 500), Vec2(610, 488), steps: 3).dropFirst())
        XCTAssertEqual(realPoints(engine), 2)
    }

    func testAFlickAsThePencilLandsIsNotAPoint() {
        let engine = pencil()
        Fixtures.drawPath(engine, straight(Vec2(390, 488), Vec2(400, 500), steps: 3) + straight(Vec2(400, 500), Vec2(600, 500)).dropFirst())
        XCTAssertEqual(realPoints(engine), 2)
    }

    func testACurlAtTheEndIsNotAPoint() {
        let engine = pencil()
        let curl = (0...7).map { Vec2(600, 496) + Vec2(sin(Float($0) * 0.7), cos(Float($0) * 0.7)) * 4 }
        Fixtures.drawPath(engine, straight(Vec2(400, 500), Vec2(600, 500)) + curl)
        XCTAssertEqual(realPoints(engine), 2)
    }

    func testASharpCornerAwayFromTheEndsIsStillAPoint() {
        let engine = pencil()
        Fixtures.drawPath(engine, straight(Vec2(400, 500), Vec2(500, 500)) + straight(Vec2(500, 500), Vec2(500, 600)).dropFirst())
        XCTAssertEqual(realPoints(engine), 3)
    }

    func testACrossingBesideAPointUsesThatPoint() {
        let engine = pencil()
        Fixtures.drawPath(engine, straight(Vec2(400, 500), Vec2(600, 500)))
        Fixtures.drawPath(engine, straight(Vec2(500, 400), Vec2(500, 600)))
        XCTAssertEqual(realPoints(engine), 5)
        Fixtures.drawPath(engine, straight(Vec2(514, 460), Vec2(514, 540)))
        XCTAssertEqual(realPoints(engine), 7, "Its ends, but the one in the middle meets the crossing that's there")
    }

    // MARK: The eraser

    private func eraser(_ engine: RetopoEngine, radius: Float = 12) {
        engine.setTool(.erase)
        engine.tools.brush.radiusPoints = radius
    }

    private func tap(_ engine: RetopoEngine, _ at: Vec2) {
        engine.pencilBegan(at: at)
        engine.pencilEnded(at: at)
    }

    private func drawBoxOfLines(_ engine: RetopoEngine) {
        for y: Float in [420, 580] { Fixtures.drawPath(engine, straight(Vec2(390, y), Vec2(610, y))) }
        for x: Float in [400, 500, 600] { Fixtures.drawPath(engine, straight(Vec2(x, 410), Vec2(x, 590))) }
    }

    func testDeletingAPointOnALineLetsTheLineCarryOn() {
        let engine = pencil()
        Fixtures.drawPath(engine, straight(Vec2(400, 500), Vec2(600, 500)))
        Fixtures.drawPath(engine, straight(Vec2(500, 480), Vec2(500, 520)))
        // The tick only left a point behind.
        XCTAssertEqual(realPoints(engine), 3)
        let edges = engine.mesh.edgeCount
        tap(engine, Vec2(500, 500))
        engine.deletePick()
        XCTAssertEqual(realPoints(engine), 2)
        XCTAssertEqual(engine.mesh.edgeCount, edges)
        engine.undo()
        XCTAssertEqual(realPoints(engine), 3)
    }

    func testErasingAtACrossingTakesBothLinesUpToTheirPoints() {
        let engine = pencil()
        Fixtures.drawPath(engine, straight(Vec2(400, 500), Vec2(600, 500)))
        Fixtures.drawPath(engine, straight(Vec2(500, 400), Vec2(500, 600)))
        let before = engine.mesh.vertexCount
        eraser(engine)
        tap(engine, Vec2(500, 500))
        XCTAssertLessThan(engine.mesh.vertexCount, before)
        XCTAssertFalse(engine.mesh.aliveVertices.contains { engine.mesh.edgesOf($0).count > 2 })
        assertValid(engine.mesh)
    }

    func testErasingALineBetweenTwoQuadsMakesOneShape() {
        let engine = pencil()
        drawBoxOfLines(engine)
        XCTAssertEqual(engine.statistics.quads, 2)
        eraser(engine)
        tap(engine, Vec2(500, 500))
        XCTAssertEqual(engine.statistics.quads, 0)
        XCTAssertEqual(engine.mesh.aliveFaces.map { engine.mesh.cornerCount(of: $0) }, [6])
        assertValid(engine.mesh)
    }

    func testErasingACurveTakesAllOfIt() {
        let engine = pencil()
        Fixtures.drawPath(engine, Fixtures.circle(center: Vec2(500, 500), radius: 100, steps: 48, closes: false))
        eraser(engine, radius: 10)
        tap(engine, Vec2(500, 600))
        XCTAssertEqual(engine.mesh.edgeCount, 0)
    }

    func testTheEraserStopsAtALinesPoints() {
        let engine = pencil()
        Fixtures.drawPath(engine, straight(Vec2(400, 500), Vec2(600, 500)))
        Fixtures.drawPath(engine, straight(Vec2(500, 480), Vec2(500, 520)))
        eraser(engine)
        tap(engine, Vec2(450, 500))
        XCTAssertEqual(realPoints(engine), 2, "the far side and the point it stopped at")
        XCTAssertEqual(engine.statistics.edges, 1)
    }

    func testRubbingInsideAShapeLeavesItAlone() {
        let engine = pencil()
        drawBoxOfLines(engine)
        let faces = engine.mesh.faceCount, edges = engine.mesh.edgeCount, depth = engine.history.undoStack.count
        eraser(engine)
        Fixtures.drawPath(engine, [Vec2(450, 480), Vec2(450, 500), Vec2(460, 520)])
        XCTAssertEqual(engine.mesh.faceCount, faces)
        XCTAssertEqual(engine.mesh.edgeCount, edges)
        XCTAssertEqual(engine.history.undoStack.count, depth, "nothing to take back")
    }

    func testNothingGoesUntilTheEraserLifts() {
        let engine = pencil()
        Fixtures.drawPath(engine, straight(Vec2(400, 500), Vec2(600, 500)))
        let edges = engine.mesh.edgeCount
        eraser(engine)
        engine.pencilBegan(at: Vec2(500, 450))
        XCTAssertTrue(engine.overlay.erasingEdges.isEmpty)
        engine.pencilMoved(to: Vec2(500, 500))
        XCTAssertEqual(engine.mesh.edgeCount, edges)
        XCTAssertEqual(engine.overlay.erasingEdges.count, edges * 2, "the whole line shows")
        engine.pencilEnded(at: Vec2(500, 500))
        XCTAssertEqual(engine.mesh.edgeCount, 0)
        XCTAssertTrue(engine.overlay.erasingEdges.isEmpty)
    }

    func testAnEraserCancelledPartWayTakesNothing() {
        let engine = pencil()
        Fixtures.drawPath(engine, straight(Vec2(400, 500), Vec2(600, 500)))
        let edges = engine.mesh.edgeCount, depth = engine.history.undoStack.count
        eraser(engine)
        engine.pencilBegan(at: Vec2(500, 500))
        engine.pencilCancelled()
        XCTAssertEqual(engine.mesh.edgeCount, edges)
        XCTAssertEqual(engine.history.undoStack.count, depth)
        XCTAssertTrue(engine.overlay.erasingEdges.isEmpty)
    }

    func testAFastRubStillReachesWhatItPassedOver() {
        let engine = pencil()
        Fixtures.drawPath(engine, straight(Vec2(400, 500), Vec2(600, 500)))
        eraser(engine)
        // One long jump, right over the line.
        engine.pencilBegan(at: Vec2(500, 300))
        engine.pencilMoved(to: Vec2(500, 700))
        engine.pencilEnded(at: Vec2(500, 700))
        XCTAssertEqual(engine.mesh.edgeCount, 0)
    }

    func testTheEraserWorksOnBothSidesOfTheMirror() {
        let engine = pencil()
        engine.setSymmetryEnabled(true)
        Fixtures.drawPath(engine, straight(Vec2(350, 500), Vec2(450, 500)))
        XCTAssertEqual(realPoints(engine), 4)
        eraser(engine)
        engine.pencilBegan(at: Vec2(400, 500))
        XCTAssertEqual(engine.overlay.erasingEdges.count, engine.mesh.edgeCount * 2, "both sides show")
        engine.pencilEnded(at: Vec2(400, 500))
        XCTAssertEqual(engine.mesh.edgeCount, 0)
    }

    // MARK: Seeing points as they're made

    private func moveAlong(_ engine: RetopoEngine, _ path: [Vec2]) {
        engine.pencilBegan(at: path[0])
        for p in path.dropFirst() { engine.pencilMoved(to: p) }
    }

    func testADotShowsWhereAStrokeCrossesALineAsItGoes() {
        let engine = pencil()
        Fixtures.drawPath(engine, straight(Vec2(400, 500), Vec2(600, 500)))
        moveAlong(engine, straight(Vec2(500, 400), Vec2(500, 480), steps: 10))
        XCTAssertEqual(engine.overlay.previewPoints.count, 0)
        for p in straight(Vec2(500, 480), Vec2(500, 560), steps: 10).dropFirst() { engine.pencilMoved(to: p) }
        XCTAssertEqual(engine.overlay.previewPoints.count, 1)
        engine.pencilEnded(at: Vec2(500, 560))
        XCTAssertEqual(engine.overlay.previewPoints.count, 0, "The real point has taken over")
        XCTAssertEqual(realPoints(engine), 5)
    }

    func testTheDotIsWhereThePointEndsUp() throws {
        let engine = pencil()
        Fixtures.drawPath(engine, straight(Vec2(400, 500), Vec2(600, 500)))
        moveAlong(engine, straight(Vec2(460, 420), Vec2(460, 580), steps: 30))
        let dot = try XCTUnwrap(engine.overlay.previewPoints.first)
        engine.pencilEnded(at: Vec2(460, 580))
        let mesh = engine.mesh
        let nearest = mesh.aliveVertices.filter { !mesh.isBendVertex($0) }.map { simd_length(mesh.position($0) - dot) }.min() ?? .infinity
        XCTAssertLessThan(nearest, 0.02)
    }

    func testDotsMirrorAndOneShowsWhereTheStrokeStopsAtTheMiddle() {
        let engine = pencil()
        engine.setSymmetryEnabled(true)
        Fixtures.drawPath(engine, straight(Vec2(420, 420), Vec2(420, 580)))
        moveAlong(engine, straight(Vec2(380, 500), Vec2(560, 500), steps: 40))
        // Crossing the line, its mirror image, and the middle, where it stopped.
        XCTAssertEqual(engine.overlay.previewPoints.count, 3)
        engine.pencilCancelled()
        XCTAssertEqual(engine.overlay.previewPoints.count, 0)
    }

    func testNoDotForALineOnTheFarSide() {
        let engine = pencil()
        Fixtures.drawPath(engine, straight(Vec2(400, 500), Vec2(600, 500)))
        var back = Fixtures.frontCamera()
        back.setPreset(.back)
        engine.camera = back
        moveAlong(engine, straight(Vec2(500, 400), Vec2(500, 600), steps: 30))
        XCTAssertEqual(engine.overlay.previewPoints.count, 0)
        engine.pencilCancelled()
    }

    // MARK: Why a shape isn't finished

    private func tapShape(_ engine: RetopoEngine, at: Vec2) {
        engine.pencilBegan(at: at)
        engine.pencilEnded(at: at)
    }

    func testPickingAShapeSaysHowManyPointsItHasAndShowsThem() {
        let engine = pencil()
        for y: Float in [420, 580] { Fixtures.drawPath(engine, straight(Vec2(390, y), Vec2(610, y))) }
        for x: Float in [400, 600] { Fixtures.drawPath(engine, straight(Vec2(x, 410), Vec2(x, 590))) }
        Fixtures.drawPath(engine, straight(Vec2(500, 400), Vec2(500, 440)))
        tapShape(engine, at: Vec2(500, 500))
        XCTAssertEqual(engine.pickNote, "5 points")
        XCTAssertEqual(engine.overlay.previewPoints.count, 5)
        engine.clearPick()
        XCTAssertNil(engine.pickNote)
        XCTAssertEqual(engine.overlay.previewPoints.count, 0)
    }

    func testPickingAQuadSaysNothing() {
        let engine = pencil()
        for y: Float in [420, 580] { Fixtures.drawPath(engine, straight(Vec2(390, y), Vec2(610, y))) }
        for x: Float in [400, 600] { Fixtures.drawPath(engine, straight(Vec2(x, 410), Vec2(x, 590))) }
        tapShape(engine, at: Vec2(500, 500))
        XCTAssertEqual(engine.selection.faces.count, 1)
        XCTAssertNil(engine.pickNote)
    }

    func testPickingFourPointsWithALongCurveSaysSo() {
        let engine = pencil()
        for radius: Float in [50, 100] { drawLoop(engine, center: Vec2(500, 500), radius: radius) }
        Fixtures.drawPath(engine, straight(Vec2(485, 390), Vec2(485, 460)))
        Fixtures.drawPath(engine, straight(Vec2(515, 390), Vec2(515, 460)))
        tapShape(engine, at: Vec2(500, 575))
        XCTAssertEqual(engine.pickNote, "4 points, but a side curves too far to go straight")
    }

    // MARK: What's exported

    func testUnusedLinesAreLeftOutOfExportsAndKeptInTheFile() throws {
        let engine = pencil()
        for y: Float in [420, 580] { Fixtures.drawPath(engine, straight(Vec2(390, y), Vec2(610, y))) }
        for x: Float in [400, 600] { Fixtures.drawPath(engine, straight(Vec2(x, 410), Vec2(x, 590))) }
        Fixtures.drawPath(engine, straight(Vec2(420, 300), Vec2(580, 300)))
        XCTAssertGreaterThan(engine.mesh.bendCount, 0)

        let out = engine.mesh.forExport()
        XCTAssertEqual(out.faceCount, 1)
        XCTAssertEqual(out.vertexCount, 4)
        XCTAssertEqual(out.edgeCount, 4)
        assertValid(out)
        let obj = String(decoding: OBJExporter.export(mesh: out, name: "t", sources: [], options: ExportOptions()), as: UTF8.self)
        XCTAssertFalse(obj.contains("\nl "))
        XCTAssertEqual(obj.components(separatedBy: "\nf ").count - 1, 1)

        let saved = try ProjectCodec.decode(try ProjectCodec.encode(engine.makeSnapshot()))
        XCTAssertEqual(saved.mesh.edgeCount, engine.mesh.edgeCount, "Still in the project")
    }

    func testLinesWithNoFacesExportNothing() {
        let engine = pencil()
        Fixtures.drawPath(engine, straight(Vec2(420, 300), Vec2(580, 300)))
        let out = engine.mesh.forExport()
        XCTAssertEqual(out.vertexCount, 0)
        XCTAssertEqual(out.edgeCount, 0)
    }
}

/// Going back over a line is part of drawing it.
final class RetracedLineTests: XCTestCase {
    private func straight(_ a: Vec2, _ b: Vec2, bow: Float = 0, steps: Int = 24) -> [Vec2] {
        let across = simd_normalize(Vec2(b.y - a.y, a.x - b.x))
        return (0...steps).map { i in
            let t = Float(i) / Float(steps)
            return simd_mix(a, b, Vec2(repeating: t)) + across * bow * sin(t * .pi)
        }
    }

    private func triangle() -> RetopoEngine {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.pencil)
        Fixtures.drawPath(engine, straight(Vec2(400, 420), Vec2(600, 420), bow: 20))
        Fixtures.drawPath(engine, straight(Vec2(600, 420), Vec2(500, 600)))
        Fixtures.drawPath(engine, straight(Vec2(500, 600), Vec2(400, 420)))
        return engine
    }

    func testGoingBackOverALineLeavesNoSliver() throws {
        let engine = triangle()
        XCTAssertEqual(engine.mesh.faceCount, 1)
        Fixtures.drawPath(engine, straight(Vec2(400, 420), Vec2(600, 420), bow: 24))
        let mesh = engine.mesh
        XCTAssertEqual(mesh.faceCount, 1, "no sliver between the two")
        XCTAssertEqual(mesh.aliveFaces.first.map(mesh.cornerCount(of:)), 3)
        XCTAssertTrue(mesh.aliveEdges.allSatisfy { !mesh.isWire($0) }, "nothing left over")
    }

    private func joined(turning degrees: Float) -> Mesh {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.pencil)
        let join = Vec2(500, 500)
        Fixtures.drawPath(engine, straight(Vec2(380, 500), join))
        let angle = degrees * .pi / 180
        Fixtures.drawPath(engine, straight(join, join + Vec2(cos(angle), sin(angle)) * 120))
        return engine.mesh
    }

    func testCarryingALineOnWithAGentleTurnLeavesNoCorner() {
        let mesh = joined(turning: 50)
        XCTAssertEqual(mesh.aliveVertices.filter { !mesh.isBendVertex($0) }.count, 2, "Only its two ends")
    }

    func testCarryingALineOnWithASharpTurnLeavesACorner() {
        let mesh = joined(turning: 80)
        XCTAssertEqual(mesh.aliveVertices.filter { !mesh.isBendVertex($0) }.count, 3)
    }

    func testGoingOverPartOfALineRedrawsThatPart() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.pencil)
        Fixtures.drawPath(engine, straight(Vec2(380, 500), Vec2(620, 500), bow: 0))
        Fixtures.drawPath(engine, straight(Vec2(450, 500), Vec2(550, 500), bow: 9))
        let mesh = engine.mesh
        XCTAssertEqual(mesh.faceCount, 0, "no sliver between the stroke and the line")
        XCTAssertEqual(mesh.aliveVertices.filter { mesh.edgesOf($0).count == 1 }.count, 2, "still one line")
        XCTAssertTrue(mesh.aliveVertices.allSatisfy { mesh.edgesOf($0).count <= 2 })
        // The new stroke is what stayed, so the line now bows out where it was drawn.
        let screens = mesh.aliveVertices.compactMap { engine.camera.project(mesh.position($0))?.screen }
        let highest = screens.map { abs($0.y - 500) }.max() ?? 0
        XCTAssertEqual(highest, 9, accuracy: 3)
    }

    func testAStrokeOutAndBackAlongItselfIsOneLine() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.pencil)
        var path = straight(Vec2(450, 500), Vec2(560, 500))
        path += straight(Vec2(560, 504), Vec2(452, 508))
        Fixtures.drawPath(engine, path)
        let mesh = engine.mesh
        XCTAssertEqual(mesh.faceCount, 0, "not a closed shape")
        XCTAssertGreaterThan(mesh.edgeCount, 0)
    }

    func testGoingOverPartOfALineWithMirrorOnStaysMatched() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.pencil)
        engine.setSymmetryEnabled(true)
        Fixtures.drawPath(engine, straight(Vec2(260, 500), Vec2(440, 500), bow: 0))
        Fixtures.drawPath(engine, straight(Vec2(330, 500), Vec2(410, 500), bow: 9))
        let mesh = engine.mesh
        XCTAssertEqual(mesh.faceCount, 0)
        XCTAssertEqual(mesh.aliveVertices.filter { mesh.edgesOf($0).count == 1 }.count, 4, "one line each side")
        let plane = MirrorPlane(axis: .x, offset: 0)
        for v in mesh.aliveVertices {
            let partner = mesh.mirrorPartner[Int(v)]
            XCTAssertGreaterThanOrEqual(partner, 0)
            guard partner >= 0 else { continue }
            XCTAssertTrue(mesh.isVertexAlive(VertexID(partner)))
            XCTAssertLessThan(simd_length(plane.reflect(mesh.position(v)) - mesh.position(VertexID(partner))), 0.005)
        }
    }

    func testAStrokeFromNearALinesEndWithMirrorOnStaysMatched() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.pencil)
        engine.setSymmetryEnabled(true)
        Fixtures.drawPath(engine, straight(Vec2(300, 500), Vec2(440, 500), bow: 0))
        Fixtures.drawPath(engine, straight(Vec2(330, 500), Vec2(410, 500), bow: 9))
        let mesh = engine.mesh
        let plane = MirrorPlane(axis: .x, offset: 0)
        XCTAssertEqual(mesh.faceCount % 2, 0, "whatever it makes, it makes on both sides")
        for v in mesh.aliveVertices where !mesh.isBendVertex(v) {
            let partner = mesh.mirrorPartner[Int(v)]
            XCTAssertGreaterThanOrEqual(partner, 0)
            guard partner >= 0, mesh.isVertexAlive(VertexID(partner)) else {
                XCTFail("A point whose mirror image has gone")
                continue
            }
            XCTAssertLessThan(simd_length(plane.reflect(mesh.position(v)) - mesh.position(VertexID(partner))), 0.005)
        }
    }

    func testANarrowShapeDrawnOnPurposeStays() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.pencil)
        Fixtures.drawPath(engine, straight(Vec2(400, 500), Vec2(600, 500), bow: 12))
        Fixtures.drawPath(engine, straight(Vec2(600, 500), Vec2(400, 500), bow: 12))
        let mesh = engine.mesh
        XCTAssertEqual(mesh.faceCount, 1, "a thin almond, 24 across and 200 long")
        XCTAssertEqual(mesh.aliveFaces.first.map(mesh.cornerCount(of:)), 2)
    }

    func testTwoLinesWellApartAreStillAShape() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.pencil)
        Fixtures.drawPath(engine, straight(Vec2(400, 500), Vec2(600, 500), bow: 40))
        Fixtures.drawPath(engine, straight(Vec2(600, 500), Vec2(400, 500), bow: 40))
        let mesh = engine.mesh
        XCTAssertEqual(mesh.faceCount, 1, "an eye drawn in two strokes")
        XCTAssertEqual(mesh.aliveFaces.first.map(mesh.cornerCount(of:)), 2)
    }
}

final class StarPointTests: XCTestCase {
    func testOnlyPointsWithFiveOrMoreLinesAreStars() throws {
        var mesh = Mesh()
        let center = mesh.addVertex(.zero)
        let around = (0..<5).map { mesh.addVertex(Vec3(cos(Float($0)), sin(Float($0)), 0)) }
        for v in around.prefix(4) { _ = try mesh.ensureEdge(center, v) }
        XCTAssertEqual(MeshValidator.stars(mesh), [], "four lines is a normal point")
        _ = try mesh.ensureEdge(center, around[4])
        XCTAssertEqual(MeshValidator.stars(mesh), [center])
    }
}

/// A straight edge can stand well off the model where it spans a dip.
final class LooseLinesTests: XCTestCase {
    private func engine() -> RetopoEngine {
        let engine = Fixtures.engine(with: Fixtures.plane(size: 8), camera: Fixtures.frontCamera())
        engine.setTool(.pencil)
        return engine
    }

    private func straight(_ a: Vec2, _ b: Vec2, steps: Int = 24) -> [Vec2] {
        (0...steps).map { simd_mix(a, b, Vec2(repeating: Float($0) / Float(steps))) }
    }

    func testAStrokePassingRightByALooseEndJoinsIt() {
        let engine = engine()
        Fixtures.drawPath(engine, straight(Vec2(400, 590), Vec2(300, 590)))
        let before = engine.statistics.vertices
        // It stops 3pt short of this one, so nothing actually crosses.
        Fixtures.drawPath(engine, straight(Vec2(403, 450), Vec2(403, 730)))
        XCTAssertEqual(engine.statistics.vertices, before + 2, "only the new stroke's ends are new points")
        let mesh = engine.mesh
        let joined = mesh.aliveVertices.filter { mesh.edgesOf($0).count == 3 }
        XCTAssertEqual(joined.count, 1, "the loose end is now part of the stroke")
    }

    func testAStrokePassingWellClearOfALooseEndLeavesItAlone() {
        let engine = engine()
        Fixtures.drawPath(engine, straight(Vec2(400, 590), Vec2(300, 590)))
        Fixtures.drawPath(engine, straight(Vec2(440, 450), Vec2(440, 730)))
        let mesh = engine.mesh
        XCTAssertFalse(mesh.aliveVertices.contains { mesh.edgesOf($0).count == 3 })
    }

    func testDrawingOverALooseLineTakesItsPlace() {
        let engine = engine()
        Fixtures.drawPath(engine, straight(Vec2(300, 590), Vec2(500, 590)))
        Fixtures.drawPath(engine, straight(Vec2(200, 591), Vec2(600, 591)))
        XCTAssertEqual(engine.statistics.vertices, 2, "one line, with only the stroke's ends as points")
    }

    func testALineBesideALooseLineIsKept() {
        let engine = engine()
        Fixtures.drawPath(engine, straight(Vec2(300, 590), Vec2(500, 590)))
        Fixtures.drawPath(engine, straight(Vec2(300, 640), Vec2(500, 640)))
        XCTAssertEqual(engine.statistics.vertices, 4)
    }
}

final class LinesOverADipTests: XCTestCase {
    /// A bowl facing the camera, steep enough that an edge across it is far from the bottom.
    private func bowl() -> SourceObject {
        var positions: [Vec3] = []
        var indices: [UInt32] = []
        let divisions = 60
        for y in 0...divisions {
            for x in 0...divisions {
                let p = Vec2(Float(x), Float(y)) / Float(divisions) * 4 - 2
                positions.append(Vec3(p.x, p.y, simd_length_squared(p) * 0.8))
            }
        }
        let stride = UInt32(divisions + 1)
        for y in 0..<UInt32(divisions) {
            for x in 0..<UInt32(divisions) {
                let a = y * stride + x, b = a + 1, c = a + stride + 1, d = a + stride
                indices += [a, b, c, a, c, d]
            }
        }
        return SourceObject(name: "Bowl", positions: positions, indices: indices)
    }

    private func straight(_ a: Vec2, _ b: Vec2, steps: Int = 24) -> [Vec2] {
        (0...steps).map { simd_mix(a, b, Vec2(repeating: Float($0) / Float(steps))) }
    }

    private func engineWithEdgeAcrossBowl() throws -> RetopoEngine {
        var camera = Fixtures.frontCamera(distance: 9)
        camera.sceneRadius = 4
        let engine = Fixtures.engine(with: bowl(), camera: camera)
        engine.setTool(.pencil)
        engine.perform("Edge") { mesh, _ in
            let a = mesh.addVertex(Vec3(-1, 0, 0.8)), b = mesh.addVertex(Vec3(1, 0, 0.8))
            _ = try mesh.ensureEdge(a, b)
        }
        return engine
    }

    func testAStraightLineThatIsNoLongerAQuadsSideGoesBackOnTheModel() throws {
        let engine = try engineWithEdgeAcrossBowl()
        let start = try XCTUnwrap(engine.camera.project(Vec3(-1, 0, 0.8))).screen
        // Any stroke brings the drawing up to date.
        Fixtures.drawPath(engine, straight(start + Vec2(-30, -90), start + Vec2(30, -90)))
        let mesh = engine.mesh
        XCTAssertEqual(engine.statistics.vertices, 4, "the line gains no points of its own")
        let onTheLine = mesh.aliveVertices.filter { mesh.isBendVertex($0) && abs(mesh.position($0).y) < 0.05 }
        XCTAssertFalse(onTheLine.isEmpty, "it has to bend to follow the bowl")
        for v in onTheLine {
            let gap = try XCTUnwrap(engine.projector?.closest(to: mesh.position(v), maxDistance: .greatestFiniteMagnitude))
            XCTAssertLessThan(simd_length(gap.position - mesh.position(v)), 0.01)
        }
    }

    func testAStrokeOverTheDipCrossesTheEdgeAboveIt() throws {
        let engine = try engineWithEdgeAcrossBowl()
        XCTAssertEqual(engine.statistics.vertices, 2)
        let middle = try XCTUnwrap(engine.camera.project(Vec3(0, 0, 0.8))).screen
        Fixtures.drawPath(engine, straight(middle + Vec2(0, -60), middle + Vec2(0, 60)))
        XCTAssertEqual(engine.statistics.vertices, 5, "its two ends, the edge's two ends, and where they cross")
    }
}

/// A quad's sides go straight unless they wrap around something, which a bump on the way doesn't.
final class WrappingSideTests: XCTestCase {
    /// A square whose top side follows these points, in the plane z = 0 unless they say otherwise.
    private func face(topSide: [Vec3]) throws -> (Mesh, FaceID) {
        var mesh = Mesh()
        let a = mesh.addVertex(Vec3(-1, 0, 0)), b = mesh.addVertex(Vec3(1, 0, 0))
        let c = mesh.addVertex(Vec3(1, -2, 0)), d = mesh.addVertex(Vec3(-1, -2, 0))
        let bends = topSide.map { mesh.addVertex($0) }
        for v in bends { mesh.setBend(v, true) }
        let f = try mesh.addFace([a] + bends + [b, c, d], autoOrient: false)
        return (mesh, f)
    }

    private func arc(degrees: Float) -> [Vec3] {
        let half = degrees * .pi / 360, radius = 1 / sin(half)
        return (1..<24).map { i in
            let angle = -half + 2 * half * Float(i) / 24
            return Vec3(radius * sin(angle), radius * (cos(angle) - cos(half)), 0)
        }
    }

    func testASideOverABumpGoesStraight() throws {
        // Flat, up over a nose and flat again, about 1.4 times as long as the straight line.
        let side = [Vec3(-0.7, 0, 0), Vec3(-0.3, 0, 0), Vec3(-0.1, 0, 0.35), Vec3(0.1, 0, 0.35), Vec3(0.3, 0, 0), Vec3(0.7, 0, 0)]
        let (mesh, f) = try face(topSide: side)
        XCTAssertTrue(mesh.isQuad(f))
    }

    func testASideAroundAThirdOfARingGoesStraight() throws {
        let (mesh, f) = try face(topSide: arc(degrees: 115))
        XCTAssertTrue(mesh.isQuad(f))
    }

    func testASideAroundHalfARingStaysCurved() throws {
        let (mesh, f) = try face(topSide: arc(degrees: 180))
        XCTAssertFalse(mesh.isQuad(f))
    }

    func testASideJustPastTheLimitStaysCurved() throws {
        // A circular arc of 140 degrees is about 1.31 times its straight line, and it's still wrapping.
        let (mesh, f) = try face(topSide: arc(degrees: 140))
        XCTAssertFalse(mesh.isQuad(f))
    }

    func testAScribbledSideStaysCurved() throws {
        // Zigzags head the same way at both ends, but it's far too long to be a bump.
        let side = (1..<16).map { i in Vec3(-1 + Float(i) / 8, i % 2 == 0 ? 0 : 0.4, 0) }
        let (mesh, f) = try face(topSide: side)
        XCTAssertFalse(mesh.isQuad(f))
    }
}

final class EnclosedRegionTests: XCTestCase {
    func testABendJustInsideTheOutlineDoesNotBlockTheShape() throws {
        // A cut from a to b, under c. It crossed the line from c down to d right beside that line's bend,
        // so the bend is outside the turn from a to c, but on this rising surface it's a hair inside the shape.
        var mesh = Mesh()
        let a = mesh.addVertex(Vec3(-1, 0, 0)), b = mesh.addVertex(Vec3(1, 0, 0)), c = mesh.addVertex(Vec3(0, 1, 1))
        let d = mesh.addVertex(Vec3(-1.3, -1, 0)), e = mesh.addVertex(Vec3(1.3, -1, 0))
        let bend = mesh.addVertex(Vec3(-0.99, 0.02, -0.01))
        mesh.setBend(bend, true)
        var edges: [EdgeID] = []
        for (from, to) in [(a, b), (b, c), (c, a), (a, bend), (bend, d), (d, e), (e, b)] { edges.append(try mesh.ensureEdge(from, to)) }
        let regions = EnclosedRegions.regions(bordering: edges, in: mesh, projector: Fixtures.projector(Fixtures.plane()))
        XCTAssertTrue(regions.contains { Set($0.vertices) == [a, b, c] }, "the triangle above the cut")
        XCTAssertTrue(regions.contains { Set($0.vertices) == [a, bend, d, e, b] }, "the shape below it")
    }

    func testARealShapeInsideTheOutlineStillBlocksIt() throws {
        var mesh = Mesh()
        let corners = [Vec3(-1, -1, 0), Vec3(1, -1, 0), Vec3(1, 1, 0), Vec3(-1, 1, 0)].map { mesh.addVertex($0) }
        var edges: [EdgeID] = []
        for i in 0..<4 { edges.append(try mesh.ensureEdge(corners[i], corners[(i + 1) % 4])) }
        let inner = [Vec3(-0.2, -0.2, 0), Vec3(0.2, -0.2, 0), Vec3(0, 0.2, 0)].map { mesh.addVertex($0) }
        for i in 0..<3 { _ = try mesh.ensureEdge(inner[i], inner[(i + 1) % 3]) }
        let regions = EnclosedRegions.regions(bordering: edges, in: mesh, projector: Fixtures.projector(Fixtures.plane()))
        XCTAssertFalse(regions.contains { Set($0.vertices) == Set(corners) })
    }
}
