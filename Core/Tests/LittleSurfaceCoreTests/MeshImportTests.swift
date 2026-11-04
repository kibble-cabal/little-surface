import XCTest
import simd
@testable import LittleSurfaceCore

final class MeshImportTests: XCTestCase {
    private func document(_ text: String) throws -> OBJDocument {
        try OBJImporter.parse(data: Data(text.utf8))
    }

    private let mixed = """
    o Mixed
    v 0 0 0
    v 1 0 0
    v 2 0 0
    v 0 1 0
    v 1 1 0
    v 2 1 0
    v 1 2 0
    v 3 0 0
    v 3 1 0
    v 4 0 0
    v 4 1 0
    v 3.5 2 0
    v 5 5 0
    v 6 5 0
    f 1 2 5 4
    f 2 3 6 5
    f 4 5 7
    f 8 10 11 12 9
    l 13 14
    """

    func testQuadsTrianglesNgonsAndLooseEdgesAllSurvive() throws {
        let imported = try MeshImporter.build(document(mixed), name: "Mixed")
        let stats = MeshValidator.analyze(imported.mesh).statistics
        XCTAssertEqual(stats.quads, 2)
        XCTAssertEqual(stats.triangles, 1)
        XCTAssertEqual(stats.ngons, 1)
        XCTAssertEqual(imported.mesh.aliveEdges.filter(imported.mesh.isWire).count, 1)
        XCTAssertEqual(imported.skippedFaces, 0)
        assertValid(imported.mesh)
    }

    func testRoundTripThroughExportKeepsEveryCount() throws {
        let first = try MeshImporter.build(document(mixed), name: "Mixed")
        let text = OBJExporter.export(mesh: first.mesh, name: "Mixed", sources: [], options: ExportOptions())
        let second = try MeshImporter.build(OBJImporter.parse(data: text), name: "Mixed")
        XCTAssertEqual(second.mesh.vertexCount, first.mesh.vertexCount)
        XCTAssertEqual(second.mesh.edgeCount, first.mesh.edgeCount)
        XCTAssertEqual(second.mesh.faceCount, first.mesh.faceCount)
        XCTAssertEqual(MeshValidator.analyze(second.mesh).statistics.quads, 2)
    }

    func testKeepsTheFilesWindingAsStated() throws {
        let imported = try MeshImporter.build(document("v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\n"), name: "A")
        let flipped = try MeshImporter.build(document("v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 4 3 2 1\n"), name: "B")
        XCTAssertEqual(imported.mesh.faceNormal(0).z, 1, accuracy: 1e-5)
        XCTAssertEqual(flipped.mesh.faceNormal(0).z, -1, accuracy: 1e-5)
    }

    func testAThirdFaceOnAnEdgeIsSkippedAndCountedNotFatal() throws {
        let text = """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        v 0 -1 0
        v 0 0 1
        f 1 2 3
        f 2 1 4
        f 1 2 5
        """
        let imported = try MeshImporter.build(document(text), name: "Fin")
        XCTAssertEqual(imported.mesh.faceCount, 2)
        XCTAssertEqual(imported.skippedFaces, 1)
        XCTAssertEqual(imported.mesh.vertexCount, 4, "the skipped face's corner isn't left floating")
        assertValid(imported.mesh)
    }

    func testRepeatedCornerIsSkipped() throws {
        let imported = try MeshImporter.build(document("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\nf 1 1 2\n"), name: "R")
        XCTAssertEqual(imported.mesh.faceCount, 1)
        XCTAssertEqual(imported.skippedFaces, 1)
    }

