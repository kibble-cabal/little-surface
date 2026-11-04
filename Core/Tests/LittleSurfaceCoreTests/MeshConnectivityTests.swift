import XCTest
import simd
@testable import LittleSurfaceCore

final class MeshConnectivityTests: XCTestCase {
    func testAddFaceCreatesEdgesAndIncidence() throws {
        var mesh = Mesh()
        let v = (0..<4).map { mesh.addVertex(Vec3(Float($0), 0, 0)) }
        let f = try mesh.addFace(v)
        XCTAssertEqual(mesh.edgeCount, 4)
        XCTAssertEqual(mesh.faceCount, 1)
        XCTAssertEqual(mesh.loop(f), v)
        for e in mesh.aliveEdges { XCTAssertTrue(mesh.isBoundary(e)) }
        assertValid(mesh)
    }

    func testSharedEdgeHasBothFaces() throws {
        let (mesh, ids) = Fixtures.grid(columns: 2, rows: 1)
        let shared = try XCTUnwrap(mesh.edge(between: ids[0][1], ids[1][1]))
        XCTAssertEqual(mesh.faceCountOf(edge: shared), 2)
        XCTAssertEqual(mesh.edgeCount, 7)
        assertValid(mesh)
        assertConsistentWinding(mesh)
    }

    func testAddFaceRefusesAThirdFaceOnAnEdge() throws {
        var (mesh, ids) = Fixtures.grid(columns: 2, rows: 1)
        let shared = (ids[0][1], ids[1][1])
        let extra = mesh.addVertex(Vec3(1, 0.5, 1))
        XCTAssertThrowsError(try mesh.addFace([shared.0, shared.1, extra])) { error in
            XCTAssertEqual(error as? MeshError, .nonManifoldEdge)
        }
        XCTAssertEqual(mesh.faceCount, 2)
        assertValid(mesh)
    }

    func testAddFaceRejectsRepeatsAndDuplicates() throws {
        var mesh = Mesh()
        let v = (0..<4).map { mesh.addVertex(Vec3(Float($0), Float($0 % 2), 0)) }
        XCTAssertThrowsError(try mesh.addFace([v[0], v[1]])) { XCTAssertEqual($0 as? MeshError, .tooFewVertices) }
        XCTAssertThrowsError(try mesh.addFace([v[0], v[1], v[0]])) { XCTAssertEqual($0 as? MeshError, .repeatedVertex) }
        try mesh.addFace(v)
        XCTAssertThrowsError(try mesh.addFace(Array(v.reversed()))) { XCTAssertEqual($0 as? MeshError, .duplicateFace) }
        assertValid(mesh)
    }

    func testAutoOrientFlipsToMatchNeighbour() throws {
        var (mesh, ids) = Fixtures.grid(columns: 1, rows: 1)
        let a = mesh.addVertex(Vec3(2, 0, 0)), b = mesh.addVertex(Vec3(2, 1, 0))
        // Stated with the same direction along the shared edge as the existing face.
        try mesh.addFace([ids[0][1], ids[1][1], b, a].reversed().reversed())
        assertConsistentWinding(mesh)
        assertValid(mesh)
    }

    func testRemoveFaceLeavesEdges() throws {
        var (mesh, _) = Fixtures.grid(columns: 2, rows: 2)
        let f = mesh.aliveFaces[0]
        mesh.removeFace(f)
        XCTAssertEqual(mesh.faceCount, 3)
        XCTAssertEqual(mesh.edgeCount, 12)
        assertValid(mesh)
    }

    func testRemoveVertexCascades() throws {
        var (mesh, ids) = Fixtures.grid(columns: 2, rows: 2)
        mesh.removeVertex(ids[1][1])
        XCTAssertEqual(mesh.faceCount, 0)
        XCTAssertEqual(mesh.vertexCount, 8)
        XCTAssertEqual(mesh.edgeCount, 8)
        assertValid(mesh)
    }

    func testSlotsAreReused() throws {
        var mesh = Mesh()
        let a = mesh.addVertex(.zero)
        mesh.removeVertex(a)
        let b = mesh.addVertex(Vec3(1, 1, 1))
        XCTAssertEqual(a, b)
        XCTAssertEqual(mesh.position(b), Vec3(1, 1, 1))
        assertValid(mesh)
    }

    // MARK: Edge splitting

