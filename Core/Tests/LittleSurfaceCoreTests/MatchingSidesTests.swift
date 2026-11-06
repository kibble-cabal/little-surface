import XCTest
import simd
@testable import LittleSurfaceCore

/// Two points on top of each other, which nobody meant.
final class PointsTooCloseTests: XCTestCase {
    private func stripWithAStackedCorner(gap: Float) throws -> (Mesh, VertexID) {
        var mesh = Mesh()
        let a = mesh.addVertex(Vec3(1, 1, 0)), b = mesh.addVertex(Vec3(1, 0, 0)), c = mesh.addVertex(Vec3(2, 0, 0))
        let d = mesh.addVertex(Vec3(2, 1, 0)), extra = mesh.addVertex(Vec3(1.5, 1, 0)), stacked = mesh.addVertex(Vec3(1.5 - gap, 1, 0))
        try mesh.addFace([a, b, c, d, extra, stacked], autoOrient: false)
        return (mesh, stacked)
    }

    func testAPointMadeOnTopOfAnotherJoinsIt() throws {
        var (mesh, stacked) = try stripWithAStackedCorner(gap: 0.001)
        XCTAssertEqual(mesh.cornerCount(of: mesh.aliveFaces[0]), 6)
        var result = PlanResult()
        result.vertices = [stacked]
        var met: [VertexID] = []
        DrawnFaces.joinPointsTooCloseToTell(result: &result, met: &met, gap: 0.003, in: &mesh, symmetry: SymmetrySettings())
        XCTAssertEqual(mesh.cornerCount(of: mesh.aliveFaces[0]), 5)
        XCTAssertEqual(mesh.aliveVertices.count, 5)
    }

    func testPointsAlreadyThereAndPointsApartAreLeftAlone() throws {
        var (mesh, stacked) = try stripWithAStackedCorner(gap: 0.001)
        var result = PlanResult()
        var met: [VertexID] = []
        DrawnFaces.joinPointsTooCloseToTell(result: &result, met: &met, gap: 0.003, in: &mesh, symmetry: SymmetrySettings())
        XCTAssertEqual(mesh.aliveVertices.count, 6)
        (mesh, stacked) = try stripWithAStackedCorner(gap: 0.01)
        result.vertices = [stacked]
        DrawnFaces.joinPointsTooCloseToTell(result: &result, met: &met, gap: 0.003, in: &mesh, symmetry: SymmetrySettings())
        XCTAssertEqual(mesh.aliveVertices.count, 6)
    }

    func testTheOtherSideJoinsToo() throws {
        var (mesh, stacked) = try stripWithAStackedCorner(gap: 0.001)
        var image: [VertexID: VertexID] = [:]
        for v in mesh.aliveVertices {
            let p = mesh.position(v)
            image[v] = mesh.addVertex(Vec3(-p.x, p.y, p.z))
            mesh.setMirrorPartner(v, image[v]!)
            mesh.setMirrorPartner(image[v]!, v)
        }
        try mesh.addFace(mesh.loop(mesh.aliveFaces[0]).reversed().map { image[$0]! }, autoOrient: false)
        var settings = SymmetrySettings()
        settings.isEnabled = true
        var result = PlanResult()
        result.vertices = [stacked]
        var met: [VertexID] = []
        DrawnFaces.joinPointsTooCloseToTell(result: &result, met: &met, gap: 0.003, in: &mesh, symmetry: settings)
        XCTAssertEqual(mesh.aliveVertices.count, 10)
        for f in mesh.aliveFaces { XCTAssertEqual(mesh.cornerCount(of: f), 5) }
        for v in mesh.aliveVertices {
            let q = VertexID(mesh.mirrorPartner[Int(v)])
            XCTAssertTrue(mesh.isVertexAlive(q))
            XCTAssertEqual(VertexID(mesh.mirrorPartner[Int(q)]), v)
        }
    }

    func testAPairEitherSideOfTheMiddleBecomesOnePointOnIt() throws {
        var mesh = Mesh()
        let a = mesh.addVertex(Vec3(0.0005, 0, 0)), b = mesh.addVertex(Vec3(-0.0005, 0, 0))
        let c = mesh.addVertex(Vec3(1, 1, 0)), d = mesh.addVertex(Vec3(-1, 1, 0))
        try mesh.ensureEdge(a, c)
        try mesh.ensureEdge(b, d)
        mesh.setMirrorPartner(a, b)
        mesh.setMirrorPartner(b, a)
        mesh.setMirrorPartner(c, d)
        mesh.setMirrorPartner(d, c)
        var settings = SymmetrySettings()
        settings.isEnabled = true
        var result = PlanResult()
        result.vertices = [a, b]
        var met: [VertexID] = []
        DrawnFaces.joinPointsTooCloseToTell(result: &result, met: &met, gap: 0.003, in: &mesh, symmetry: settings)
        XCTAssertEqual(mesh.aliveVertices.count, 3)
        let middle = mesh.aliveVertices.first { mesh.edgesOf($0).count == 2 }!
        XCTAssertEqual(mesh.mirrorPartner[Int(middle)], middle)
        XCTAssertEqual(mesh.position(middle).x, 0, accuracy: 1e-5)
    }
}

