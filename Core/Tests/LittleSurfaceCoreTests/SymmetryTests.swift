import XCTest
import simd
@testable import LittleSurfaceCore

final class SymmetryTests: XCTestCase {
    private func symmetricEngine(_ source: SourceObject = Fixtures.sphere()) -> RetopoEngine {
        let engine = Fixtures.engine(with: source, camera: Fixtures.frontCamera())
        engine.setSymmetryEnabled(true)
        return engine
    }

    private func screen(_ engine: RetopoEngine, _ p: Vec3) -> Vec2 {
        engine.camera.project(p)!.screen
    }

    func testMirroredStrokeOnBothSides() throws {
        let engine = symmetricEngine()
        Fixtures.draw(engine, from: screen(engine, Vec3(0.2, -0.3, 0.9)), to: screen(engine, Vec3(0.5, 0.3, 0.8)))
        let mesh = engine.mesh
        XCTAssertGreaterThan(mesh.vertexCount, 4)
        XCTAssertEqual(MeshValidator.connectedComponents(mesh).count, 2)
        var positive = 0, negative = 0
        for v in mesh.aliveVertices {
            let p = mesh.position(v)
            if p.x > 0 { positive += 1 } else { negative += 1 }
            let partner = mesh.mirrorPartner[Int(v)]
            XCTAssertGreaterThanOrEqual(partner, 0, "every vertex has a partner")
            XCTAssertLessThan(simd_length(engine.symmetry.plane.reflect(p) - mesh.position(partner)), 0.02)
        }
        XCTAssertEqual(positive, negative)
        assertValid(mesh)
    }

    func testStrokeAcrossPlaneSharesCenterVertex() throws {
        let engine = symmetricEngine()
        engine.tools.stroke.edgeLength = 0.13
        // Starts on the right, ends on the left, crossing the plane at an angle.
        Fixtures.draw(engine, from: screen(engine, Vec3(0.5, 0.2, 0.8)), to: screen(engine, Vec3(-0.4, -0.2, 0.85)))
        let mesh = engine.mesh
        let center = mesh.aliveVertices.filter { abs(mesh.position($0).x) < 1e-5 }
        XCTAssertEqual(center.count, 1, "exactly one vertex at the crossing, shared by both strokes")
        XCTAssertEqual(mesh.mirrorPartner[Int(center[0])], center[0])
        XCTAssertEqual(mesh.edgesOf(center[0]).count, 4, "stroke and mirror image cross there")
        assertValid(mesh)
    }

    func testStrokeAlongCenterlineMakesNoDuplicates() throws {
        let engine = symmetricEngine()
        Fixtures.draw(engine, from: screen(engine, Vec3(0, -0.5, 0.86)), to: screen(engine, Vec3(0, 0.5, 0.86)))
        let mesh = engine.mesh
        XCTAssertGreaterThan(mesh.vertexCount, 3)
        for v in mesh.aliveVertices {
            XCTAssertEqual(mesh.position(v).x, 0, accuracy: 1e-6, "snapped onto the plane")
            XCTAssertEqual(mesh.mirrorPartner[Int(v)], v)
        }
        XCTAssertEqual(mesh.edgeCount, mesh.vertexCount - 1, "one polyline, not two overlapping ones")
    }

    func testStripOnOneSideMirrors() throws {
        let engine = symmetricEngine(Fixtures.sphere(rings: 64, segments: 96))
        engine.setTool(.quadStrip)
        engine.tools.strip.width = 0.2
        engine.tools.strip.segments = 6
        Fixtures.draw(engine, from: screen(engine, Vec3(0.2, -0.4, 0.89)), to: screen(engine, Vec3(0.5, 0.2, 0.84)))
        engine.commitPendingStrip()
        XCTAssertEqual(engine.mesh.faceCount, 12)
        for f in engine.mesh.aliveFaces {
            XCTAssertGreaterThan(simd_dot(engine.mesh.faceNormal(f), engine.mesh.faceCenter(f)), 0, "mirrored faces wind correctly too")
        }
        assertValid(engine.mesh)
        assertConsistentWinding(engine.mesh)
    }

