import XCTest
import simd
@testable import LittleSurfaceCore

final class StrokeStabilizerTests: XCTestCase {
    /// A tremble on a straight line, from a repeatable sequence.
    private func trembling(amount: Float) -> [Vec2] {
        (0...200).map { i in
            let wobble = sin(Float(i) * 1.7) * 0.6 + sin(Float(i) * 3.1) * 0.4
            return Vec2(100 + Float(i), 300 + wobble * amount)
        }
    }

    private func wander(_ points: [Vec2]) -> Float {
        zip(points, points.dropFirst()).reduce(0) { $0 + abs($1.1.y - $1.0.y) }
    }

    func testATrembleDoesNotReachTheLine() {
        let raw = trembling(amount: 3)
        var steady = StrokeStabilizer(start: raw[0], strength: 0.4)
        let line = raw.dropFirst().flatMap { steady.pull(to: $0) }
        XCTAssertLessThan(wander(line), wander(raw) * 0.2)
    }

    func testNoStrengthFollowsThePencil() {
        var steady = StrokeStabilizer(start: Vec2(0, 0), strength: 0)
        XCTAssertEqual(steady.pull(to: Vec2(3, 4)), [Vec2(3, 4)])
        XCTAssertEqual(steady.end(at: Vec2(9, 9)), Vec2(9, 9))
    }

    func testTheLineReachesWhereThePencilLifts() {
        var steady = StrokeStabilizer(start: Vec2(0, 0), strength: 0.5)
        for x in stride(from: Float(10), through: 100, by: 10) { _ = steady.pull(to: Vec2(x, 0)) }
        XCTAssertEqual(steady.end(at: Vec2(100, 0)).x, 100, accuracy: 0.01)
    }

    func testAFlickOnLiftingDoesNotTurnTheLine() {
        var steady = StrokeStabilizer(start: Vec2(0, 0), strength: 0.5)
        for x in stride(from: Float(10), through: 100, by: 10) { _ = steady.pull(to: Vec2(x, 0)) }
        XCTAssertEqual(steady.end(at: Vec2(100, 7)).y, 0, accuracy: 0.01)
    }

    func testACornerStillReadsAsACorner() {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.pencil)
        engine.steadiness = 1
        let path = (0...50).map { Vec2(400 + Float($0) * 2, 500) } + (1...50).map { Vec2(500, 500 + Float($0) * 2) }
        Fixtures.drawPath(engine, path)
        XCTAssertEqual(engine.mesh.vertexCount - engine.mesh.bendCount, 3)
    }

    func testAShakyLineHasOnlyItsEnds() {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.pencil)
        Fixtures.drawPath(engine, trembling(amount: 6).map { $0 + Vec2(300, 200) })
        XCTAssertEqual(engine.mesh.vertexCount - engine.mesh.bendCount, 2)
    }
}
