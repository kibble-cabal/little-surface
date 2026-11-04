import XCTest
import simd
@testable import LittleSurfaceCore

final class StrokeTests: XCTestCase {
    private func capture(on projector: SurfaceProjector, camera: Camera, _ points: [Vec2]) -> StrokeCapture {
        var c = StrokeCapture(camera: camera, projector: projector)
        for p in points { c.add(screen: p) }
        return c
    }

    func testCaptureStaysOnSurfaceAndFillsFastStrokes() throws {
        let projector = Fixtures.projector(Fixtures.sphere())
        let camera = Fixtures.frontCamera()
        // A fast stroke: only three samples across the sphere.
        let c = capture(on: projector, camera: camera, [Vec2(380, 500), Vec2(500, 500), Vec2(620, 500)])
        XCTAssertEqual(c.runs.count, 1)
        XCTAssertGreaterThan(c.runs[0].count, 10, "gaps between samples are filled with real surface hits")
        for p in c.runs[0] { XCTAssertEqual(simd_length(p.position), 1, accuracy: 0.01) }
    }

    func testCaptureBreaksAtSilhouetteRatherThanBridging() throws {
        // Two spheres, one in front of the other: a stroke from one to the other jumps in depth.
        let near = Fixtures.sphere(radius: 0.4, center: Vec3(-0.4, 0, 1), rings: 24, segments: 32)
        let far = Fixtures.sphere(radius: 0.4, center: Vec3(0.4, 0, -1), rings: 24, segments: 32)
        let projector = SurfaceProjector(bvhs: [TriangleBVH(object: near)!, TriangleBVH(object: far)!])
        let camera = Fixtures.frontCamera()
        let a = try XCTUnwrap(camera.project(Vec3(-0.5, 0, 1.3))?.screen)
        let b = try XCTUnwrap(camera.project(Vec3(0.5, 0, -0.65))?.screen)
        let points = (0...20).map { simd_mix(a, b, Vec2(repeating: Float($0) / 20)) }
        let c = capture(on: projector, camera: camera, points)
        XCTAssertGreaterThanOrEqual(c.runs.count, 2)
        for run in c.usableRuns {
            for i in 1..<run.count {
                XCTAssertLessThan(simd_length(run[i].position - run[i - 1].position), 0.5, "no segment bridges the gap")
            }
        }
    }

    func testCaptureReportsMisses() throws {
        let projector = Fixtures.projector(Fixtures.sphere())
        let camera = Fixtures.frontCamera()
        let c = capture(on: projector, camera: camera, [Vec2(10, 10), Vec2(20, 10)])
        XCTAssertEqual(c.hitCount, 0)
        XCTAssertEqual(c.missCount, 2)
    }

    func testResamplingSpacingFollowsEdgeLength() throws {
        let projector = Fixtures.projector(Fixtures.sphere())
        let camera = Fixtures.frontCamera()
        let c = capture(on: projector, camera: camera, stride(from: 380, through: 620, by: 3).map { Vec2(Float($0), 500) })
        var settings = StrokeSettings()
        settings.edgeLength = 0.1
        let path = try XCTUnwrap(StrokeProcessor.process(run: c.runs[0], settings: settings, projector: projector, closeRadius: 0.05))
        for i in 1..<path.points.count {
            let d = simd_length(path.points[i].position - path.points[i - 1].position)
            XCTAssertEqual(d, 0.1, accuracy: 0.025)
        }
        for p in path.points { XCTAssertEqual(simd_length(p.position), 1, accuracy: 0.01, "resampled points return to the surface") }
    }

