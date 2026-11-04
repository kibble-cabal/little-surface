import XCTest
import simd
@testable import LittleSurfaceCore

/// The acceptance workflow from the brief, run through the same engine API the app's input layer
/// calls, with screen-space Pencil samples. Only the UIKit event delivery and Metal drawing are absent.
final class WorkflowTests: XCTestCase {
    func testAcceptanceWorkflow() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 2. Import a detailed model from a real file on disk.
        let detailed = Fixtures.sphere(rings: 200, segments: 300)
        XCTAssertGreaterThan(detailed.triangleCount, 100_000)
        let modelURL = dir.appendingPathComponent("detailed.glb")
        var exportSource = ExportOptions()
        exportSource.includeSource = true
        try GLBExporter.export(mesh: Mesh(), name: "", sources: [detailed], options: exportSource).write(to: modelURL)
        let imported = try ModelImporter.load(url: modelURL)
        XCTAssertEqual(imported.objects.count, 1)
        let engine = RetopoEngine(name: "Workflow")
        engine.camera.viewSize = Vec2(1000, 1000)
        engine.addSources(imported.objects, bvhs: RetopoEngine.buildBVHs(for: imported.objects))
        XCTAssertTrue(engine.hasSurface)

        // 3. Rotate and inspect it, returning to a useful angle.
        engine.camera.orbit(deltaPoints: Vec2(200, 80))
        engine.camera.zoom(factor: 1.2, focus: Vec2(500, 500))
        engine.camera.setPreset(.front)
        engine.frameAll()

        func screen(_ p: Vec3) -> Vec2 { engine.camera.project(p)!.screen }

        // 4. Draw two edge-flow paths.
        engine.setTool(.drawEdges)
        engine.tools.stroke.edgeLength = 0.12
        let onSphere: (Float, Float) -> Vec3 = { x, y in Vec3(x, y, sqrt(1 - x * x - y * y)) }
        Fixtures.draw(engine, from: screen(onSphere(-0.55, 0.3)), to: screen(onSphere(0.55, 0.3)), bend: Vec2(0, -8))
        XCTAssertNil(engine.pendingStroke)
        let afterFirst = engine.mesh.vertexCount
        Fixtures.draw(engine, from: screen(onSphere(-0.55, -0.3)), to: screen(onSphere(0.55, -0.3)), bend: Vec2(0, 8))
        XCTAssertGreaterThan(engine.mesh.vertexCount, afterFirst)
        XCTAssertEqual(engine.mesh.faceCount, 0)
        XCTAssertEqual(MeshValidator.connectedComponents(engine.mesh).count, 2)

        // 5. Generate connecting quads.
        engine.setTool(.quadPatch)
        engine.patchTap(at: screen(onSphere(0, 0.31)))
        engine.patchTap(at: screen(onSphere(0, -0.31)))
        XCTAssertEqual(engine.patchChains.count, 2)
        engine.tools.patch.rows = 4
        engine.updatePatchPreview()
        let preview = try XCTUnwrap(engine.patchPreview, engine.patchError ?? "no preview")
        XCTAssertEqual(preview.rows, 4)
        XCTAssertEqual(engine.mesh.faceCount, 0, "the preview doesn't commit anything")
        engine.commitPatch()
        let stats = engine.statistics
        XCTAssertEqual(stats.faces, preview.columns * 4)
        XCTAssertEqual(stats.quads, stats.faces)
        XCTAssertEqual(stats.components, 1)
        assertValid(engine.mesh)
        assertConsistentWinding(engine.mesh)

        // 6. Modify individual vertices.
        engine.setTool(.select)
        engine.setSelectionMode(.vertex)
        engine.clearSelection()
        let interior = try XCTUnwrap(engine.mesh.aliveVertices.first { !engine.mesh.isBoundaryVertex($0) })
        let oldPosition = engine.mesh.position(interior)
        let from = screen(oldPosition)
        Fixtures.draw(engine, from: from, to: from + Vec2(12, -9), steps: 6)
        let newPosition = engine.mesh.position(interior)
        XCTAssertGreaterThan(simd_length(newPosition - oldPosition), 1e-3)
        XCTAssertEqual(simd_length(newPosition), 1 + engine.tools.surfaceOffset, accuracy: 0.01, "stays on the surface")
        engine.undo()
        XCTAssertEqual(engine.mesh.position(interior), oldPosition)
        engine.redo()
        XCTAssertEqual(engine.mesh.position(interior), newPosition)

        // 7. Add and delete faces.
        let facesBefore = engine.mesh.faceCount
        engine.setTool(.face)
        for corner in [Vec2(0.6, 0.0), Vec2(0.75, 0.0), Vec2(0.75, 0.15), Vec2(0.6, 0.15)] {
            engine.faceToolTap(at: screen(onSphere(corner.x, corner.y)))
        }
        XCTAssertEqual(engine.mesh.faceCount, facesBefore + 1, "the fourth corner completes a quad")
        let added = try XCTUnwrap(engine.selection.faces.first)
        XCTAssertGreaterThan(simd_dot(engine.mesh.faceNormal(added), engine.mesh.faceCenter(added)), 0)
        engine.setTool(.select)
        engine.deleteSelection()
        XCTAssertEqual(engine.mesh.faceCount, facesBefore)
        assertValid(engine.mesh)

