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
}
