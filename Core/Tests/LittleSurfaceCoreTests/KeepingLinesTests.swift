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
        engine.setSelectionMode(.face)
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

    func testErasingAPointOnALineLetsTheLineCarryOn() {
        let engine = pencil()
        Fixtures.drawPath(engine, straight(Vec2(400, 500), Vec2(600, 500)))
        Fixtures.drawPath(engine, straight(Vec2(500, 480), Vec2(500, 520)))
        // The tick only left a point behind.
        XCTAssertEqual(realPoints(engine), 3)
        let edges = engine.mesh.edgeCount
        eraser(engine)
        tap(engine, Vec2(500, 500))
        XCTAssertEqual(realPoints(engine), 2)
        XCTAssertEqual(engine.mesh.edgeCount, edges)
        engine.undo()
        XCTAssertEqual(realPoints(engine), 3)
    }

    func testErasingACrossingTakesTheLinesThatMeetThere() {
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

    func testErasingPartOfACurveLeavesTheRest() {
        let engine = pencil()
        Fixtures.drawPath(engine, Fixtures.circle(center: Vec2(500, 500), radius: 100, steps: 48, closes: false))
        let before = engine.mesh.edgeCount
        eraser(engine, radius: 10)
        tap(engine, Vec2(500, 600))
        XCTAssertLessThan(engine.mesh.edgeCount, before)
        XCTAssertGreaterThan(engine.mesh.edgeCount, before / 2)
    }

    func testRubbingInsideAFaceOpensItAndKeepsItsLines() {
        let engine = pencil()
        drawBoxOfLines(engine)
        let edges = engine.mesh.edgeCount
        eraser(engine, radius: 20)
        tap(engine, Vec2(450, 500))
        XCTAssertEqual(engine.mesh.faceCount, 1)
        XCTAssertEqual(engine.mesh.edgeCount, edges)
    }

    func testARubThatStartsOnAPointDoesNotTakeTheLineWithIt() {
        let engine = pencil()
        Fixtures.drawPath(engine, straight(Vec2(400, 500), Vec2(600, 500)))
        Fixtures.drawPath(engine, straight(Vec2(500, 480), Vec2(500, 520)))
        let edges = engine.mesh.edgeCount
        eraser(engine)
        Fixtures.drawPath(engine, [Vec2(500, 500), Vec2(503, 501), Vec2(499, 499), Vec2(501, 500)])
        XCTAssertEqual(engine.mesh.edgeCount, edges)
    }

    func testTheEraserWorksOnBothSidesOfTheMirror() {
        let engine = pencil()
        engine.setSymmetryEnabled(true)
        Fixtures.drawPath(engine, straight(Vec2(350, 500), Vec2(450, 500)))
        Fixtures.drawPath(engine, straight(Vec2(400, 480), Vec2(400, 520)))
        XCTAssertEqual(realPoints(engine), 6)
        eraser(engine)
        tap(engine, Vec2(400, 500))
        XCTAssertEqual(realPoints(engine), 4)
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