    func testStripCrossingPlaneStopsThereAndWelds() throws {
        let engine = symmetricEngine(Fixtures.plane())
        engine.setSymmetryPlane(axis: .x, offset: 0)
        engine.setTool(.quadStrip)
        engine.tools.strip.width = 0.4
        engine.tools.strip.segments = 6
        Fixtures.draw(engine, from: screen(engine, Vec3(1, 0, 0)), to: screen(engine, Vec3(-1, 0, 0)))
        engine.commitPendingStrip()
        let mesh = engine.mesh
        XCTAssertEqual(mesh.faceCount, 12, "six on each side, without overlap")
        let center = mesh.aliveVertices.filter { abs(mesh.position($0).x) < 1e-5 }
        XCTAssertEqual(center.count, 2, "the two center vertices are shared, not doubled")
        XCTAssertEqual(MeshValidator.connectedComponents(mesh).count, 1)
        let report = MeshValidator.analyze(mesh)
        XCTAssertNil(report.issue(.duplicateVertices))
        XCTAssertNil(report.issue(.selfIntersections))
        assertValid(mesh)
        assertConsistentWinding(mesh)
    }

    func testPatchBetweenMirroredChainsHasNoDoubledHalf() throws {
        let engine = symmetricEngine(Fixtures.plane())
        engine.setSymmetryPlane(axis: .x, offset: 0)
        engine.tools.stroke.edgeLength = 0.25
        // One stroke at x = 0.5 makes its mirror at x = -0.5. Fill between the pair.
        Fixtures.draw(engine, from: screen(engine, Vec3(0.5, -0.5, 0)), to: screen(engine, Vec3(0.5, 0.5, 0)))
        engine.setTool(.quadPatch)
        engine.patchTap(at: screen(engine, Vec3(0.5, 0, 0)))
        engine.patchTap(at: screen(engine, Vec3(-0.5, 0, 0)))
        engine.tools.patch.rows = 3
        engine.updatePatchPreview()
        XCTAssertNil(engine.patchError)
        engine.commitPatch()
        let mesh = engine.mesh
        let columns = mesh.aliveEdges.count
        XCTAssertGreaterThan(columns, 0)
        let segments = 4
        XCTAssertEqual(mesh.faceCount, segments * 3, "one patch across the plane, not one per side")
        XCTAssertNil(MeshValidator.analyze(mesh).issue(.duplicateVertices))
        assertValid(mesh)
        assertConsistentWinding(mesh)
    }

    func testAsymmetricSourceProjectsEachSideToItsOwnSurface() throws {
        // A sphere pushed off center: its two sides aren't mirror images about x = 0.
        let lopsided = Fixtures.sphere(radius: 1, center: Vec3(0.05, 0, 0), rings: 64, segments: 96)
        let engine = symmetricEngine(lopsided)
        engine.setSymmetryPlane(axis: .x, offset: 0)
        engine.setSurfaceOffset(0)
        Fixtures.draw(engine, from: screen(engine, Vec3(0.3, -0.3, 0.88)), to: screen(engine, Vec3(0.5, 0.3, 0.78)))
        let center = Vec3(0.05, 0, 0)
        for v in engine.mesh.aliveVertices {
            XCTAssertEqual(simd_length(engine.mesh.position(v) - center), 1, accuracy: 0.01, "both sides stay on the surface")
        }
    }

    func testMovingAVertexMovesItsMirror() throws {
        let engine = symmetricEngine()
        Fixtures.draw(engine, from: screen(engine, Vec3(0.2, -0.3, 0.9)), to: screen(engine, Vec3(0.5, 0.3, 0.8)))
        engine.setTool(.select)
        let mesh = engine.mesh
        let v = try XCTUnwrap(mesh.aliveVertices.first { mesh.position($0).x > 0 })
        let partner = mesh.mirrorPartner[Int(v)]
        let from = screen(engine, mesh.position(v))
        let to = from + Vec2(40, 25)
        Fixtures.draw(engine, from: from, to: to)
        let moved = engine.mesh.position(v), movedPartner = engine.mesh.position(partner)
        XCTAssertGreaterThan(simd_length(moved - mesh.position(v)), 0.01)
        XCTAssertLessThan(simd_length(engine.symmetry.plane.reflect(moved) - movedPartner), 0.02)
        XCTAssertEqual(simd_length(movedPartner), 1 + engine.tools.surfaceOffset, accuracy: 0.01)
    }

