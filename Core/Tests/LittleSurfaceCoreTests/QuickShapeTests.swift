import XCTest
import simd
@testable import LittleSurfaceCore

final class QuickShapeTests: XCTestCase {
    /// A little hand wobble, the same each run.
    private func wobbled(_ points: [Vec2], by amount: Float = 2) -> [Vec2] {
        points.enumerated().map { i, p in
            p + Vec2(sin(Float(i) * 0.7), cos(Float(i) * 1.1)) * amount
        }
    }

    private func through(_ corners: [Vec2], step: Float = 5) -> [Vec2] {
        var out: [Vec2] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            let steps = max(Int(simd_length(b - a) / step), 1)
            for i in 0..<steps { out.append(simd_mix(a, b, Vec2(repeating: Float(i) / Float(steps)))) }
        }
        out.append(corners[corners.count - 1])
        return out
    }

    private func oval(rx: Float, ry: Float, turns: Float = 1) -> [Vec2] {
        (0...80).map { i in
            let t = Float(i) / 80 * 2 * .pi * turns - .pi / 2
            return Vec2(500 + cos(t) * rx, 500 + sin(t) * ry)
        }
    }

    func testAWobblyLineGoesStraightBetweenItsEnds() throws {
        let stroke = wobbled(through([Vec2(100, 100), Vec2(400, 220)]))
        let shape = try XCTUnwrap(QuickShape.recognize(stroke))
        XCTAssertEqual(shape.kind, .line)
        XCTAssertEqual(simd_length(shape.points[0] - stroke[0]), 0, accuracy: 0.01)
        XCTAssertEqual(simd_length(shape.points[shape.points.count - 1] - stroke[stroke.count - 1]), 0, accuracy: 0.01)
        XCTAssertFalse(shape.isClosed)
    }

    func testACircle() throws {
        let shape = try XCTUnwrap(QuickShape.recognize(wobbled(oval(rx: 120, ry: 118))))
        XCTAssertEqual(shape.kind, .circle)
        XCTAssertTrue(shape.isClosed)
        XCTAssertTrue(shape.corners.isEmpty)
        for p in shape.points { XCTAssertEqual(simd_length(p - Vec2(500, 500)), 119, accuracy: 6) }
    }

    func testAnEllipse() throws {
        let shape = try XCTUnwrap(QuickShape.recognize(wobbled(oval(rx: 180, ry: 90))))
        XCTAssertEqual(shape.kind, .ellipse)
    }

    func testAnOverrunCircleStillCloses() throws {
        let shape = try XCTUnwrap(QuickShape.recognize(wobbled(oval(rx: 120, ry: 120, turns: 1.1))))
        XCTAssertEqual(shape.kind, .circle)
    }

    func testARectangleComesOutSquare() throws {
        let corners = [Vec2(300, 300), Vec2(520, 310), Vec2(512, 450), Vec2(295, 440), Vec2(300, 300)]
        let shape = try XCTUnwrap(QuickShape.recognize(wobbled(through(corners))))
        XCTAssertEqual(shape.kind, .rectangle)
        XCTAssertEqual(shape.corners.count, 4)
        for i in 0..<4 {
            let a = shape.corners[i], b = shape.corners[(i + 1) % 4], c = shape.corners[(i + 2) % 4]
            XCTAssertEqual(simd_dot(simd_normalize(a - b), simd_normalize(c - b)), 0, accuracy: 0.001)
        }
        XCTAssertLessThan(simd_length(shape.corners[0] - corners[0]), 15, "it starts from the corner the stroke did")
    }

    func testASlantedFourSidedShapeKeepsItsCorners() throws {
        let corners = [Vec2(300, 300), Vec2(600, 300), Vec2(450, 500), Vec2(250, 500), Vec2(300, 300)]
        let shape = try XCTUnwrap(QuickShape.recognize(wobbled(through(corners))))
        XCTAssertEqual(shape.kind, .polygon)
        XCTAssertEqual(shape.corners.count, 4)
        for (got, wanted) in zip(shape.corners, corners) { XCTAssertLessThan(simd_length(got - wanted), 12) }
    }

    func testATriangle() throws {
        let corners = [Vec2(400, 200), Vec2(600, 500), Vec2(200, 500), Vec2(400, 200)]
        let shape = try XCTUnwrap(QuickShape.recognize(wobbled(through(corners))))
        XCTAssertEqual(shape.kind, .triangle)
        XCTAssertEqual(shape.corners.count, 3)
    }

    func testAnArc() throws {
        let stroke = wobbled((0...50).map { i in
            let t = Float(i) / 50 * .pi
            return Vec2(500 + cos(t) * 150, 500 - sin(t) * 150)
        }, by: 1.5)
        let shape = try XCTUnwrap(QuickShape.recognize(stroke))
        XCTAssertEqual(shape.kind, .arc)
        XCTAssertFalse(shape.isClosed)
        XCTAssertLessThan(simd_length(shape.points[shape.points.count - 1] - stroke[stroke.count - 1]), 8)
        for p in shape.points { XCTAssertEqual(simd_length(p - Vec2(500, 500)), 150, accuracy: 6) }
    }

    func testABentLineKeepsItsCorner() throws {
        let corners = [Vec2(200, 200), Vec2(500, 200), Vec2(500, 500)]
        let shape = try XCTUnwrap(QuickShape.recognize(wobbled(through(corners))))
        XCTAssertEqual(shape.kind, .corners)
        XCTAssertEqual(shape.corners.count, 1)
        XCTAssertLessThan(simd_length(shape.corners[0] - corners[1]), 12)
    }

    func testAShortStrokeAndAScribbleAreLeftAlone() {
        XCTAssertNil(QuickShape.recognize([Vec2(100, 100), Vec2(105, 102), Vec2(110, 100)]))
        let scribble = (0..<120).map { i -> Vec2 in
            let t = Float(i)
            return Vec2(300 + t * 3 + sin(t * 1.9) * 40, 300 + cos(t * 2.7) * 60)
        }
        XCTAssertNil(QuickShape.recognize(scribble))
    }

    func testDraggingResizesAndTurnsAroundThePivot() throws {
        let shape = try XCTUnwrap(QuickShape.recognize(through([Vec2(100, 100), Vec2(300, 100)])))
        let moved = shape.dragged(from: Vec2(300, 100), to: Vec2(100, 500))
        XCTAssertEqual(simd_length(moved.points[0] - Vec2(100, 100)), 0, accuracy: 0.01, "the start stays")
        XCTAssertEqual(simd_length(moved.points[moved.points.count - 1] - Vec2(100, 500)), 0, accuracy: 0.05, "the end follows")
    }
}