    func testSplitWireEdge() throws {
        var mesh = Mesh()
        let a = mesh.addVertex(.zero), b = mesh.addVertex(Vec3(2, 0, 0))
        let e = try mesh.ensureEdge(a, b)
        let split = try mesh.splitEdge(e, at: 0.5)
        XCTAssertEqual(mesh.position(split.vertex), Vec3(1, 0, 0))
        XCTAssertEqual(mesh.edgeCount, 2)
        XCTAssertNotNil(mesh.edge(between: a, split.vertex))
        XCTAssertNotNil(mesh.edge(between: split.vertex, b))
        XCTAssertNil(mesh.edge(between: a, b))
        assertValid(mesh)
    }

    func testSplitInteriorEdgeUpdatesBothFaces() throws {
        var (mesh, ids) = Fixtures.grid(columns: 2, rows: 1)
        let shared = try XCTUnwrap(mesh.edge(between: ids[0][1], ids[1][1]))
        let faces = mesh.facesOf(edge: shared)
        let v = try mesh.splitEdge(shared, at: 0.25).vertex
        for f in faces {
            XCTAssertEqual(mesh.loop(f).count, 5)
            XCTAssertTrue(mesh.loop(f).contains(v))
        }
        XCTAssertEqual(mesh.faceCountOf(edge: try XCTUnwrap(mesh.edge(between: v, ids[1][1]))), 2)
        assertValid(mesh)
        assertConsistentWinding(mesh)
    }

    func testRepeatedSplitsKeepFaceValid() throws {
        var (mesh, ids) = Fixtures.grid(columns: 1, rows: 1)
        var e = try XCTUnwrap(mesh.edge(between: ids[0][0], ids[0][1]))
        for _ in 0..<5 {
            let result = try mesh.splitEdge(e, at: 0.5)
            e = result.newEdge
            assertValid(mesh)
        }
        XCTAssertEqual(mesh.loop(mesh.aliveFaces[0]).count, 9)
    }

    // MARK: Deletion

    func testDeleteFacesRemovesOrphansButKeepsNeighbours() throws {
        var (mesh, _) = Fixtures.grid(columns: 2, rows: 1)
        let f = mesh.aliveFaces[0]
        mesh.deleteFaces([f])
        XCTAssertEqual(mesh.faceCount, 1)
        XCTAssertEqual(mesh.vertexCount, 4)
        XCTAssertEqual(mesh.edgeCount, 4)
        assertValid(mesh)
    }

    func testDeleteFaceKeepingEdges() throws {
        var (mesh, _) = Fixtures.grid(columns: 2, rows: 1)
        mesh.deleteFaces([mesh.aliveFaces[0]], keepEdges: true)
        XCTAssertEqual(mesh.faceCount, 1)
        XCTAssertEqual(mesh.edgeCount, 7)
        assertValid(mesh)
    }

    func testDeleteEdgeRemovesItsFaces() throws {
        var (mesh, ids) = Fixtures.grid(columns: 2, rows: 1)
        let shared = try XCTUnwrap(mesh.edge(between: ids[0][1], ids[1][1]))
        mesh.deleteEdges([shared])
        XCTAssertEqual(mesh.faceCount, 0)
        XCTAssertEqual(mesh.edgeCount, 6)
        assertValid(mesh)
    }

    // MARK: Dissolve

    func testDissolveEdgeMergesFaces() throws {
        var (mesh, ids) = Fixtures.grid(columns: 2, rows: 1)
        let shared = try XCTUnwrap(mesh.edge(between: ids[0][1], ids[1][1]))
        try mesh.dissolveEdge(shared)
        XCTAssertEqual(mesh.faceCount, 1)
        XCTAssertEqual(mesh.loop(mesh.aliveFaces[0]).count, 6)
        XCTAssertEqual(mesh.edgeCount, 6)
        assertValid(mesh)
    }

    func testDissolveBoundaryEdgeIsRefused() throws {
        var (mesh, ids) = Fixtures.grid(columns: 1, rows: 1)
        let e = try XCTUnwrap(mesh.edge(between: ids[0][0], ids[0][1]))
        XCTAssertThrowsError(try mesh.dissolveEdge(e))
        assertValid(mesh)
    }