/// Turning mirror on after drawing something, and every stroke from then on.
final class MatchingSidesTests: XCTestCase {
    private func engine() -> RetopoEngine {
        let e = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        e.setTool(.pencil)
        return e
    }

    /// Everything that's wrong with the two sides at the moment.
    private func faults(_ m: Mesh) -> [String] {
        var out: [String] = []
        for v in m.aliveVertices {
            let q = m.mirrorPartner[Int(v)]
            guard q >= 0 else { out.append("point \(v) has no partner"); continue }
            guard m.isVertexAlive(q), m.mirrorPartner[Int(q)] == v else { out.append("point \(v) has a bad partner"); continue }
            if m.isBendVertex(v) != m.isBendVertex(q) { out.append("point \(v) is real on one side only") }
            let p = m.position(q)
            if simd_length(Vec3(-p.x, p.y, p.z) - m.position(v)) > 0.01 { out.append("point \(v) is off from its partner") }
        }
        for e in m.aliveEdges where Symmetry.mirrorEdge(of: e, in: m) == nil { out.append("line \(e) has no mirror") }
        var sets: [Set<VertexID>: FaceID] = [:]
        for f in m.aliveFaces { sets[Set(m.loop(f).filter { !m.isBendVertex($0) })] = f }
        for f in m.aliveFaces {
            let corners = m.loop(f).filter { !m.isBendVertex($0) }
            guard let other = sets[Set(corners.map { m.mirrorPartner[Int($0)] })] else { out.append("face \(f) has no mirror"); continue }
            if m.isQuad(f) != m.isQuad(other) { out.append("face \(f) is a quad on one side only") }
        }
        return out
    }

    /// Roughly the same line either side, by hand: not quite in the same place, and not the same speed.
    private func drawBothSidesByHand(_ e: RetopoEngine) {
        Fixtures.draw(e, from: Vec2(560, 380), to: Vec2(580, 620), steps: 40, bend: Vec2(14, 0))
        Fixtures.draw(e, from: Vec2(437, 383), to: Vec2(418, 617), steps: 13, bend: Vec2(-16, 3))
    }

    func testLinesDrawnByHandOnBothSidesEndUpMatched() {
        let e = engine()
        drawBothSidesByHand(e)
        XCTAssertFalse(faults(e.mesh).isEmpty)
        let before = e.mesh.edgeCount
        e.setSymmetryEnabled(true)
        XCTAssertEqual(faults(e.mesh), [])
        XCTAssertLessThanOrEqual(e.mesh.edgeCount, before + 40, "Matched up, not doubled")
        XCTAssertEqual(e.mesh.aliveVertices.filter { !e.mesh.isBendVertex($0) }.count, 4)
    }

    func testALineWithNothingOppositeGoesAcross() {
        let e = engine()
        Fixtures.draw(e, from: Vec2(600, 400), to: Vec2(600, 600))
        let edges = e.mesh.edgeCount
        e.setSymmetryEnabled(true)
        XCTAssertEqual(faults(e.mesh), [])
        XCTAssertEqual(e.mesh.edgeCount, edges * 2)
        e.undo()
        XCTAssertEqual(e.mesh.edgeCount, edges, "It's one step to undo")
        XCTAssertTrue(e.symmetry.isEnabled, "and mirror stays on")
    }

    func testALineOverTheMiddleMatchesItself() {
        let e = engine()
        Fixtures.draw(e, from: Vec2(400, 500), to: Vec2(603, 490), bend: Vec2(0, 18))
        e.setSymmetryEnabled(true)
        XCTAssertEqual(faults(e.mesh), [])
    }

    func testAClosedOutlineStaysCurvedWhenMirrorComesOn() {
        // Close up, so the points on the line are closer together than the width of the middle.
        let e = engine()
        e.camera.distance *= 0.15
        var points: [Vec2] = []
        for i in 0...80 {
            let t = Float(i) / 80 * 2 * .pi + 2.2
            points.append(Vec2(500 + 180 * cos(t), 500 + 120 * sin(t)))
        }
        e.pencilBegan(at: points[0], pressure: 0.5)
        for p in points.dropFirst() { e.pencilMoved(to: p, pressure: 0.5) }
        e.pencilEnded(at: points[points.count - 1], pressure: 0.5)
        func length(_ m: Mesh) -> Float { m.aliveEdges.reduce(0) { let (a, b) = m.ends($1); return $0 + simd_length(m.position(a) - m.position(b)) } }
        let before = length(e.mesh)
        e.setSymmetryEnabled(true)
        XCTAssertEqual(faults(e.mesh), [])
        XCTAssertEqual(length(e.mesh), before, accuracy: before * 0.05, "Nothing went straight")
        XCTAssertEqual(e.mesh.aliveVertices.filter { e.mesh.mirrorPartner[Int($0)] == $0 }.count, 2, "It goes over the middle twice, not along it")
        XCTAssertEqual(e.mesh.aliveFaces.filter(e.mesh.isQuad).count, 0)
        XCTAssertEqual(e.mesh.aliveFaces.count, 1)
    }

