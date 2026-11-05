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

    /// Straight along x for 100 points, then on at an angle for another 100.
    private func bend(degrees: Float, from start: Vec2, step: Float) -> [Vec2] {
        let radians = degrees * Float.pi / 180
        let way = Vec2(cos(radians), sin(radians))
        let count = Int(100 / step)
        var path: [Vec2] = []
        for i in 0...count { path.append(start + Vec2(Float(i) * step, 0)) }
        let corner = start + Vec2(100, 0)
        for i in 1...count { path.append(corner + way * (Float(i) * step)) }
        return path
    }

    func testAGentleBendDoesNotStopTheLine() {
        // However fast the hand: a quick one leaves wide gaps between samples.
        let cases: [(degrees: Float, step: Float)] = [(15, 2), (30, 2), (40, 2), (30, 25), (40, 25), (35, 50)]
        for (degrees, step) in cases {
            let raw = bend(degrees: degrees, from: Vec2(0, 0), step: step)
            let lift = raw[raw.count - 1]
            var steady = StrokeStabilizer(start: raw[0], strength: 1)
            var line: [Vec2] = []
            for point in raw.dropFirst() { line += steady.pull(to: point) }
            XCTAssertLessThan(simd_length(steady.end(at: lift) - lift), 2, "\(degrees)° at \(step)")
            let reached: Vec2 = line.last ?? raw[0]
            XCTAssertLessThan(simd_length(reached - lift), 34, "\(degrees)° at \(step)")
        }
    }

    func testAGentleBendOnTheModelReachesItsEnd() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.pencil)
        engine.steadiness = 1
        let path = bend(degrees: 35, from: Vec2(400, 500), step: 25)
        let lift = path[path.count - 1]
        Fixtures.drawPath(engine, path)
        let mesh = engine.mesh
        var nearest = Float.infinity
        for v in mesh.aliveVertices {
            guard let there = engine.camera.project(mesh.position(v))?.screen else { continue }
            nearest = min(nearest, simd_length(there - lift))
        }
        XCTAssertLessThan(nearest, 4)
    }
}
