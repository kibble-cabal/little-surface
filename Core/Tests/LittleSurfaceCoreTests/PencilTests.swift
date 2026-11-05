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
        let points = (0...48).map { i -> Vec2 in
            let a = Float(i) / 48 * 2 * .pi
            return center + Vec2(cos(a), sin(a)) * radius
        }
        engine.pencilBegan(at: points[0])
        for p in points.dropFirst() { engine.pencilMoved(to: p) }
        engine.pencilEnded(at: points[points.count - 1])
    }

    private func screenLength(_ engine: RetopoEngine, _ e: EdgeID) -> Float {
        let (a, b) = engine.mesh.ends(e)
        let pa = engine.mesh.position(a), pb = engine.mesh.position(b)
        return simd_length(pa - pb) / engine.camera.worldPerPoint(at: (pa + pb) / 2)
    }

    private func meanScreenLength(_ engine: RetopoEngine) -> Float {
        let edges = engine.mesh.aliveEdges
        return edges.reduce(0) { $0 + screenLength(engine, $1) } / Float(edges.count)
    }

    func testAQuadIsTheSameSizeOnScreenAtAnyZoom() {
        let far = pencil()
        Fixtures.draw(far, from: Vec2(420, 400), to: Vec2(580, 400))
        XCTAssertEqual(meanScreenLength(far), RetopoEngine.quadSizePoints, accuracy: 5)

        let near = pencil()
        near.camera.distance *= 0.6
        Fixtures.draw(near, from: Vec2(420, 400), to: Vec2(580, 400))
        XCTAssertEqual(meanScreenLength(near), RetopoEngine.quadSizePoints, accuracy: 5)
        XCTAssertLessThan(near.mesh.edgeLength(near.mesh.aliveEdges[0]), far.mesh.edgeLength(far.mesh.aliveEdges[0]), "closer means finer")
    }

    func testALineThatMeetsTopologyMatchesItsSize() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(420, 400), to: Vec2(580, 400))
        let first = engine.mesh.averageEdgeLength
        engine.camera.distance *= 0.6
        guard let end = engine.camera.project(engine.mesh.position(engine.mesh.aliveVertices[0]))?.screen else { return XCTFail("off screen") }
        Fixtures.draw(engine, from: end, to: end + Vec2(0, 120))
        XCTAssertEqual(engine.mesh.averageEdgeLength, first, accuracy: first * 0.25)
    }

    func testEndsThatMeetCloseIntoALoopWithAnEvenCount() {
        let engine = pencil()
        drawLoop(engine, center: Vec2(500, 400), radius: 80)
        XCTAssertEqual(engine.mesh.vertexCount, engine.mesh.edgeCount, "a closed loop")
        XCTAssertTrue(engine.mesh.edgeCount.isMultiple(of: 2))
    }

    func testAStrokeAcrossTwoLinesConnectsThem() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(420, 360), to: Vec2(580, 360))
        Fixtures.draw(engine, from: Vec2(420, 460), to: Vec2(580, 460))
        let before = engine.mesh.vertexCount
        Fixtures.draw(engine, from: Vec2(500, 330), to: Vec2(500, 490))
        let branches = engine.mesh.aliveVertices.filter { engine.mesh.edgesOf($0).count >= 3 }
        XCTAssertGreaterThanOrEqual(branches.count, 2, "joined at both lines")
        XCTAssertGreaterThan(engine.mesh.vertexCount, before)
    }

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

    // MARK: Nothing is refused

    func testAMarkOverFinishedQuadsStaysAsAPencilLine() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(420, 360), to: Vec2(580, 360))
        Fixtures.draw(engine, from: Vec2(420, 460), to: Vec2(580, 460))
        let chains = NeighborChains.openChains(in: engine.mesh)
        XCTAssertEqual(chains.count, 2)
        _ = engine.perform("Fill") { mesh, _ in
            let plan = try QuadPatchBuilder.plan(chains: chains, parameters: QuadPatchParameters(), mesh: mesh, projector: engine.projector).plan
            _ = try PlanApplier.apply(plan, to: &mesh, symmetry: engine.symmetry, projector: engine.projector)
        }
        let faces = engine.mesh.faceCount
        XCTAssertGreaterThan(faces, 0)
        Fixtures.draw(engine, from: Vec2(450, 400), to: Vec2(550, 420))
        XCTAssertEqual(engine.sketches.count, 1)
        XCTAssertEqual(engine.sketches[0].colorIndex, SketchPalette.graphite)
        XCTAssertEqual(engine.mesh.faceCount, faces)
        XCTAssertNil(engine.message, "and nothing was said about it")
    }

    func testTappingAMarkPicksItAndDeletingTakesItOutAndUndoes() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(420, 360), to: Vec2(580, 360))
        Fixtures.draw(engine, from: Vec2(420, 460), to: Vec2(580, 460))
        let chains = NeighborChains.openChains(in: engine.mesh)
        _ = engine.perform("Fill") { mesh, _ in
            let plan = try QuadPatchBuilder.plan(chains: chains, parameters: QuadPatchParameters(), mesh: mesh, projector: engine.projector).plan
            _ = try PlanApplier.apply(plan, to: &mesh, symmetry: engine.symmetry, projector: engine.projector)
        }
        Fixtures.draw(engine, from: Vec2(450, 400), to: Vec2(550, 400))
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

    func testDeletingAPickedLineRemovesIt() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(420, 400), to: Vec2(580, 400))
        engine.pencilBegan(at: Vec2(500, 400))
        engine.pencilEnded(at: Vec2(500, 400))
        engine.deletePick()
        XCTAssertEqual(engine.mesh.edgeCount, 0)
    }

    // MARK: Fills

    func testTwoLinesPencilInQuadsThatFirmUpOnMovingOn() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(420, 360), to: Vec2(580, 360))
        XCTAssertTrue(engine.pencilledFills.isEmpty)
        Fixtures.draw(engine, from: Vec2(420, 460), to: Vec2(580, 460))
        XCTAssertEqual(engine.pencilledFills.count, 1, "appeared with no button")
        XCTAssertEqual(engine.mesh.faceCount, 0, "still pencilled")
        XCTAssertFalse(engine.overlay.previewTriangles.isEmpty, "and showing")

        Fixtures.draw(engine, from: Vec2(420, 620), to: Vec2(580, 620))
        XCTAssertGreaterThan(engine.mesh.faceCount, 0, "moving on firmed it up")
        XCTAssertTrue(engine.mesh.aliveFaces.allSatisfy { engine.mesh.loop($0).count == 4 })
    }

    func testUndoTakesThePencilledQuadsAndLeavesTheLine() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(420, 360), to: Vec2(580, 360))
        Fixtures.draw(engine, from: Vec2(420, 460), to: Vec2(580, 460))
        let edges = engine.mesh.edgeCount
        engine.undo()
        XCTAssertTrue(engine.pencilledFills.isEmpty)
        XCTAssertEqual(engine.mesh.edgeCount, edges)
        engine.undo()
        XCTAssertLessThan(engine.mesh.edgeCount, edges)
    }

    func testBesideALineAStrokeTakesItsCount() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(420, 360), to: Vec2(580, 360))
        let first = engine.mesh.edgeCount
        Fixtures.draw(engine, from: Vec2(410, 460), to: Vec2(600, 460))
        XCTAssertEqual(engine.mesh.edgeCount, first * 2, "both lines have the same count")
    }

    func testDrawingThroughABandMakesABandOnEachSide() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(400, 340), to: Vec2(600, 340))
        Fixtures.draw(engine, from: Vec2(400, 460), to: Vec2(600, 460))
        XCTAssertEqual(engine.pencilledFills.count, 1)
        XCTAssertEqual(engine.mesh.faceCount, 0)
        Fixtures.draw(engine, from: Vec2(400, 400), to: Vec2(600, 400))
        XCTAssertEqual(engine.pencilledFills.count, 2, "reflowed")
        XCTAssertEqual(engine.mesh.faceCount, 0, "and it's all still pencilled")
        engine.firmUpFills()
        XCTAssertGreaterThan(engine.mesh.faceCount, 0)
        XCTAssertTrue(engine.mesh.aliveFaces.allSatisfy { engine.mesh.loop($0).count == 4 })
    }

    func testALoopFillsAndALoopInsideItBecomesARing() {
        let engine = pencil()
        drawLoop(engine, center: Vec2(500, 400), radius: 120)
        XCTAssertEqual(engine.pencilledFills.count, 1, "the enclosed area fills in")
        XCTAssertEqual(engine.pencilledFills[0].chains.count, 1)

        drawLoop(engine, center: Vec2(500, 400), radius: 60)
        XCTAssertEqual(engine.pencilledFills.count, 1)
        XCTAssertEqual(engine.pencilledFills[0].preview.kind, .ring)
        XCTAssertEqual(engine.mesh.faceCount, 0, "the first fill never firmed up")
    }

    func testALoopAroundAPencilledLoopMakesARingInstead() {
        let engine = pencil()
        drawLoop(engine, center: Vec2(500, 400), radius: 60)
        drawLoop(engine, center: Vec2(500, 400), radius: 120)
        XCTAssertEqual(engine.pencilledFills.count, 1)
        XCTAssertEqual(engine.pencilledFills[0].preview.kind, .ring)
        XCTAssertEqual(engine.mesh.faceCount, 0)
    }

    func testFourLinesFenceInAnAreaEvenWithoutCorners() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(400, 320), to: Vec2(600, 320))
        Fixtures.draw(engine, from: Vec2(400, 480), to: Vec2(600, 480))
        engine.undo()
        XCTAssertTrue(engine.pencilledFills.isEmpty)
        Fixtures.draw(engine, from: Vec2(440, 300), to: Vec2(440, 500))
        Fixtures.draw(engine, from: Vec2(560, 300), to: Vec2(560, 500))
        XCTAssertFalse(engine.pencilledFills.isEmpty, "the middle is fenced in")
        engine.firmUpFills()
        XCTAssertGreaterThan(engine.mesh.faceCount, 0)
    }

    func testALoopAroundTheWholeModelEnclosesNothing() {
        let sphere = Fixtures.sphere()
        var mesh = Mesh()
        let count = 24
        let vertices = (0..<count).map { i -> VertexID in
            let a = Float(i) / Float(count) * 2 * .pi
            return mesh.addVertex(Vec3(cos(a), 0, sin(a)))
        }
        var edges: [EdgeID] = []
        for i in 0..<count { edges.append(try! mesh.ensureEdge(vertices[i], vertices[(i + 1) % count])) }
        XCTAssertTrue(EnclosedRegions.regions(bordering: edges, in: mesh, projector: Fixtures.projector(sphere)).isEmpty)
    }

    func testTappingTheHoleInARingOffersToFillItButNotTheOutside() {
        let engine = pencil()
        drawLoop(engine, center: Vec2(500, 400), radius: 120)
        drawLoop(engine, center: Vec2(500, 400), radius: 60)
        engine.firmUpFills()
        let faces = engine.mesh.faceCount
        XCTAssertGreaterThan(faces, 0)

        Fixtures.draw(engine, from: Vec2(620, 400), to: Vec2(620.5, 400))
        XCTAssertTrue(engine.hasPick)
        XCTAssertNil(engine.pickedLoop, "the outside of the ring isn't an area to fill")

        Fixtures.draw(engine, from: Vec2(560, 400), to: Vec2(560.5, 400))
        XCTAssertNotNil(engine.pickedLoop)
        engine.fillPick()
        XCTAssertGreaterThan(engine.mesh.faceCount, faces)
        XCTAssertFalse(engine.hasPick)
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

    // MARK: The eraser

    func testTheEraserTakesOutQuadsLinesAndMarksInOneUndo() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(420, 360), to: Vec2(580, 360))
        Fixtures.draw(engine, from: Vec2(420, 460), to: Vec2(580, 460))
        engine.firmUpFills()
        Fixtures.draw(engine, from: Vec2(300, 620), to: Vec2(700, 620), bend: Vec2(0, -300))
        let faces = engine.mesh.faceCount, edges = engine.mesh.edgeCount, marks = engine.sketches.count
        XCTAssertGreaterThan(faces, 0)

        engine.setTool(.erase)
        engine.setSelectionMode(.face)
        Fixtures.draw(engine, from: Vec2(500, 340), to: Vec2(500, 640))
        XCTAssertLessThan(engine.mesh.faceCount, faces)
        XCTAssertLessThan(engine.mesh.edgeCount, edges)

        engine.undo()
        XCTAssertEqual(engine.mesh.faceCount, faces)
        XCTAssertEqual(engine.mesh.edgeCount, edges)
        XCTAssertEqual(engine.sketches.count, marks)
    }

    func testTheEraserRubsOutAPencilMark() {
        let engine = pencil()
        Fixtures.draw(engine, from: Vec2(420, 360), to: Vec2(580, 360))
        Fixtures.draw(engine, from: Vec2(420, 460), to: Vec2(580, 460))
        engine.firmUpFills()
        Fixtures.draw(engine, from: Vec2(440, 410), to: Vec2(560, 410))
        XCTAssertEqual(engine.sketches.count, 1, "a stroke along the quads stays as a mark")

        engine.setTool(.erase)
        engine.setSelectionMode(.face)
        Fixtures.draw(engine, from: Vec2(500, 400), to: Vec2(500, 420))
        XCTAssertTrue(engine.sketches.isEmpty)
    }
}