    func testDissolveInteriorVertexMergesFan() throws {
        var (mesh, ids) = Fixtures.grid(columns: 2, rows: 2)
        try mesh.dissolveVertex(ids[1][1])
        XCTAssertEqual(mesh.faceCount, 1)
        XCTAssertEqual(mesh.loop(mesh.aliveFaces[0]).count, 8)
        XCTAssertEqual(mesh.vertexCount, 8)
        assertValid(mesh)
    }

    func testDissolveValenceTwoVertexOnWire() throws {
        var mesh = Mesh()
        let a = mesh.addVertex(.zero), b = mesh.addVertex(Vec3(1, 0, 0)), c = mesh.addVertex(Vec3(2, 0, 0))
        try mesh.ensureEdge(a, b)
        try mesh.ensureEdge(b, c)
        try mesh.dissolveVertex(b)
        XCTAssertNotNil(mesh.edge(between: a, c))
        XCTAssertEqual(mesh.vertexCount, 2)
        assertValid(mesh)
    }

    func testDissolveVertexOnFaceEdgeRemovesCorner() throws {
        var (mesh, ids) = Fixtures.grid(columns: 1, rows: 1)
        let e = try XCTUnwrap(mesh.edge(between: ids[0][0], ids[0][1]))
        let v = try mesh.splitEdge(e, at: 0.5).vertex
        XCTAssertEqual(mesh.loop(mesh.aliveFaces[0]).count, 5)
        try mesh.dissolveVertex(v)
        XCTAssertEqual(mesh.loop(mesh.aliveFaces[0]).count, 4)
        assertValid(mesh)
    }

    // MARK: Connect

    func testConnectWithinFaceCutsIt() throws {
        var (mesh, ids) = Fixtures.grid(columns: 1, rows: 1)
        try mesh.connectVertices(ids[0][0], ids[1][1])
        XCTAssertEqual(mesh.faceCount, 2)
        for f in mesh.aliveFaces { XCTAssertEqual(mesh.loop(f).count, 3) }
        assertValid(mesh)
        assertConsistentWinding(mesh)
    }

    func testConnectUnrelatedVerticesMakesWire() throws {
        var mesh = Mesh()
        let a = mesh.addVertex(.zero), b = mesh.addVertex(Vec3(1, 0, 0))
        let e = try mesh.connectVertices(a, b)
        XCTAssertTrue(mesh.isWire(e))
        XCTAssertThrowsError(try mesh.connectVertices(a, b))
    }

    // MARK: Welding

