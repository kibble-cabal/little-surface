import XCTest
import simd
@testable import LittleSurfaceCore

final class SubdivisionTests: XCTestCase {
    private func cube() -> Mesh {
        var mesh = Mesh()
        let corners: [Vec3] = [Vec3(-1,-1,-1), Vec3(1,-1,-1), Vec3(1,1,-1), Vec3(-1,1,-1), Vec3(-1,-1,1), Vec3(1,-1,1), Vec3(1,1,1), Vec3(-1,1,1)]
        let v = corners.map { mesh.addVertex($0) }
        let faces: [[Int]] = [[3,2,1,0],[4,5,6,7],[0,1,5,4],[2,3,7,6],[1,2,6,5],[3,0,4,7]]
        for q in faces { try! mesh.addFace(q.map { v[$0] }, autoOrient: false) }
        return mesh
    }

    func testCubeCountsAndKnownPositions() throws {
        let result = try CatmullClark.subdivide(cube().polygonMesh().mesh)
        XCTAssertEqual(result.faceCount, 24)
        XCTAssertEqual(result.positions.count, 26, "8 corners + 12 edges + 6 faces")
        // Corner rule for valence 3: (F + 2R + (n-3)P) / n puts cube corners at 5/9.
        XCTAssertEqual(result.positions[0].x, -5.0 / 9.0, accuracy: 1e-5)
        XCTAssertEqual(result.positions[0].y, -5.0 / 9.0, accuracy: 1e-5)
        // Face points stay at the face centers.
        let last = result.positions[25]
        XCTAssertEqual(simd_length(last), 1, accuracy: 1e-5)
    }

    func testPreviewDoesNotChangeBaseTopology() throws {
        let mesh = cube()
        let topology = mesh.topologyVersion
        let positions = mesh.positions
        let preview = try CatmullClark.preview(mesh, levels: 2)
        XCTAssertEqual(preview.levels, 2)
        XCTAssertEqual(preview.mesh.faceCount, 96)
        XCTAssertEqual(mesh.topologyVersion, topology)
        XCTAssertEqual(mesh.positions, positions)
        XCTAssertEqual(mesh.faceCount, 6)
    }

    func testPreviewStopsAtFaceLimit() throws {
        let preview = try CatmullClark.preview(cube(), levels: 8, maxFaces: 500)
        XCTAssertLessThan(preview.levels, 8)
        XCTAssertLessThanOrEqual(preview.mesh.faceCount, 500 * 4)
    }

    func testPreviewCancels() throws {
        XCTAssertThrowsError(try CatmullClark.preview(cube(), levels: 3, isCancelled: { true }))
    }

    func testOpenCornersSmoothLikeBlendersDefault() throws {
        let (mesh, ids) = Fixtures.grid(columns: 1, rows: 1)
        let poly = mesh.polygonMesh()
        let result = try CatmullClark.subdivide(poly.mesh)
        XCTAssertEqual(result.faceCount, 4)
        // 3/4 of itself + 1/8 of each boundary neighbour, Blender's "All" boundary smooth, so that
        // the preview matches a Subdivision Surface modifier added after export.
        XCTAssertEqual(result.positions[Int(poly.vertexMap[Int(ids[0][0])])], Vec3(0.125, 0.125, 0))
    }

    func testBoundaryEdgeVertexSmoothsAlongBoundaryOnly() throws {
        let (mesh, ids) = Fixtures.grid(columns: 2, rows: 1)
        var bent = mesh
        // Lift the middle boundary vertex: it should move 3/4 of the way to its old spot.
        bent.setPosition(ids[0][1], Vec3(1, 0, 1))
        let poly = bent.polygonMesh()
        let result = try CatmullClark.subdivide(poly.mesh)
        let p = result.positions[Int(poly.vertexMap[Int(ids[0][1])])]
        XCTAssertEqual(p.z, 0.75, accuracy: 1e-5)
        XCTAssertEqual(p.x, 1, accuracy: 1e-5)
    }

    func testResultKeepsOrientation() throws {
        let mesh = cube()
        let result = try CatmullClark.subdivide(mesh.polygonMesh().mesh)
        for f in 0..<result.faceCount {
            let corners = result.face(f).map { result.positions[Int($0)] }
            let n = GeometryMath.newellNormal(corners)
            let center = corners.reduce(Vec3(repeating: 0), +) / 4
            XCTAssertGreaterThan(simd_dot(n, center), 0, "outward stays outward")
        }
    }

    func testTrianglesAndNgonsBecomeQuads() throws {
        var mesh = Mesh()
        let v = (0..<5).map { i -> VertexID in
            let a = 2 * Float.pi * Float(i) / 5
            return mesh.addVertex(Vec3(cos(a), sin(a), 0))
        }
        try mesh.addFace(v)
        let c = mesh.addVertex(Vec3(2, 0, 0))
        try mesh.addFace([v[0], c, v[1]])
        let result = try CatmullClark.subdivide(mesh.polygonMesh().mesh)
        XCTAssertEqual(result.faceCount, 8)
        for f in 0..<result.faceCount { XCTAssertEqual(result.face(f).count, 4) }
    }

    func testApplyMakesRealEditableGeometryAndKeepsWires() throws {
        var mesh = cube()
        let a = mesh.addVertex(Vec3(5, 0, 0)), b = mesh.addVertex(Vec3(6, 0, 0))
        try mesh.ensureEdge(a, b)
        try mesh.applyCatmullClark(projector: nil)
        XCTAssertEqual(mesh.faceCount, 24)
        XCTAssertEqual(mesh.vertexCount, 28)
        XCTAssertEqual(MeshValidator.analyze(mesh).issue(.looseEdges)?.count, 1)
        assertValid(mesh)
        assertConsistentWinding(mesh)
    }

