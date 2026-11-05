import XCTest
import simd
@testable import LittleSurfaceCore

/// Drawing with mirror on: each side stays its own, and they meet exactly on the middle.
final class MirrorDrawingTests: XCTestCase {
    private func mirrored() -> RetopoEngine {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.pencil)
        engine.setSymmetryEnabled(true)
        return engine
    }

    private func straight(_ a: Vec2, _ b: Vec2, steps: Int = 24) -> [Vec2] {
        (0...steps).map { simd_mix(a, b, Vec2(repeating: Float($0) / Float(steps))) }
    }

    /// The middle of the screen is the middle of the sphere, which is where the plane is.
    private func assertPairedExactly(_ mesh: Mesh, file: StaticString = #filePath, line: UInt = #line) {
        let plane = MirrorPlane(axis: .x, offset: 0)
        for v in mesh.aliveVertices {
            let partner = mesh.mirrorPartner[Int(v)]
            XCTAssertGreaterThanOrEqual(partner, 0, "A point with no mirror image", file: file, line: line)
            guard partner >= 0 else { continue }
            let target = plane.reflect(mesh.position(v))
            XCTAssertLessThan(simd_length(target - mesh.position(VertexID(partner))), 0.005, file: file, line: line)
        }
    }

    private func pointsOnTheMiddle(_ mesh: Mesh) -> Int {
        mesh.aliveVertices.filter { mesh.mirrorPartner[Int($0)] == $0 }.count
    }

    func testALineStopsAtTheMiddle() {
        let engine = mirrored()
        Fixtures.drawPath(engine, straight(Vec2(380, 500), Vec2(620, 500)))
        let mesh = engine.mesh
        XCTAssertEqual(pointsOnTheMiddle(mesh), 1)
        assertPairedExactly(mesh)
        // The two halves meet in one line, whichever side it was drawn from.
        XCTAssertEqual(mesh.aliveVertices.filter { mesh.edgesOf($0).count == 1 }.count, 2)
        XCTAssertLessThan(mesh.aliveVertices.map { abs(mesh.position($0).x) }.max() ?? 0, 0.55)
    }

    func testAnEndCloseToTheMiddleReachesIt() {
        let engine = mirrored()
        Fixtures.drawPath(engine, straight(Vec2(380, 500), Vec2(490, 500)))
        XCTAssertEqual(pointsOnTheMiddle(engine.mesh), 1)
        assertPairedExactly(engine.mesh)
    }

    func testAStartCloseToTheMiddleReachesIt() {
        let engine = mirrored()
        Fixtures.drawPath(engine, straight(Vec2(490, 500), Vec2(380, 500)))
        XCTAssertEqual(pointsOnTheMiddle(engine.mesh), 1)
        assertPairedExactly(engine.mesh)
    }

    func testAStartJustOverTheMiddleDoesNotStopTheLine() {
        let engine = mirrored()
        Fixtures.drawPath(engine, straight(Vec2(505, 500), Vec2(380, 500)))
        XCTAssertLessThan(engine.mesh.aliveVertices.map(\.self).map { engine.mesh.position($0).x }.min() ?? 0, -0.3)
        XCTAssertEqual(pointsOnTheMiddle(engine.mesh), 1)
        assertPairedExactly(engine.mesh)
    }

    func testALineFarFromTheMiddleStaysAsDrawn() {
        let engine = mirrored()
        Fixtures.drawPath(engine, straight(Vec2(400, 400), Vec2(400, 600)))
        XCTAssertEqual(pointsOnTheMiddle(engine.mesh), 0)
        assertPairedExactly(engine.mesh)
    }

    func testACrossingCloseToTheMiddleIsOnePoint() {
        let engine = mirrored()
        // A line from the side to the middle, then one from above that crosses it just off the middle.
        Fixtures.drawPath(engine, straight(Vec2(380, 500), Vec2(500, 500)))
        let before = pointsOnTheMiddle(engine.mesh)
        Fixtures.drawPath(engine, straight(Vec2(492, 420), Vec2(492, 580)))
        XCTAssertEqual(engine.mesh.aliveVertices.filter { engine.mesh.position($0).y.magnitude < 0.02 && abs(engine.mesh.position($0).x) < 0.1 && !engine.mesh.isBendVertex($0) }.count, 1)
        XCTAssertGreaterThanOrEqual(pointsOnTheMiddle(engine.mesh), before)
        assertPairedExactly(engine.mesh)
        assertValid(engine.mesh)
    }

    func testASquareToTheMiddleMakesTwoMatchingQuads() {
        let engine = mirrored()
        for y: Float in [420, 580] { Fixtures.drawPath(engine, straight(Vec2(400, y), Vec2(500, y))) }
        Fixtures.drawPath(engine, straight(Vec2(400, 410), Vec2(400, 590)))
        XCTAssertEqual(engine.statistics.quads, 0, "Open at the middle, with nothing to close it yet")
        Fixtures.drawPath(engine, straight(Vec2(500, 420), Vec2(500, 580)))
        XCTAssertEqual(engine.statistics.quads, 2)
        assertPairedExactly(engine.mesh)
    }

    func testLopsidedFacesDoNotStraightenOneSide() {
        var mesh = Mesh()
        // Two curved faces mirrored across x, one with a real corner too many.
        func face(_ side: Float, extraCorner: Bool) throws -> [VertexID] {
            let points = [Vec3(side, 0, 0), Vec3(side * 1.5, -0.1, 0), Vec3(side * 2, 0, 0), Vec3(side * 2, 1, 0), Vec3(side, 1, 0)]
            let ids = points.map { mesh.addVertex($0) }
            try mesh.addFace(ids, autoOrient: false)
            mesh.setBend(ids[1], true)
            if extraCorner {
                let e = try XCTUnwrap(mesh.edge(between: ids[2], ids[3]))
                _ = try mesh.splitEdge(e, at: 0.5, position: Vec3(side * 2, 0.5, 0))
            }
            return ids
        }
        let right = try! face(1, extraCorner: false)
        let left = try! face(-1, extraCorner: true)
        mesh.setMirrorPartner(right[1], left[1])
        mesh.setMirrorPartner(left[1], right[1])
        mesh.straightenQuads(mirrored: true)
        XCTAssertTrue(mesh.isVertexAlive(right[1]))
        XCTAssertTrue(mesh.isVertexAlive(left[1]))
        mesh.straightenQuads(mirrored: false)
        XCTAssertFalse(mesh.isVertexAlive(right[1]))
    }
}
