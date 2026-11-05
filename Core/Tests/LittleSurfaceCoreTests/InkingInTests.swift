import simd
import XCTest
@testable import LittleSurfaceCore

final class InkingInTests: XCTestCase {
    private func engine() -> RetopoEngine {
        let engine = Fixtures.engine(with: Fixtures.plane(size: 8), camera: Fixtures.frontCamera())
        engine.setTool(.pencil)
        return engine
    }

    private func draw(_ engine: RetopoEngine, _ corners: [Vec2], bow: Float = 0) {
        var path: [Vec2] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            let across = simd_normalize(Vec2(b.y - a.y, a.x - b.x))
            let steps = max(Int(simd_length(b - a) / 6), 1)
            for i in 0..<steps {
                let t = Float(i) / Float(steps)
                path.append(simd_mix(a, b, Vec2(repeating: t)) + across * sin(t * .pi) * bow)
            }
        }
        path.append(corners[corners.count - 1])
        engine.pencilBegan(at: path[0])
        for p in path.dropFirst() { engine.pencilMoved(to: p) }
        engine.pencilEnded(at: path[path.count - 1])
    }

    private let a = Vec2(400, 400), b = Vec2(600, 400), c = Vec2(600, 600), d = Vec2(400, 600)

    /// Three sides drawn on their own stay pencil, then the fourth closes them into a quad.
    private func quad(_ engine: RetopoEngine, bow: Float = 0) {
        draw(engine, [a, b], bow: bow)
        draw(engine, [b, c], bow: bow)
        draw(engine, [c, d], bow: bow)
        XCTAssertEqual(engine.statistics.quads, 0)
        draw(engine, [d, a], bow: bow)
        XCTAssertEqual(engine.statistics.quads, 1)
    }

    func testAllFourSidesOfANewQuadInkInWithTheCurvesTheyWereDrawnWith() throws {
        let engine = engine()
        quad(engine, bow: 8)
        let inking = engine.inkingIn
        XCTAssertEqual(inking.sides.count, 4)
        XCTAssertEqual(inking.topologyVersion, engine.mesh.topologyVersion)
        for side in inking.sides {
            XCTAssertGreaterThan(side.curve.count, 2)
            XCTAssertEqual(side.curve.count, side.straight.count)
            let (p, q) = engine.mesh.ends(side.edge)
            let ends = [engine.mesh.position(p), engine.mesh.position(q)]
            // Both start and finish where the real side's ends are.
            for end in [side.curve[0], side.curve[side.curve.count - 1], side.straight[0], side.straight[side.straight.count - 1]] {
                XCTAssertLessThan(ends.map { simd_length($0 - end) }.min()!, 1e-4)
            }
            XCTAssertLessThan(simd_length(side.curve[0] - side.straight[0]), 1e-4)
            let chord = simd_normalize(ends[1] - ends[0])
            let off = side.straight.map { simd_length(simd_cross($0 - ends[0], chord)) }.max()!
            XCTAssertLessThan(off, 1e-4, "The straight points lie on the side")
            let bowed = side.curve.map { simd_length(simd_cross($0 - ends[0], chord)) }.max()!
            XCTAssertGreaterThan(bowed, 0.01, "The curve is the one that was drawn")
        }
    }

    func testAStrokeThatMakesNoQuadInksNothing() {
        let engine = engine()
        draw(engine, [a, b], bow: 8)
        XCTAssertTrue(engine.inkingIn.sides.isEmpty)
    }

    func testCuttingAQuadInksOnlyTheCut() throws {
        let engine = engine()
        quad(engine)
        draw(engine, [Vec2(500, 380), Vec2(500, 620)], bow: 8)
        XCTAssertEqual(engine.statistics.quads, 2)
        XCTAssertEqual(engine.inkingIn.sides.count, 1, "The two halves of each split side were ink already")
        XCTAssertGreaterThan(engine.inkingIn.sides[0].curve.count, 2)
    }

    func testUndoLeavesItOutOfDate() {
        let engine = engine()
        quad(engine, bow: 8)
        XCTAssertEqual(engine.inkingIn.topologyVersion, engine.mesh.topologyVersion)
        engine.undo()
        XCTAssertNotEqual(engine.inkingIn.topologyVersion, engine.mesh.topologyVersion)
    }
}