    func testTheSmootherOfTwoLinesIsTheOneThatsKept() {
        let e = engine()
        var wobbly: [Vec2] = []
        for i in 0...60 { wobbly.append(Vec2(440 + (i % 8 < 4 ? 4 : -4), 400 + Float(i) * 200 / 60)) }
        e.pencilBegan(at: wobbly[0], pressure: 0.5)
        for p in wobbly.dropFirst() { e.pencilMoved(to: p, pressure: 0.5) }
        e.pencilEnded(at: wobbly[wobbly.count - 1], pressure: 0.5)
        Fixtures.draw(e, from: Vec2(560, 400), to: Vec2(560, 600))
        func length(_ m: Mesh, _ keep: (Vec3) -> Bool) -> Float {
            m.aliveEdges.reduce(0) { let (a, b) = m.ends($1); return keep(m.position(a)) ? $0 + simd_length(m.position(a) - m.position(b)) : $0 }
        }
        let smooth = length(e.mesh) { $0.x > 0 }
        XCTAssertGreaterThan(length(e.mesh) { $0.x < 0 }, smooth * 1.02, "The wobble has to be there to begin with")
        e.setSymmetryEnabled(true)
        XCTAssertEqual(faults(e.mesh), [])
        XCTAssertEqual(length(e.mesh) { $0.x < 0 }, smooth, accuracy: smooth * 0.05)
        XCTAssertEqual(length(e.mesh) { $0.x > 0 }, smooth, accuracy: smooth * 0.05)
    }

    func testStrokesAfterTurningMirrorOnMakeTheSameShapesBothSides() {
        let e = engine()
        drawBothSidesByHand(e)
        Fixtures.draw(e, from: Vec2(400, 450), to: Vec2(603, 440), bend: Vec2(0, 10))
        e.setSymmetryEnabled(true)
        XCTAssertEqual(faults(e.mesh), [])
        Fixtures.draw(e, from: Vec2(620, 540), to: Vec2(500, 540))
        Fixtures.draw(e, from: Vec2(620, 590), to: Vec2(500, 590))
        Fixtures.draw(e, from: Vec2(530, 420), to: Vec2(530, 620))
        XCTAssertEqual(faults(e.mesh), [])
        XCTAssertGreaterThan(e.mesh.aliveFaces.count, 1)
    }

    func testSmoothingOneSideLeavesTheOtherLineSmooth() {
        let e = engine()
        drawBothSidesByHand(e)
        e.setSymmetryEnabled(true)
        e.setTool(.relaxBrush)
        for _ in 0..<3 {
            e.pencilBegan(at: Vec2(575, 420), pressure: 0.5)
            for t in 1...20 { e.pencilMoved(to: Vec2(575, 420 + Float(t) * 8), pressure: 0.5) }
            e.pencilEnded(at: Vec2(575, 580), pressure: 0.5)
        }
        XCTAssertEqual(faults(e.mesh), [])
        for v in e.mesh.aliveVertices where e.mesh.isBendVertex(v) && e.mesh.edgesOf(v).count == 2 {
            let es = e.mesh.edgesOf(v)
            let a = e.mesh.position(e.mesh.otherEnd(es[0], from: v)) - e.mesh.position(v)
            let b = e.mesh.position(e.mesh.otherEnd(es[1], from: v)) - e.mesh.position(v)
            XCTAssertLessThan(simd_dot(a, b), 0, "No line doubles back on itself")
        }
    }

    func testTurningMirrorOffAndOnAgainChangesNothingThatsMatched() {
        let e = engine()
        e.setSymmetryEnabled(true)
        Fixtures.draw(e, from: Vec2(600, 400), to: Vec2(600, 600))
        Fixtures.draw(e, from: Vec2(650, 500), to: Vec2(550, 500))
        let m = e.mesh
        e.setSymmetryEnabled(false)
        e.setSymmetryEnabled(true)
        XCTAssertEqual(e.mesh.positions, m.positions)
        XCTAssertEqual(e.mesh.edgeCount, m.edgeCount)
    }

    func testAStrokeOverAnUnpairedLineStillMeetsItsOtherSide() {
        // Saved with mirror on and its lines unpaired, as an older project can be.
        let drawn = engine()
        Fixtures.draw(drawn, from: Vec2(600, 400), to: Vec2(600, 600))
        Fixtures.draw(drawn, from: Vec2(401, 400), to: Vec2(401, 600))
        var saved = drawn.makeSnapshot()
        saved.symmetry.isEnabled = true
        let e = RetopoEngine(snapshot: saved)
        e.installLoadedBVHs(RetopoEngine.buildBVHs(for: saved.sources))
        e.camera = drawn.camera
        e.setTool(.pencil)
        Fixtures.draw(e, from: Vec2(650, 500), to: Vec2(550, 500))
        let crossings = e.mesh.aliveVertices.filter { !e.mesh.isBendVertex($0) && e.mesh.edgesOf($0).count == 4 }
        XCTAssertEqual(crossings.count, 2, "It crosses the line on both sides")
    }
}
