import XCTest
import simd
@testable import LittleSurfaceCore

final class SelectionTests: XCTestCase {
    func testEdgeLoopFollowsStraightThroughQuads() throws {
        let (mesh, ids) = Fixtures.grid(columns: 4, rows: 4)
        let middle = try XCTUnwrap(mesh.edge(between: ids[2][1], ids[2][2]))
        let loop = SelectionTools.edgeLoop(from: middle, in: mesh)
        // Across the full width: four edges on row 2.
        XCTAssertEqual(loop.count, 4)
        for e in loop {
            let (a, b) = mesh.ends(e)
            XCTAssertEqual(mesh.position(a).y, 2)
            XCTAssertEqual(mesh.position(b).y, 2)
        }
    }

    func testEdgeRingCrossesQuads() throws {
        let (mesh, ids) = Fixtures.grid(columns: 4, rows: 4)
        let middle = try XCTUnwrap(mesh.edge(between: ids[2][1], ids[2][2]))
        let ring = SelectionTools.edgeRing(from: middle, in: mesh)
        // Five parallel edges in column 1.
        XCTAssertEqual(ring.count, 5)
        for e in ring { XCTAssertEqual(mesh.edgeMidpoint(e).x, 1.5, accuracy: 1e-5) }
    }

    func testBoundaryAndConnected() throws {
        var (mesh, ids) = Fixtures.grid(columns: 2, rows: 2)
        XCTAssertEqual(SelectionTools.boundaryEdges(in: mesh).count, 8)
        let island = mesh.addVertex(Vec3(9, 9, 9))
        let connected = SelectionTools.connectedVertices(from: [ids[0][0]], in: mesh)
        XCTAssertEqual(connected.count, 9)
        XCTAssertFalse(connected.contains(island))
    }

    func testPickerRespectsOcclusion() throws {
        let sphere = Fixtures.sphere()
        let projector = Fixtures.projector(sphere)
        var mesh = Mesh()
        let front = mesh.addVertex(Vec3(0, 0, 1))
        _ = mesh.addVertex(Vec3(0, 0, -1))
        let camera = Fixtures.frontCamera()
        let center = Vec2(500, 500)

        var picker = MeshPicker(camera: camera, mesh: mesh, projector: projector)
        XCTAssertEqual(picker.pickVertex(at: center, radius: 20), front)

        var backOnly = Mesh()
        _ = backOnly.addVertex(Vec3(0, 0, -1))
        picker = MeshPicker(camera: camera, mesh: backOnly, projector: projector)
        XCTAssertNil(picker.pickVertex(at: center, radius: 20), "a vertex behind the surface isn't pickable")

        picker.ignoresOcclusion = true
        XCTAssertNotNil(picker.pickVertex(at: center, radius: 20), "x-ray can pick through the surface")

    }

    func testPickFaceAndEdge() throws {
        let plane = Fixtures.plane(z: -0.01)
        let projector = Fixtures.projector(plane)
        var (mesh, _) = Fixtures.grid(columns: 2, rows: 2, spacing: 0.5)
        // Center the grid on the origin.
        for v in mesh.aliveVertices { mesh.setPosition(v, mesh.position(v) - Vec3(0.5, 0.5, 0)) }
        let camera = Fixtures.frontCamera()
        let picker = MeshPicker(camera: camera, mesh: mesh, projector: projector)
        let quarter = try XCTUnwrap(camera.project(Vec3(0.25, 0.25, 0))?.screen)
        let f = try XCTUnwrap(picker.pickFace(at: quarter))
        XCTAssertEqual(mesh.faceCenter(f).x, 0.25, accuracy: 1e-4)
        let onEdge = try XCTUnwrap(camera.project(Vec3(0.25, 0, 0))?.screen)
        let (e, _) = try XCTUnwrap(picker.pickEdge(at: onEdge, radius: 10))
        XCTAssertEqual(mesh.edgeMidpoint(e).y, 0, accuracy: 1e-4)
    }

    func testLassoSelectsInside() throws {
        let camera = Fixtures.frontCamera()
        var (mesh, _) = Fixtures.grid(columns: 2, rows: 2, spacing: 0.5)
        for v in mesh.aliveVertices { mesh.setPosition(v, mesh.position(v) - Vec3(0.5, 0.5, 0)) }
        var picker = MeshPicker(camera: camera, mesh: mesh, projector: nil)
        picker.ignoresOcclusion = true
        let ring = [Vec2(0, 0), Vec2(500, 0), Vec2(500, 1000), Vec2(0, 1000)].map { $0 + Vec2(-1, 0) }
        let inside = picker.select(inside: ring, mode: .vertex)
        XCTAssertEqual(inside.vertices.count, 3, "only the left column")
    }
}