    func testWeldJoinsTwoQuads() throws {
        var mesh = Mesh()
        let left = (0..<4).map { i in mesh.addVertex([Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0)][i]) }
        let right = (0..<4).map { i in mesh.addVertex([Vec3(1, 0, 0), Vec3(2, 0, 0), Vec3(2, 1, 0), Vec3(1, 1, 0)][i]) }
        try mesh.addFace(left)
        try mesh.addFace(right)
        try mesh.mergeVertex(right[0], into: left[1])
        try mesh.mergeVertex(right[3], into: left[2])
        XCTAssertEqual(mesh.vertexCount, 6)
        XCTAssertEqual(mesh.edgeCount, 7)
        XCTAssertEqual(mesh.faceCountOf(edge: try XCTUnwrap(mesh.edge(between: left[1], left[2]))), 2)
        assertValid(mesh)
        assertConsistentWinding(mesh)
    }

    func testWeldNeighboursCollapsesAnEdge() throws {
        var (mesh, ids) = Fixtures.grid(columns: 2, rows: 1)
        let keep = try mesh.weld([ids[0][0], ids[0][1]])
        XCTAssertEqual(mesh.vertexCount, 5)
        // One quad lost a corner and is now a triangle.
        let sizes = mesh.aliveFaces.map { mesh.loop($0).count }.sorted()
        XCTAssertEqual(sizes, [3, 4])
        XCTAssertEqual(mesh.position(keep), Vec3(0.5, 0, 0))
        assertValid(mesh)
    }

    func testWeldOppositeCornersOfAQuadIsRefused() throws {
        var (mesh, ids) = Fixtures.grid(columns: 2, rows: 2)
        // These share a quad diagonally, so welding them pinches that quad.
        XCTAssertThrowsError(try mesh.weld([ids[0][0], ids[1][1]]))
    }

    func testWeldRefusesThirdFaceOnEdge() throws {
        var mesh = Mesh()
        // Two triangles share edge a-b; a third triangle's edge c-d lands on a-b when welded.
        let a = mesh.addVertex(.zero), b = mesh.addVertex(Vec3(1, 0, 0))
        let p = mesh.addVertex(Vec3(0, 1, 0)), q = mesh.addVertex(Vec3(0, -1, 0))
        try mesh.addFace([a, b, p])
        try mesh.addFace([b, a, q])
        let c = mesh.addVertex(Vec3(0, 0, 1)), d = mesh.addVertex(Vec3(1, 0, 1)), r = mesh.addVertex(Vec3(0, 0, 2))
        try mesh.addFace([c, d, r])
        var work = mesh
        XCTAssertThrowsError(try {
            try work.mergeVertex(c, into: a)
            try work.mergeVertex(d, into: b)
        }())
    }

    func testWeldByDistanceMergesDuplicates() throws {
        var mesh = Mesh()
        let a = mesh.addVertex(.zero), b = mesh.addVertex(Vec3(1, 0, 0)), c = mesh.addVertex(Vec3(1, 1, 0))
        let d = mesh.addVertex(Vec3(1.0001, 0, 0)), e = mesh.addVertex(Vec3(2, 0, 0)), f = mesh.addVertex(Vec3(1.0001, 1, 0))
        try mesh.addFace([a, b, c])
        try mesh.addFace([d, e, f])
        let merged = try mesh.weldByDistance(0.01)
        XCTAssertEqual(merged, 2)
        XCTAssertEqual(mesh.vertexCount, 4)
        assertValid(mesh)
    }

    // MARK: Flip

    func testFlipBetweenTwoTriangles() throws {
        var mesh = Mesh()
        let a = mesh.addVertex(.zero), b = mesh.addVertex(Vec3(1, 0, 0)), c = mesh.addVertex(Vec3(1, 1, 0)), d = mesh.addVertex(Vec3(0, 1, 0))
        try mesh.addFace([a, b, c])
        try mesh.addFace([a, c, d])
        try mesh.flipEdge(try XCTUnwrap(mesh.edge(between: a, c)))
        XCTAssertNil(mesh.edge(between: a, c))
        XCTAssertNotNil(mesh.edge(between: b, d))
        XCTAssertEqual(mesh.faceCount, 2)
        assertValid(mesh)
        assertConsistentWinding(mesh)
    }

    func testFlipBetweenTwoQuads() throws {
        var (mesh, ids) = Fixtures.grid(columns: 2, rows: 1)
        let shared = try XCTUnwrap(mesh.edge(between: ids[0][1], ids[1][1]))
        try mesh.flipEdge(shared)
        XCTAssertEqual(mesh.faceCount, 2)
        for f in mesh.aliveFaces { XCTAssertEqual(mesh.loop(f).count, 4) }
        assertValid(mesh)
        assertConsistentWinding(mesh)
    }

    func testFlipBoundaryIsRefused() throws {
        var (mesh, ids) = Fixtures.grid(columns: 1, rows: 1)
        XCTAssertThrowsError(try mesh.flipEdge(try XCTUnwrap(mesh.edge(between: ids[0][0], ids[0][1]))))
    }

    // MARK: Extrude and fill

    func testExtrudeBoundaryAddsQuadsFacingTheSameWay() throws {
        var (mesh, ids) = Fixtures.grid(columns: 2, rows: 1)
        let top = Set([try XCTUnwrap(mesh.edge(between: ids[1][0], ids[1][1])), try XCTUnwrap(mesh.edge(between: ids[1][1], ids[1][2]))])
        let newEdges = try mesh.extrudeEdges(top, distance: 1, projector: nil)
        XCTAssertEqual(mesh.faceCount, 4)
        XCTAssertEqual(mesh.vertexCount, 9)
        XCTAssertEqual(newEdges.count, 2)
        for e in newEdges {
            XCTAssertEqual(mesh.position(mesh.ends(e).0).y, 2, accuracy: 1e-5)
        }
        assertValid(mesh)
        assertConsistentWinding(mesh)
    }

    func testExtrudeInteriorEdgeIsRefused() throws {
        var (mesh, ids) = Fixtures.grid(columns: 2, rows: 1)
        let shared = try XCTUnwrap(mesh.edge(between: ids[0][1], ids[1][1]))
        XCTAssertThrowsError(try mesh.extrudeEdges([shared], distance: 1, projector: nil))
    }

    func testFillHoleMatchesWinding() throws {
        var (mesh, ids) = Fixtures.grid(columns: 3, rows: 3)
        let center = try XCTUnwrap(mesh.findFace(withVertices: [ids[1][1], ids[1][2], ids[2][2], ids[2][1]]))
        mesh.removeFace(center)
        XCTAssertEqual(ChainFinder.boundaryLoops(in: mesh).count, 2)
        let hole = try XCTUnwrap(ChainFinder.boundaryLoops(in: mesh).first { $0.segmentCount == 4 })
        try mesh.fill(loop: hole)
        XCTAssertEqual(mesh.faceCount, 9)
        assertValid(mesh)
        assertConsistentWinding(mesh)
    }

    // MARK: Subdivide

    func testSubdivideFacesInGrid() throws {
        var (mesh, _) = Fixtures.grid(columns: 2, rows: 2)
        let all = Set(mesh.aliveFaces)
        let result = try mesh.subdivideFaces(all)
        XCTAssertEqual(mesh.faceCount, 16)
        XCTAssertEqual(mesh.vertexCount, 25)
        XCTAssertEqual(result.faces.count, 16)
        for f in mesh.aliveFaces { XCTAssertEqual(mesh.loop(f).count, 4) }
        assertValid(mesh)
        assertConsistentWinding(mesh)
    }

    func testSubdivideSingleFaceTurnsNeighbourIntoNgon() throws {
        var (mesh, _) = Fixtures.grid(columns: 2, rows: 1)
        let target = mesh.aliveFaces[0]
        let other = mesh.aliveFaces[1]
        try mesh.subdivideFaces([target])
        XCTAssertEqual(mesh.faceCount, 5)
        XCTAssertEqual(mesh.loop(other).count, 5)
        assertValid(mesh)
        assertConsistentWinding(mesh)
    }

    // MARK: Normals

    func testReverseFacesKeepsCornerEdgeCorrespondence() throws {
        var (mesh, _) = Fixtures.grid(columns: 2, rows: 2)
        mesh.reverseFaces([mesh.aliveFaces[0]])
        assertValid(mesh)
        XCTAssertFalse(MeshValidator.analyze(mesh, checkSelfIntersections: false).hasNoStructuralErrors)
    }

    func testRecalculateNormalsRestoresConsistency() throws {
        var (mesh, _) = Fixtures.grid(columns: 3, rows: 3)
        mesh.reverseFaces(Set(mesh.aliveFaces.prefix(3)))
        let flipped = mesh.recalculateNormals()
        XCTAssertGreaterThan(flipped, 0)
        assertValid(mesh)
        assertConsistentWinding(mesh)
    }

    func testRecalculateNormalsFollowsTheSurface() throws {
        let plane = Fixtures.plane()
        let projector = Fixtures.projector(plane)
        var (mesh, _) = Fixtures.grid(columns: 2, rows: 2, spacing: 0.5)
        mesh.reverseFaces(Set(mesh.aliveFaces))
        XCTAssertLessThan(mesh.faceNormal(mesh.aliveFaces[0]).z, 0)
        mesh.recalculateNormals(projector: projector)
        XCTAssertGreaterThan(mesh.faceNormal(mesh.aliveFaces[0]).z, 0)
    }

    func testRecalculateNormalsPointsClosedMeshOutward() throws {
        var mesh = Mesh()
        // An inside-out cube.
        let corners: [Vec3] = [Vec3(-1,-1,-1), Vec3(1,-1,-1), Vec3(1,1,-1), Vec3(-1,1,-1), Vec3(-1,-1,1), Vec3(1,-1,1), Vec3(1,1,1), Vec3(-1,1,1)]
        let v = corners.map { mesh.addVertex($0) }
        let inward: [[Int]] = [[0,1,2,3],[7,6,5,4],[4,5,1,0],[3,2,6,7],[5,6,2,1],[0,3,7,4]]
        for q in inward { try mesh.addFace(q.map { v[$0] }, autoOrient: false) }
        mesh.recalculateNormals()
        for f in mesh.aliveFaces {
            XCTAssertGreaterThan(simd_dot(mesh.faceNormal(f), mesh.faceCenter(f)), 0)
        }
    }
}