    func testCenterVertexStaysOnPlaneWhenMoved() throws {
        let engine = symmetricEngine()
        engine.perform("seed") { mesh, _ in
            let v = mesh.addVertex(Vec3(0, 0, 1))
            let w = mesh.addVertex(Vec3(0.2, 0, 0.98))
            try mesh.ensureEdge(v, w)
        }
        engine.setTool(.select)
        let v = try XCTUnwrap(engine.mesh.aliveVertices.first { engine.mesh.position($0).x == 0 })
        let from = screen(engine, engine.mesh.position(v))
        Fixtures.draw(engine, from: from, to: from + Vec2(60, 40))
        XCTAssertEqual(engine.mesh.position(v).x, 0, accuracy: 1e-6)
        XCTAssertLessThan(engine.mesh.position(v).y, -0.01)
    }

    func testDeleteAndSubdivideActOnBothSides() throws {
        let engine = symmetricEngine(Fixtures.plane())
        engine.setSymmetryPlane(axis: .x, offset: 0)
        engine.setTool(.quadStrip)
        engine.tools.strip.width = 0.4
        engine.tools.strip.segments = 4
        Fixtures.draw(engine, from: screen(engine, Vec3(0.5, -0.5, 0)), to: screen(engine, Vec3(0.5, 0.5, 0)))
        engine.commitPendingStrip()
        XCTAssertEqual(engine.mesh.faceCount, 8)

        engine.setTool(.select)
        engine.setSelectionMode(.face)
        let f = try XCTUnwrap(engine.mesh.aliveFaces.first { engine.mesh.faceCenter($0).x > 0 })
        engine.clearSelection()
        engine.pencilBegan(at: screen(engine, engine.mesh.faceCenter(f)))
        engine.pencilEnded(at: screen(engine, engine.mesh.faceCenter(f)))
        XCTAssertEqual(engine.selection.faces, [f])
        engine.subdivideSelection()
        XCTAssertEqual(engine.mesh.faceCount, 14, "the face and its mirror each became four")
        for v in engine.mesh.aliveVertices { XCTAssertGreaterThanOrEqual(engine.mesh.mirrorPartner[Int(v)], 0, "new vertices are paired") }
        assertValid(engine.mesh)

        engine.selectAll()
        let total = engine.selection.faces.count
        engine.setSelectionMode(.face)
        engine.clearSelection()
        engine.pencilBegan(at: screen(engine, engine.mesh.faceCenter(engine.mesh.aliveFaces.first { engine.mesh.faceCenter($0).x > 0 }!)))
        engine.pencilEnded(at: screen(engine, engine.mesh.faceCenter(engine.mesh.aliveFaces.first { engine.mesh.faceCenter($0).x > 0 }!)))
        engine.deleteSelection()
        XCTAssertEqual(engine.mesh.faceCount, total - 2)
        assertValid(engine.mesh)
    }

    func testApplySymmetryProducesPlainWeldedGeometry() throws {
        var mesh = Mesh()
        // Half a strip: right side only, with its inner edge on the plane.
        let a = mesh.addVertex(Vec3(0, 0, 0)), b = mesh.addVertex(Vec3(1, 0, 0)), c = mesh.addVertex(Vec3(1, 1, 0)), d = mesh.addVertex(Vec3(0, 1, 0))
        try mesh.addFace([a, b, c, d])
        try Symmetry.apply(to: &mesh, plane: MirrorPlane(), centerTolerance: 0.001, keepPositive: true, projector: nil)
        XCTAssertEqual(mesh.faceCount, 2)
        XCTAssertEqual(mesh.vertexCount, 6, "center vertices aren't doubled")
        XCTAssertEqual(mesh.faceCountOf(edge: try XCTUnwrap(mesh.edge(between: a, d))), 2)
        assertValid(mesh)
        assertConsistentWinding(mesh)
        for f in mesh.aliveFaces { XCTAssertGreaterThan(mesh.faceNormal(f).z, 0.9) }
    }

    func testApplySymmetryDiscardsTheOtherSide() throws {
        var mesh = Mesh()
        let a = mesh.addVertex(Vec3(1, 0, 0)), b = mesh.addVertex(Vec3(2, 0, 0)), c = mesh.addVertex(Vec3(2, 1, 0))
        try mesh.addFace([a, b, c])
        let d = mesh.addVertex(Vec3(-5, 0, 0)), e = mesh.addVertex(Vec3(-6, 0, 0)), f = mesh.addVertex(Vec3(-6, 1, 0))
        try mesh.addFace([d, f, e])
        try Symmetry.apply(to: &mesh, plane: MirrorPlane(), centerTolerance: 0.001, keepPositive: true, projector: nil)
        XCTAssertEqual(mesh.faceCount, 2)
        XCTAssertEqual(mesh.bounds.minCorner.x, -2, accuracy: 1e-5, "the old left side was replaced by the mirror of the right")
        assertValid(mesh)
    }