    func testPointsSplitAlongSeamsAreWelded() throws {
        // Two triangles sharing an edge, each with its own copy of it, as glTF does along a seam.
        let text = "v 0 0 0\nv 1 0 0\nv 0 1 0\nv 1 0 0\nv 0 1 0\nv 1 1 0\nf 1 2 3\nf 4 6 5\n"
        let imported = try MeshImporter.build(document(text), name: "Seam")
        XCTAssertEqual(imported.mesh.vertexCount, 4)
        XCTAssertEqual(imported.mesh.edgeCount, 5)
        XCTAssertEqual(imported.weldedVertices, 2)
        XCTAssertFalse(MeshValidator.analyze(imported.mesh).issues.contains { $0.kind == .nonManifoldEdges })
    }

    func testUnusedPointsAreLeftOut() throws {
        let imported = try MeshImporter.build(document("v 9 9 9\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 2 3 4\n"), name: "U")
        XCTAssertEqual(imported.mesh.vertexCount, 3)
    }

    func testSeveralObjectsBecomeSeparatePartsOfOneMesh() throws {
        let text = "o A\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\no B\nv 5 0 0\nv 6 0 0\nv 5 1 0\nf 4 5 6\n"
        let imported = try MeshImporter.build(document(text), name: "Parts")
        XCTAssertEqual(MeshValidator.analyze(imported.mesh).statistics.components, 2)
    }

    func testAnEmptyFileExplainsItself() {
        XCTAssertThrowsError(try MeshImporter.build(document("# nothing\n"), name: "Empty")) { error in
            XCTAssertEqual(error as? ImportError, .noGeometry)
        }
    }

    func testASculptSizedFileSaysToImportItAsAModel() throws {
        var big = OBJDocument()
        big.positions = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)]
        var object = OBJDocument.Object(name: "Big")
        for _ in 0...MeshImporter.faceLimit {
            object.faceVertices += [0, 1, 2]
            object.faceStarts.append(Int32(object.faceVertices.count))
        }
        big.objects = [object]
        XCTAssertThrowsError(try MeshImporter.build(big, name: "Big")) { error in
            XCTAssertTrue(error.localizedDescription.contains("sculpt"))
        }
    }

    func testOpeningIntoAProjectIsOneUndoAndEveryToolThenWorksOnIt() throws {
        let imported = try MeshImporter.build(document(mixed), name: "Mixed")
        let engine = RetopoEngine()
        let surfaceObject = imported.mesh.asSurface(named: "Mixed (copy)")
        let bvh = try XCTUnwrap(TriangleBVH(object: surfaceObject))
        XCTAssertTrue(engine.addEditableMesh(imported, surface: (surfaceObject, bvh)))
        XCTAssertEqual(engine.mesh.faceCount, 4)
        XCTAssertEqual(engine.sources.count, 1, "there's something to draw on")
        XCTAssertFalse(engine.tools.surfaceSnapping, "moving a vertex can change the mesh's shape")
        XCTAssertNotNil(engine.projector)
        engine.undo()
        XCTAssertEqual(engine.mesh.faceCount, 0)
        engine.redo()
        XCTAssertEqual(engine.mesh.faceCount, 4)
        engine.selectAll()
        engine.deleteSelection()
        assertValid(engine.mesh)
    }

    func testOpeningIntoAProjectWithASculptKeepsThatSurfaceAndExistingTopology() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(420, 380), to: Vec2(600, 380))
        let existing = engine.mesh.vertexCount
        let imported = try MeshImporter.build(document(mixed), name: "Mixed")
        XCTAssertTrue(engine.addEditableMesh(imported, surface: nil))
        XCTAssertEqual(engine.sources.count, 1)
        XCTAssertTrue(engine.tools.surfaceSnapping)
        XCTAssertEqual(engine.mesh.vertexCount, existing + imported.mesh.vertexCount)
        assertValid(engine.mesh)
    }

    func testSurfaceCopyMatchesTheMesh() throws {
        let imported = try MeshImporter.build(document(mixed), name: "Mixed")
        let surface = imported.mesh.asSurface(named: "Copy")
        // Two quads, a triangle and a pentagon.
        XCTAssertEqual(surface.triangleCount, 2 * 2 + 1 + 3)
    }
}
