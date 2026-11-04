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
}