    func testMergeCenterlineWeldsNearbyPairs() throws {
        let engine = symmetricEngine(Fixtures.plane())
        engine.setSymmetryEnabled(false)
        engine.setSymmetryPlane(axis: .x, offset: 0)
        engine.setCenterTolerance(0.05)
        engine.perform("seed") { mesh, _ in
            let a = mesh.addVertex(Vec3(0.01, 0, 0)), b = mesh.addVertex(Vec3(-0.01, 0, 0))
            let c = mesh.addVertex(Vec3(1, 0, 0)), d = mesh.addVertex(Vec3(-1, 0, 0))
            try mesh.ensureEdge(a, c)
            try mesh.ensureEdge(b, d)
        }
        engine.mergeCenterline()
        XCTAssertEqual(engine.mesh.vertexCount, 3)
        XCTAssertEqual(MeshValidator.connectedComponents(engine.mesh).count, 1)
        XCTAssertEqual(engine.mesh.aliveVertices.filter { engine.mesh.position($0).x == 0 }.count, 1)
        assertValid(engine.mesh)
    }

    func testYAndZPlanes() throws {
        for axis in [MirrorAxis.y, .z] {
            var mesh = Mesh()
            var p = Vec3(1, 1, 1)
            p[axis.rawValue] = 0
            var q = Vec3(1, 1, 1)
            q[axis.rawValue] = 2
            let a = mesh.addVertex(p), b = mesh.addVertex(q)
            try mesh.ensureEdge(a, b)
            try Symmetry.apply(to: &mesh, plane: MirrorPlane(axis: axis), centerTolerance: 0.01, keepPositive: true, projector: nil)
            XCTAssertEqual(mesh.vertexCount, 3)
            XCTAssertEqual(mesh.bounds.minCorner[axis.rawValue], -2, accuracy: 1e-5)
            assertValid(mesh)
        }
    }

    func testWeldingACenterlineVertexIntoAPairedOneKeepsPartnersReciprocal() throws {
        var mesh = Mesh()
        let center = mesh.addVertex(Vec3(0, 0, 0))
        let left = mesh.addVertex(Vec3(-1, 0, 0)), right = mesh.addVertex(Vec3(1, 0, 0))
        mesh.setMirrorPartner(center, center)
        mesh.setMirrorPartner(left, right)
        mesh.setMirrorPartner(right, left)
        try mesh.mergeVertex(center, into: left)
        XCTAssertNil(mesh.firstInvariantViolation())
        XCTAssertEqual(mesh.mirrorPartner[Int(left)], right)
    }
}

final class MirrorPairConsistencyTests: XCTestCase {
    func testChangingAPartnerReleasesTheOldOne() {
        var mesh = Mesh()
        let a = mesh.addVertex(Vec3(1, 0, 0)), b = mesh.addVertex(Vec3(-1, 0, 0)), c = mesh.addVertex(Vec3(0, 1, 0))
        mesh.setMirrorPartner(a, b)
        mesh.setMirrorPartner(b, a)
        mesh.setMirrorPartner(a, a)
        XCTAssertEqual(mesh.mirrorPartner[Int(b)], invalidID)
        assertValid(mesh)

        mesh.setMirrorPartner(b, c)
        mesh.setMirrorPartner(c, b)
        mesh.setMirrorPartner(a, c)
        mesh.setMirrorPartner(c, a)
        XCTAssertEqual(mesh.mirrorPartner[Int(b)], invalidID)
        assertValid(mesh)
    }

    /// Files written before this was fixed can hold these links. They're rebuilt from positions anyway,
    /// so they're never a reason to refuse someone's project.
    func testAProjectSavedWithBrokenPairsStillOpens() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setSymmetryEnabled(true)
        Fixtures.draw(engine, from: Vec2(540, 400), to: Vec2(640, 420))
        var snapshot = engine.makeSnapshot()
        let vertices = snapshot.mesh.aliveVertices
        let first = Int(vertices[0]), second = Int(vertices[1])
        snapshot.mesh.mirrorPartner[first] = vertices[1]     // Not returned.
        snapshot.mesh.mirrorPartner[second] = Int32(snapshot.mesh.positions.count + 5)
        let reopened = try ProjectCodec.decode(try ProjectCodec.encode(snapshot))
        assertValid(reopened.mesh)
        XCTAssertEqual(reopened.mesh.vertexCount, snapshot.mesh.vertexCount)
    }
}