    func testEngineKeepsPreviewAndManualSubdivisionSeparate() throws {
        let engine = RetopoEngine()
        engine.perform("seed") { mesh, _ in mesh = self.cube() }
        engine.viewport.subdivisionPreview = true
        engine.viewport.subdivisionLevels = 2
        XCTAssertEqual(engine.mesh.faceCount, 6, "turning on the preview changes nothing real")
        engine.applySubdivision()
        XCTAssertEqual(engine.mesh.faceCount, 24)
        engine.undo()
        XCTAssertEqual(engine.mesh.faceCount, 6)
    }
}

final class ValidationTests: XCTestCase {
    func testStatistics() throws {
        var (mesh, ids) = Fixtures.grid(columns: 2, rows: 1)
        let tip = mesh.addVertex(Vec3(1, 2, 0))
        try mesh.addFace([ids[1][1], ids[1][0], tip].reversed())
        let w = mesh.addVertex(Vec3(9, 9, 9)), x = mesh.addVertex(Vec3(10, 9, 9))
        try mesh.ensureEdge(w, x)
        let stats = MeshStatistics(mesh)
        XCTAssertEqual(stats.vertices, 9)
        XCTAssertEqual(stats.edges, 10)
        XCTAssertEqual(stats.faces, 3)
        XCTAssertEqual(stats.quads, 2)
        XCTAssertEqual(stats.triangles, 1)
        XCTAssertEqual(stats.ngons, 0)
        XCTAssertEqual(stats.components, 2)
    }

    func testCleanMeshReportsNoErrors() throws {
        let (mesh, _) = Fixtures.grid(columns: 3, rows: 3)
        let report = MeshValidator.analyze(mesh)
        XCTAssertTrue(report.hasNoStructuralErrors)
        XCTAssertEqual(report.issue(.holes)?.count, 1, "a sheet has one open boundary")
    }

    func testDetectsDuplicatesAndDegenerates() throws {
        var mesh = Mesh()
        let a = mesh.addVertex(.zero), b = mesh.addVertex(Vec3(1, 0, 0)), c = mesh.addVertex(Vec3(1, 1, 0))
        let d = mesh.addVertex(Vec3(1, 0, 0) + Vec3(1e-7, 0, 0))
        try mesh.addFace([a, b, c])
        let collinear = [mesh.addVertex(Vec3(5, 0, 0)), mesh.addVertex(Vec3(6, 0, 0)), mesh.addVertex(Vec3(7, 0, 0))]
        try mesh.addFace(collinear)
        let report = MeshValidator.analyze(mesh)
        XCTAssertEqual(report.issue(.duplicateVertices)?.vertices, [b, d])
        XCTAssertEqual(report.issue(.degenerateFaces)?.count, 1)
        XCTAssertFalse(report.hasNoStructuralErrors)
    }

    func testDetectsInconsistentNormalsAndPinches() throws {
        var (mesh, _) = Fixtures.grid(columns: 2, rows: 1)
        mesh.reverseFaces([mesh.aliveFaces[0]])
        XCTAssertEqual(MeshValidator.analyze(mesh).issue(.inconsistentNormals)?.count, 1)

        var bowtie = Mesh()
        let c = bowtie.addVertex(.zero)
        let v = [Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(-1, 0, 0), Vec3(-1, -1, 0)].map { bowtie.addVertex($0) }
        try bowtie.addFace([c, v[0], v[1]])
        try bowtie.addFace([c, v[2], v[3]])
        XCTAssertEqual(MeshValidator.analyze(bowtie).issue(.nonManifoldVertices)?.vertices, [c])
    }

    func testDetectsHolesIsolatedPartsAndNgons() throws {
        var (mesh, ids) = Fixtures.grid(columns: 3, rows: 3)
        mesh.removeFace(try XCTUnwrap(mesh.findFace(withVertices: [ids[1][1], ids[1][2], ids[2][2], ids[2][1]])))
        let far = [Vec3(9, 9, 9), Vec3(10, 9, 9), Vec3(10, 10, 9), Vec3(9.5, 11, 9), Vec3(9, 10, 9)].map { mesh.addVertex($0) }
        try mesh.addFace(far)
        let report = MeshValidator.analyze(mesh)
        XCTAssertEqual(report.issue(.holes)?.count, 3)
        XCTAssertEqual(report.issue(.isolatedComponents)?.count, 1)
        XCTAssertEqual(report.issue(.ngons)?.count, 1)
    }

    func testDetectsSelfIntersection() throws {
        var mesh = Mesh()
        let a = [Vec3(-1, 0, -1), Vec3(1, 0, -1), Vec3(1, 0, 1), Vec3(-1, 0, 1)].map { mesh.addVertex($0) }
        let b = [Vec3(0, -1, -1), Vec3(0, 1, -1), Vec3(0, 1, 1), Vec3(0, -1, 1)].map { mesh.addVertex($0) }
        try mesh.addFace(a)
        try mesh.addFace(b)
        XCTAssertEqual(MeshValidator.analyze(mesh).issue(.selfIntersections)?.count, 2)

        let (clean, _) = Fixtures.grid(columns: 4, rows: 4)
        XCTAssertNil(MeshValidator.analyze(clean).issue(.selfIntersections))
    }
}