final class QuickShapeDrawingTests: XCTestCase {
    private func engine() -> RetopoEngine {
        let engine = Fixtures.engine(with: Fixtures.plane(size: 8), camera: Fixtures.frontCamera())
        engine.setTool(.pencil)
        return engine
    }

    private func wobbly(_ corners: [Vec2], step: Float = 6) -> [Vec2] {
        var out: [Vec2] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            let steps = max(Int(simd_length(b - a) / step), 1)
            for i in 0..<steps {
                let wobble = Vec2(sin(Float(out.count)), cos(Float(out.count) * 1.3)) * 1.5
                out.append(simd_mix(a, b, Vec2(repeating: Float(i) / Float(steps))) + wobble)
            }
        }
        out.append(corners[corners.count - 1])
        return out
    }

    /// Draws the stroke, rests, then moves on to any more points before lifting.
    private func drawAndRest(_ engine: RetopoEngine, _ path: [Vec2], thenTo more: [Vec2] = []) {
        engine.pencilBegan(at: path[0])
        for p in path.dropFirst() { engine.pencilMoved(to: p) }
        engine.pencilPaused(at: path[path.count - 1])
        for p in more { engine.pencilMoved(to: p) }
        engine.pencilEnded(at: more.last ?? path[path.count - 1])
    }

    private let box = [Vec2(400, 400), Vec2(600, 405), Vec2(595, 600), Vec2(402, 595), Vec2(400, 400)]

    func testARectangleIsAQuadStraightAway() {
        let engine = engine()
        drawAndRest(engine, wobbly(box))
        XCTAssertEqual(engine.statistics.quads, 1)
        XCTAssertEqual(engine.statistics.vertices, 4)
        XCTAssertEqual(engine.statistics.faces, 1)
    }

    func testRestingAgainDoesNothingAndItsOneUndo() {
        let engine = engine()
        let depth = engine.history.undoStack.count
        drawAndRest(engine, wobbly(box))
        XCTAssertEqual(engine.history.undoStack.count, depth + 1)
        engine.undo()
        XCTAssertEqual(engine.mesh.edgeCount, 0)
    }

    func testACircleIsASmoothLoopWithNoPoints() {
        let engine = engine()
        let circle = Fixtures.circle(center: Vec2(500, 500), radius: 120, steps: 60, closes: false)
        drawAndRest(engine, circle)
        XCTAssertEqual(engine.statistics.faces, 1)
        XCTAssertEqual(engine.statistics.vertices, 0)
    }

    func testALineIsStraightOnScreen() throws {
        let engine = engine()
        drawAndRest(engine, wobbly([Vec2(300, 500), Vec2(700, 520)]))
        let mesh = engine.mesh
        for v in mesh.aliveVertices {
            let there = try XCTUnwrap(engine.camera.project(mesh.position(v))).screen
            let t = (there.x - 300) / 400
            XCTAssertEqual(there.y, 500 + t * 20, accuracy: 2.5)
        }
    }

    func testMovingAfterItSnapsResizesIt() throws {
        let engine = engine()
        drawAndRest(engine, wobbly([Vec2(300, 500), Vec2(500, 500)]), thenTo: [Vec2(700, 500)])
        let mesh = engine.mesh
        let xs = try mesh.aliveVertices.map { try XCTUnwrap(engine.camera.project(mesh.position($0))).screen.x }
        XCTAssertEqual(xs.max()!, 700, accuracy: 3)
    }

    func testAPauseOnAScribbleLeavesTheStrokeAsDrawn() {
        let engine = engine()
        let scribble = (0..<120).map { i -> Vec2 in
            let t = Float(i)
            return Vec2(300 + t * 3 + sin(t * 1.9) * 40, 500 + cos(t * 2.7) * 60)
        }
        engine.pencilBegan(at: scribble[0])
        for p in scribble.dropFirst() { engine.pencilMoved(to: p) }
        let before = engine.inkPath
        engine.pencilPaused(at: scribble[scribble.count - 1])
        XCTAssertEqual(engine.inkPath, before)
        engine.pencilEnded(at: scribble[scribble.count - 1])
        XCTAssertGreaterThan(engine.mesh.edgeCount, 0)
    }

    func testCancellingAShapeMakesNothing() {
        let engine = engine()
        let path = wobbly(box)
        engine.pencilBegan(at: path[0])
        for p in path.dropFirst() { engine.pencilMoved(to: p) }
        engine.pencilPaused(at: path[path.count - 1])
        engine.pencilCancelled()
        XCTAssertEqual(engine.mesh.edgeCount, 0)
        XCTAssertTrue(engine.inkPath.isEmpty)
    }

    func testARectangleOnTheCurveKeepsItsCornersOnTheSurface() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.pencil)
        drawAndRest(engine, wobbly([Vec2(450, 450), Vec2(550, 452), Vec2(548, 550), Vec2(452, 548), Vec2(450, 450)]))
        XCTAssertEqual(engine.statistics.quads, 1)
    }

    func testAMirroredShapeShowsOnBothSidesWhileItsBeingDrawn() {
        let engine = engine()
        engine.setSymmetryEnabled(true)
        let right = [Vec2(600, 400), Vec2(760, 405), Vec2(755, 600), Vec2(602, 595), Vec2(600, 400)]
        let path = wobbly(right)
        engine.pencilBegan(at: path[0])
        for p in path.dropFirst() { engine.pencilMoved(to: p) }
        engine.pencilPaused(at: path[path.count - 1])
        XCTAssertFalse(engine.overlay.mirrorEdges.isEmpty)
        engine.pencilEnded(at: path[path.count - 1])
        XCTAssertEqual(engine.statistics.quads, 2)
    }
}