        // 8. Enable symmetry, and draw on it.
        engine.setSymmetryEnabled(true)
        engine.setTool(.drawEdges)
        let verticesBefore = engine.mesh.vertexCount
        Fixtures.draw(engine, from: screen(onSphere(0.35, 0.62)), to: screen(onSphere(0.6, 0.62)))
        XCTAssertGreaterThanOrEqual(engine.mesh.vertexCount, verticesBefore + 4, "the stroke and its mirror image")
        assertValid(engine.mesh)

        // 9. Preview subdivision without touching the base mesh.
        let base = engine.mesh
        engine.viewport.subdivisionPreview = true
        engine.viewport.subdivisionLevels = 2
        let smooth = try CatmullClark.preview(engine.mesh, levels: 2)
        XCTAssertEqual(smooth.levels, 2)
        XCTAssertGreaterThan(smooth.mesh.faceCount, engine.mesh.faceCount * 10)
        XCTAssertEqual(engine.mesh.faceLoops, base.faceLoops)

        // 10. Save the project.
        let saved = dir.appendingPathComponent("Workflow.littlesurface")
        try ProjectCodec.encode(engine.makeSnapshot()).write(to: saved)

        // 11. Reopen it.
        let snapshot = try ProjectCodec.decode(try Data(contentsOf: saved))
        let reopened = RetopoEngine(snapshot: snapshot)
        reopened.camera.viewSize = engine.camera.viewSize
        reopened.installLoadedBVHs(RetopoEngine.buildBVHs(for: snapshot.sources))
        XCTAssertEqual(reopened.mesh.faceLoops, engine.mesh.faceLoops)
        XCTAssertEqual(reopened.mesh.positions, engine.mesh.positions)
        XCTAssertEqual(reopened.symmetry, engine.symmetry)
        XCTAssertEqual(reopened.activeTool, .drawEdges)
        XCTAssertTrue(reopened.viewport.subdivisionPreview)
        XCTAssertTrue(reopened.hasSurface)
        let reopenedFaces = reopened.mesh.faceCount

        // 12. Export the retopology mesh.
        let objData = reopened.exportData(format: .obj, options: ExportOptions())
        let glbData = reopened.exportData(format: .glb, options: ExportOptions())

        // tools/verify_export.sh opens these in Blender, trimesh and the glTF validator.
        if let folder = ProcessInfo.processInfo.environment["LS_EXPORT_DIR"] {
            let out = URL(fileURLWithPath: folder)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try objData.write(to: out.appendingPathComponent("workflow.obj"))
            try glbData.write(to: out.appendingPathComponent("workflow.glb"))
            var withSource = ExportOptions()
            withSource.includeSource = true
            try reopened.exportData(format: .obj, options: withSource).write(to: out.appendingPathComponent("workflow_with_source.obj"))
            try reopened.exportData(format: .glb, options: withSource).write(to: out.appendingPathComponent("workflow_with_source.glb"))
            let stats = reopened.statistics
            let expected = "{\"vertices\": \(stats.vertices), \"edges\": \(stats.edges), \"faces\": \(stats.faces), \"quads\": \(stats.quads), \"triangles\": \(stats.triangles), \"ngons\": \(stats.ngons)}"
            try Data(expected.utf8).write(to: out.appendingPathComponent("workflow.expected.json"))
        }

        // 13. Verify the exported mesh's geometry and connectivity.
        let document = try OBJImporter.parse(data: objData)
        XCTAssertEqual(document.objects.count, 1)
        XCTAssertEqual(document.positions.count, reopened.mesh.vertexCount)
        let object = document.objects[0]
        XCTAssertEqual(object.faceCount, reopenedFaces)
        var rebuilt = Mesh()
        for p in document.positions { rebuilt.addVertex(p) }
        for f in 0..<object.faceCount {
            let range = Int(object.faceStarts[f])..<Int(object.faceStarts[f + 1])
            XCTAssertEqual(range.count, 4, "quads stay quads in OBJ")
            try rebuilt.addFace(range.map { object.faceVertices[$0] }, autoOrient: false)
        }
        XCTAssertEqual(MeshStatistics(rebuilt).quads, reopenedFaces)
        assertValid(rebuilt)
        assertConsistentWinding(rebuilt)
        for f in rebuilt.aliveFaces {
            XCTAssertGreaterThan(simd_dot(rebuilt.faceNormal(f), rebuilt.faceCenter(f)), 0, "faces point out of the model")
        }

        let glb = try GLTFImporter.loadGLB(data: glbData, name: "t")
        XCTAssertEqual(glb.objects.count, 1)
        XCTAssertEqual(glb.objects[0].triangleCount, reopenedFaces * 2)
        var i = 0
        let tri = glb.objects[0]
        while i < tri.indices.count {
            let a = tri.positions[Int(tri.indices[i])], b = tri.positions[Int(tri.indices[i + 1])], c = tri.positions[Int(tri.indices[i + 2])]
            XCTAssertGreaterThan(simd_dot(simd_cross(b - a, c - a), a + b + c), 0)
            i += 3
        }
    }
}