    func testSmoothingRemovesJitter() throws {
        let plane = Fixtures.plane()
        let projector = Fixtures.projector(plane)
        let camera = Fixtures.frontCamera()
        let jagged = stride(from: Float(300), through: 700, by: 4).enumerated().map { i, x in Vec2(x, 500 + (i % 2 == 0 ? 4 : -4)) }
        let c = capture(on: projector, camera: camera, jagged)
        func wobble(_ smoothing: Float) throws -> Float {
            var settings = StrokeSettings()
            settings.edgeLength = 0.05
            settings.smoothing = smoothing
            let path = try XCTUnwrap(StrokeProcessor.process(run: c.runs[0], settings: settings, projector: projector, closeRadius: 0))
            // The ends stay where the Pencil put them, so only the interior measures the smoothing.
            return path.points.dropFirst().dropLast().map { abs($0.position.y) }.max()!
        }
        XCTAssertLessThan(try wobble(1), try wobble(0) * 0.5)
    }

    func testNearEndsCloseTheLoop() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.drawPath(engine, Fixtures.circle(center: Vec2(500, 500), radius: 100))
        XCTAssertNil(engine.pendingStroke, "a loop needs no question")
        XCTAssertNotNil(engine.reopenablePlans)
        XCTAssertEqual(engine.mesh.vertexCount, engine.mesh.edgeCount, "a closed polyline has as many edges as vertices")
        for v in engine.mesh.aliveVertices { XCTAssertEqual(engine.mesh.edgesOf(v).count, 2) }
        assertValid(engine.mesh)
    }

    func testAClosedLoopCanBeKeptOpenInOneStep() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.drawPath(engine, Fixtures.circle(center: Vec2(500, 500), radius: 100))
        engine.keepLoopOpen()
        XCTAssertNil(engine.reopenablePlans)
        XCTAssertEqual(engine.mesh.edgeCount, engine.mesh.vertexCount - 1)
        assertValid(engine.mesh)
        engine.undo()
        XCTAssertEqual(engine.mesh.edgeCount, 0, "keeping it open replaces the loop rather than adding a step")
    }

    func testTheNextStrokeEndsTheChanceToKeepALoopOpen() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.drawPath(engine, Fixtures.circle(center: Vec2(500, 500), radius: 100))
        Fixtures.draw(engine, from: Vec2(350, 300), to: Vec2(650, 300))
        XCTAssertNil(engine.reopenablePlans)
    }

    func testWithAutoCloseOffTheStrokeAsks() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.closesLoopsAutomatically = false
        Fixtures.drawPath(engine, Fixtures.circle(center: Vec2(500, 500), radius: 100))
        let pending = try XCTUnwrap(engine.pendingStroke)
        XCTAssertTrue(pending.canClose)
        XCTAssertEqual(engine.mesh.edgeCount, 0)
        engine.commitPendingStroke(close: false)
        XCTAssertEqual(engine.mesh.edgeCount, engine.mesh.vertexCount - 1)
    }

    func testAStrokeThatRunsPastItsStartLosesTheOvershoot() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.tools.stroke.smoothing = 0
        let spiral = (0...60).map { i -> Vec2 in
            let a = Float.pi * 2.35 * Float(i) / 60
            let r = 100 + Float(i) * 0.12
            return Vec2(500 + cos(a) * r, 500 + sin(a) * r)
        }
        Fixtures.drawPath(engine, spiral)
        XCTAssertEqual(engine.mesh.edgeCount, engine.mesh.vertexCount, "one clean loop")
        for v in engine.mesh.aliveVertices { XCTAssertEqual(engine.mesh.edgesOf(v).count, 2, "no tail left over") }
        assertValid(engine.mesh)
    }

    func testAWideClosingGapGetsEvenVertices() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.tools.stroke.smoothing = 0
        let arc = (0...60).map { i -> Vec2 in
            let a = Float.pi * 1.9 * Float(i) / 60
            return Vec2(500 + cos(a) * 110, 500 + sin(a) * 110)
        }
        Fixtures.drawPath(engine, arc)
        XCTAssertEqual(engine.mesh.edgeCount, engine.mesh.vertexCount)
        let lengths = engine.mesh.aliveEdges.map { simd_length(engine.mesh.position(engine.mesh.ends($0).0) - engine.mesh.position(engine.mesh.ends($0).1)) }
        XCTAssertLessThan(lengths.max()!, engine.tools.stroke.edgeLength * 2, "the closing span isn't one long edge")
    }

    func testDrawnNearlyClosedStripBecomesARing() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.quadStrip)
        Fixtures.drawPath(engine, Fixtures.circle(center: Vec2(500, 500), radius: 120))
        let pending = try XCTUnwrap(engine.pendingStrip)
        XCTAssertTrue(pending.path.isClosed)
        XCTAssertNotNil(pending.openPath)
        engine.commitPendingStrip()
        XCTAssertGreaterThan(engine.mesh.faceCount, 4)
        XCTAssertEqual(engine.mesh.vertexCount - engine.mesh.edgeCount + engine.mesh.faceCount, 0, "a ring has an Euler characteristic of zero")
        assertValid(engine.mesh)
    }

    func testARingStripCanBeKeptOpen() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.quadStrip)
        Fixtures.drawPath(engine, Fixtures.circle(center: Vec2(500, 500), radius: 120))
        engine.keepStripOpen()
        let pending = try XCTUnwrap(engine.pendingStrip)
        XCTAssertFalse(pending.path.isClosed)
        XCTAssertNil(pending.openPath)
        engine.commitPendingStrip()
        XCTAssertEqual(engine.mesh.vertexCount - engine.mesh.edgeCount + engine.mesh.faceCount, 1, "an open strip is a disc")
        assertValid(engine.mesh)
    }

    func testOpenStrokeCommitsRealEdges() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(400, 450), to: Vec2(600, 450))
        XCTAssertNil(engine.pendingStroke)
        XCTAssertGreaterThan(engine.mesh.edgeCount, 3)
        XCTAssertEqual(engine.mesh.edgeCount, engine.mesh.vertexCount - 1)
        for v in engine.mesh.aliveVertices {
            XCTAssertEqual(simd_length(engine.mesh.position(v)), 1 + engine.tools.surfaceOffset, accuracy: 0.01, "vertices sit on the surface")
        }
        assertValid(engine.mesh)
    }

    func testShortStrokesAreIgnored() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(500, 500), to: Vec2(503, 501))
        XCTAssertEqual(engine.mesh.edgeCount, 0)
    }

    func testStrokeOffTheModelAddsNothing() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(10, 10), to: Vec2(100, 20))
        XCTAssertEqual(engine.mesh.edgeCount, 0)
        XCTAssertEqual(engine.message?.kind, .warning)
    }

    // MARK: Interaction with existing topology

    func testEndpointSnapsToExistingVertex() throws {
        let engine = Fixtures.engine(with: Fixtures.plane(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(300, 500), to: Vec2(500, 500))
        let endCount = engine.mesh.vertexCount
        Fixtures.draw(engine, from: Vec2(505, 503), to: Vec2(500, 300))
        let junctions = engine.mesh.aliveVertices.filter { engine.mesh.edgesOf($0).count == 3 }
        XCTAssertEqual(engine.mesh.vertexCount - endCount, engine.mesh.edgeCount - (endCount - 1), "the second stroke shares its first vertex")
        XCTAssertTrue(junctions.isEmpty, "joining at an end makes a valence-2 corner, not a junction")
        XCTAssertEqual(MeshValidator.connectedComponents(engine.mesh).count, 1)
        assertValid(engine.mesh)
    }

    func testCrossingAWireEdgeSplitsItAtASharedVertex() throws {
        let engine = Fixtures.engine(with: Fixtures.plane(), camera: Fixtures.frontCamera())
        engine.tools.stroke.edgeLength = 0.5
        Fixtures.draw(engine, from: Vec2(200, 500), to: Vec2(800, 500))
        let first = engine.mesh.vertexCount
        Fixtures.draw(engine, from: Vec2(560, 200), to: Vec2(560, 800))
        XCTAssertEqual(MeshValidator.connectedComponents(engine.mesh).count, 1, "the strokes are connected at the crossing")
        let junctions = engine.mesh.aliveVertices.filter { engine.mesh.edgesOf($0).count == 4 }
        XCTAssertEqual(junctions.count, 1)
        XCTAssertGreaterThan(engine.mesh.vertexCount, first)
        assertValid(engine.mesh)
    }

    func testCrossingNearAVertexUsesThatVertex() throws {
        let engine = Fixtures.engine(with: Fixtures.plane(), camera: Fixtures.frontCamera())
        engine.tools.stroke.edgeLength = 0.5
        Fixtures.draw(engine, from: Vec2(200, 500), to: Vec2(800, 500))
        let vertices = engine.mesh.aliveVertices
        let middle = try XCTUnwrap(vertices.first { abs(engine.mesh.position($0).x) < 0.3 && engine.mesh.edgesOf($0).count == 2 })
        let screen = try XCTUnwrap(engine.camera.project(engine.mesh.position(middle))?.screen)
        Fixtures.draw(engine, from: Vec2(screen.x + 3, 200), to: Vec2(screen.x + 3, 800))
        XCTAssertEqual(engine.mesh.edgesOf(middle).count, 4, "snaps to the nearby vertex rather than adding one beside it")
        assertValid(engine.mesh)
    }

    func testStrokeOverFacesStopsAtTheirBoundaryAndAsks() throws {
        let engine = Fixtures.engine(with: Fixtures.plane(), camera: Fixtures.frontCamera())
        // A big quad on the surface around the origin.
        let v = [Vec3(-0.5, -0.5, 0), Vec3(0.5, -0.5, 0), Vec3(0.5, 0.5, 0), Vec3(-0.5, 0.5, 0)]
        engine.perform("seed") { mesh, _ in
            let ids = v.map { mesh.addVertex($0) }
            try mesh.addFace(ids)
        }
        // Long stroke straight across the quad.
        engine.tools.stroke.edgeLength = 0.1
        let left = try XCTUnwrap(engine.camera.project(Vec3(-1.5, 0, 0))?.screen)
        let right = try XCTUnwrap(engine.camera.project(Vec3(1.5, 0, 0))?.screen)
        Fixtures.draw(engine, from: left, to: right)
        let pending = try XCTUnwrap(engine.pendingStroke)
        XCTAssertTrue(pending.plans[0].droppedOverFaces)
        engine.commitPendingStroke(close: false)
        // No edge crosses the quad's interior, and the quad gains the crossing points.
        XCTAssertEqual(engine.mesh.faceCount, 1)
        for e in engine.mesh.aliveEdges {
            let mid = engine.mesh.edgeMidpoint(e)
            let inside = abs(mid.x) < 0.49 && abs(mid.y) < 0.49
            XCTAssertFalse(inside, "edge \(e) at \(mid) runs across the face")
        }
        XCTAssertEqual(MeshValidator.connectedComponents(engine.mesh).count, 1, "both parts of the stroke attach to the quad")
        assertValid(engine.mesh)
    }

    func testEdgeLoopToolClosesAutomaticallyWhenNear() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.edgeLoop)
        Fixtures.drawPath(engine, Fixtures.circle(center: Vec2(500, 500), radius: 100))
        XCTAssertNil(engine.pendingStroke)
        XCTAssertEqual(engine.mesh.edgeCount, engine.mesh.vertexCount)
        for v in engine.mesh.aliveVertices { XCTAssertEqual(engine.mesh.edgesOf(v).count, 2) }
    }

    func testEdgeLoopToolShowsIncompleteResultForWideGap() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.edgeLoop)
        let arc = (0...40).map { i -> Vec2 in
            let a = Float.pi * 1.2 * Float(i) / 40
            return Vec2(500 + cos(a) * 100, 500 + sin(a) * 100)
        }
        Fixtures.drawPath(engine, arc)
        let pending = try XCTUnwrap(engine.pendingStroke)
        XCTAssertNotNil(pending.note)
        XCTAssertEqual(engine.mesh.edgeCount, 0, "the mesh isn't touched until the artist decides")
    }

    func testSelfCrossingStrokeSharesAVertex() throws {
        let engine = Fixtures.engine(with: Fixtures.plane(), camera: Fixtures.frontCamera())
        engine.tools.stroke.edgeLength = 0.1
        engine.tools.stroke.smoothing = 0
        // A loop-the-loop that crosses itself but with ends far apart.
        var points: [Vec2] = []
        for i in 0...60 {
            let t = Float(i) / 60
            let a = t * 2 * .pi
            points.append(Vec2(300 + 400 * t + sin(a) * 100, 500 + (1 - cos(a)) * 80))
        }
        Fixtures.drawPath(engine, points)
        engine.commitPendingStroke(close: false)
        assertValid(engine.mesh)
    }

    // MARK: Carrying on from lines, and joining them

    private func freeEnds(_ mesh: Mesh) -> Int {
        mesh.aliveVertices.filter { mesh.edgesOf($0).count == 1 }.count
    }

    func testAStrokeFromTheEndOfALineCarriesItOn() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(350, 500), to: Vec2(480, 500))
        var events: [RetopoEngine.EngineEvent] = []
        engine.onEvent = { events.append($0) }
        // Further from the end than a snap reaches, but heading on from it.
        Fixtures.draw(engine, from: Vec2(515, 500), to: Vec2(650, 500))
        XCTAssertEqual(freeEnds(engine.mesh), 2, "one line, not two")
        XCTAssertEqual(engine.message?.text, "Extended the line.")
        XCTAssertTrue(events.contains(.strokeSnapped))
    }

    func testAParallelLineStartingNearAnEndStaysSeparate() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(400, 470), to: Vec2(600, 470))
        Fixtures.draw(engine, from: Vec2(400, 505), to: Vec2(600, 505))
        XCTAssertEqual(freeEnds(engine.mesh), 4, "it runs back alongside the line, so it doesn't continue it")
    }

    func testAnExtendedLineIsMeasuredWholeForTheFillOffer() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(400, 450), to: Vec2(600, 450))
        Fixtures.draw(engine, from: Vec2(400, 530), to: Vec2(480, 530))
        XCTAssertNil(engine.fillSuggestion, "too short beside the first line")
        Fixtures.draw(engine, from: Vec2(510, 530), to: Vec2(600, 530))
        XCTAssertNotNil(engine.fillSuggestion, "together they run alongside it")
    }

    func testAStrokeBetweenALinesTwoEndsClosesIt() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        let circle = Fixtures.circle(center: Vec2(500, 500), radius: 150)
        Fixtures.drawPath(engine, Array(circle[0...32]))
        var events: [RetopoEngine.EngineEvent] = []
        engine.onEvent = { events.append($0) }
        Fixtures.drawPath(engine, Array(circle[34...62]))
        XCTAssertEqual(freeEnds(engine.mesh), 0)
        XCTAssertTrue(events.contains(.loopClosed))
    }

    func testAStrokeAcrossTwoLinesJoinsThemAndDropsTheOvershoot() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(400, 440), to: Vec2(600, 440))
        Fixtures.draw(engine, from: Vec2(400, 560), to: Vec2(600, 560))
        engine.dismissFillSuggestion()
        Fixtures.draw(engine, from: Vec2(500, 410), to: Vec2(500, 590))
        XCTAssertEqual(freeEnds(engine.mesh), 4, "only the two lines' own ends are left loose")
        XCTAssertEqual(engine.message?.text, "Connected 2 lines.")
        XCTAssertEqual(engine.mesh.faceCount, 0)
    }

    func testALongOvershootPastTwoLinesIsKept() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(400, 440), to: Vec2(600, 440))
        Fixtures.draw(engine, from: Vec2(400, 560), to: Vec2(600, 560))
        engine.dismissFillSuggestion()
        Fixtures.draw(engine, from: Vec2(500, 340), to: Vec2(500, 660))
        XCTAssertEqual(freeEnds(engine.mesh), 6, "the stroke meant to go on past them")
    }

    func testCrossingOneLineStillKeepsBothEnds() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(400, 500), to: Vec2(600, 500))
        Fixtures.draw(engine, from: Vec2(500, 460), to: Vec2(500, 540))
        XCTAssertEqual(freeEnds(engine.mesh), 4)
    }
}
