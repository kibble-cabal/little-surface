import XCTest
import simd
@testable import LittleSurfaceCore

final class OBJTests: XCTestCase {
    func testQuadsSurviveRoundTrip() throws {
        let (mesh, _) = Fixtures.grid(columns: 3, rows: 2)
        let data = OBJExporter.export(mesh: mesh, name: "Grid")
        let text = String(decoding: data, as: UTF8.self)
        let document = try OBJImporter.parse(data: data)
        XCTAssertEqual(document.positions.count, 12)
        XCTAssertEqual(document.objects.count, 1)
        XCTAssertEqual(document.objects[0].name, "Grid")
        XCTAssertEqual(document.objects[0].faceCount, 6)
        for f in 0..<6 {
            XCTAssertEqual(document.objects[0].faceStarts[f + 1] - document.objects[0].faceStarts[f], 4, "stays a quad")
        }
        XCTAssertTrue(text.contains("f 1//1 2//2"))
        // Every position comes back exactly.
        let original = Set(mesh.aliveVertices.map { mesh.position($0) })
        XCTAssertEqual(Set(document.positions), original)
    }

    func testWindingSurvivesRoundTrip() throws {
        let (mesh, _) = Fixtures.grid(columns: 2, rows: 2)
        let document = try OBJImporter.parse(data: OBJExporter.export(mesh: mesh, name: "Grid"))
        let object = document.objects[0]
        for f in 0..<object.faceCount {
            let range = Int(object.faceStarts[f])..<Int(object.faceStarts[f + 1])
            let n = GeometryMath.newellNormal(range.map { document.positions[Int(object.faceVertices[$0])] })
            XCTAssertGreaterThan(n.z, 0)
        }
    }

    func testCompactionHandlesDeletedSlots() throws {
        var (mesh, _) = Fixtures.grid(columns: 3, rows: 3)
        mesh.deleteFaces(Set(mesh.aliveFaces.prefix(4)))
        let document = try OBJImporter.parse(data: OBJExporter.export(mesh: mesh, name: "Grid"))
        XCTAssertEqual(document.positions.count, mesh.vertexCount)
        XCTAssertEqual(document.objects[0].faceCount, mesh.faceCount)
        for v in document.objects[0].faceVertices { XCTAssertLessThan(Int(v), document.positions.count) }
    }

    func testLooseEdgesAreWrittenAsLines() throws {
        var mesh = Mesh()
        let a = mesh.addVertex(.zero), b = mesh.addVertex(Vec3(1, 0, 0))
        try mesh.ensureEdge(a, b)
        let document = try OBJImporter.parse(data: OBJExporter.export(mesh: mesh, name: "Wire"))
        XCTAssertEqual(document.objects[0].lines.count, 1)
    }

    func testIncludingSourceAddsASeparateObject() throws {
        let (mesh, _) = Fixtures.grid(columns: 1, rows: 1)
        let source = Fixtures.sphere(rings: 6, segments: 8)
        var options = ExportOptions()
        options.includeSource = true
        let document = try OBJImporter.parse(data: OBJExporter.export(mesh: mesh, name: "Retopo", sources: [source], options: options))
        XCTAssertEqual(document.objects.map(\.name), ["Retopo", "Sphere"])
        XCTAssertEqual(document.objects[1].faceCount, source.triangleCount)
        XCTAssertEqual(document.positions.count, 4 + source.positions.count)
        // The second object's indices point at its own vertices.
        for v in document.objects[1].faceVertices { XCTAssertGreaterThanOrEqual(v, 4) }
    }

    func testImporterHandlesRealWorldForms() throws {
        let text = """
        # comment\r
        mtllib thing.mtl\r
        o First\r
        v 0 0 0\r
        v 1.0e0 0 0 1\r
        v 1 1 0\r
        v 0 1 0\r
        vt 0 0\r
        vn 0 0 1\r
        usemtl a\r
        f 1/1/1 2/1/1 3/1/1 4/1/1\r
        o Second\r
        v 5 0 0\r
        v 6 0 0\r
        v 6 1 0\r
        f -3 -2 -1\r

        """
        let model = try OBJImporter.load(data: Data(text.utf8), name: "t")
        XCTAssertEqual(model.objects.map(\.name), ["First", "Second"])
        XCTAssertEqual(model.objects[0].triangleCount, 2, "the quad is triangulated for display")
        XCTAssertEqual(model.objects[1].triangleCount, 1)
        XCTAssertEqual(model.objects[0].normals[0], Vec3(0, 0, 1))
        XCTAssertEqual(model.objects[1].positions[0], Vec3(5, 0, 0))
    }

    func testGroupsActAsObjectsOnlyWithoutO() throws {
        let text = "v 0 0 0\nv 1 0 0\nv 1 1 0\ng one\nf 1 2 3\ng two\nf 3 2 1\n"
        let model = try OBJImporter.load(data: Data(text.utf8), name: "t")
        XCTAssertEqual(model.objects.map(\.name), ["one", "two"])
    }

    func testBadIndexIsReported() throws {
        let text = "v 0 0 0\nf 1 2 3\n"
        XCTAssertThrowsError(try OBJImporter.load(data: Data(text.utf8), name: "t")) { error in
            XCTAssertTrue(error.localizedDescription.contains("line 2"), error.localizedDescription)
        }
    }

    func testGarbageHasNoGeometry() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).obj")
        try Data("hello there\nthis is not a model\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try ModelImporter.load(url: url)) { error in
            XCTAssertEqual(error as? ImportError, .noGeometry)
        }
    }

    func testUnsupportedExtensionIsExplained() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).fbx")
        try Data([1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try ModelImporter.load(url: url)) { error in
            XCTAssertEqual(error as? ImportError, .unsupportedFormat("fbx"))
        }
    }

    func testMissingNormalsAreComputedPointingOut() throws {
        let text = "v 0 0 0\nv 1 0 0\nv 1 1 0\nf 1 2 3\n"
        let model = try OBJImporter.load(data: Data(text.utf8), name: "t")
        XCTAssertEqual(model.objects[0].normals[0], Vec3(0, 0, 1))
    }
}

final class GLBTests: XCTestCase {
    private func topologyCheck(_ data: Data, expectTriangles: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let model = try GLTFImporter.loadGLB(data: data, name: "t")
        XCTAssertEqual(model.triangleCount, expectTriangles, file: file, line: line)
    }

    func testTriangulatedExportRoundTrip() throws {
        let (mesh, _) = Fixtures.grid(columns: 3, rows: 2)
        let data = GLBExporter.export(mesh: mesh, name: "Grid")
        XCTAssertEqual(data.count % 4, 0)
        let model = try GLTFImporter.loadGLB(data: data, name: "t")
        XCTAssertEqual(model.objects.count, 1)
        XCTAssertEqual(model.objects[0].name, "Grid")
        XCTAssertEqual(model.objects[0].triangleCount, 12, "two triangles per quad")
        XCTAssertEqual(model.objects[0].positions.count, 12)
        XCTAssertEqual(Set(model.objects[0].positions), Set(mesh.aliveVertices.map { mesh.position($0) }))
        // Normals and winding both point +Z.
        for n in model.objects[0].normals { XCTAssertEqual(n.z, 1, accuracy: 1e-5) }
        let o = model.objects[0]
        var i = 0
        while i < o.indices.count {
            let a = o.positions[Int(o.indices[i])], b = o.positions[Int(o.indices[i + 1])], c = o.positions[Int(o.indices[i + 2])]
            XCTAssertGreaterThan(simd_cross(b - a, c - a).z, 0)
            i += 3
        }
    }

    func testExportDoesNotChangeEditableTopology() throws {
        let (mesh, _) = Fixtures.grid(columns: 2, rows: 2)
        let before = mesh.faceLoops
        _ = GLBExporter.export(mesh: mesh, name: "Grid")
        XCTAssertEqual(mesh.faceLoops, before)
        XCTAssertEqual(MeshStatistics(mesh).quads, 4)
    }

    func testNgonsTriangulateCompletely() throws {
        var mesh = Mesh()
        // A concave L-shape: naive fans fail on this one.
        let outline = [Vec3(0, 0, 0), Vec3(2, 0, 0), Vec3(2, 1, 0), Vec3(1, 1, 0), Vec3(1, 2, 0), Vec3(0, 2, 0)]
        try mesh.addFace(outline.map { mesh.addVertex($0) })
        let model = try GLTFImporter.loadGLB(data: GLBExporter.export(mesh: mesh, name: "L"), name: "t")
        let o = model.objects[0]
        XCTAssertEqual(o.triangleCount, 4)
        var area: Float = 0
        var i = 0
        while i < o.indices.count {
            let a = o.positions[Int(o.indices[i])], b = o.positions[Int(o.indices[i + 1])], c = o.positions[Int(o.indices[i + 2])]
            let z = simd_cross(b - a, c - a).z
            XCTAssertGreaterThan(z, 0, "no flipped triangles")
            area += z * 0.5
            i += 3
        }
        XCTAssertEqual(area, 3, accuracy: 1e-4)
    }

    func testConcaveQuadSplitsOnTheInsideDiagonal() throws {
        let t = Triangulation.triangulate([Vec3(0, 0, 0), Vec3(2, 0, 0), Vec3(0.3, 0.3, 0), Vec3(0, 2, 0)])
        XCTAssertEqual(t.count, 2)
        let points = [Vec3(0, 0, 0), Vec3(2, 0, 0), Vec3(0.3, 0.3, 0), Vec3(0, 2, 0)]
        for tri in t {
            XCTAssertGreaterThan(simd_cross(points[Int(tri.y)] - points[Int(tri.x)], points[Int(tri.z)] - points[Int(tri.x)]).z, 0)
        }
    }

    func testIncludingSourceAddsANode() throws {
        let (mesh, _) = Fixtures.grid(columns: 1, rows: 1)
        let source = Fixtures.sphere(rings: 6, segments: 8)
        var options = ExportOptions()
        options.includeSource = true
        let model = try GLTFImporter.loadGLB(data: GLBExporter.export(mesh: mesh, name: "Retopo", sources: [source], options: options), name: "t")
        XCTAssertEqual(model.objects.map(\.name), ["Retopo", "Sphere"])
        XCTAssertEqual(model.objects[1].triangleCount, source.triangleCount)
    }

    func testWireOnlyMeshExportsAValidEmptyScene() throws {
        var mesh = Mesh()
        let a = mesh.addVertex(.zero), b = mesh.addVertex(Vec3(1, 0, 0))
        try mesh.ensureEdge(a, b)
        let model = try GLTFImporter.loadGLB(data: GLBExporter.export(mesh: mesh, name: "Wire"), name: "t")
        XCTAssertEqual(model.triangleCount, 0)
    }

    // MARK: Reading glTF written by other tools

    private func glb(json: [String: Any], bin: Data) throws -> Data {
        var jsonData = try JSONSerialization.data(withJSONObject: json)
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }
        var binData = bin
        while binData.count % 4 != 0 { binData.append(0) }
        var out = Data()
        func put(_ v: UInt32) { withUnsafeBytes(of: v) { out.append(contentsOf: $0) } }
        put(0x46546C67)
        put(2)
        put(UInt32(12 + 8 + jsonData.count + 8 + binData.count))
        put(UInt32(jsonData.count))
        put(0x4E4F534A)
        out.append(jsonData)
        put(UInt32(binData.count))
        put(0x004E4942)
        out.append(binData)
        return out
    }

    private func triangleBuffer() -> (Data, [[String: Any]], [[String: Any]]) {
        var bin = Data()
        let floats: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
        floats.withUnsafeBytes { bin.append(contentsOf: $0) }
        let indices: [UInt16] = [0, 1, 2]
        indices.withUnsafeBytes { bin.append(contentsOf: $0) }
        let views: [[String: Any]] = [["buffer": 0, "byteOffset": 0, "byteLength": 36], ["buffer": 0, "byteOffset": 36, "byteLength": 6]]
        let accessors: [[String: Any]] = [
            ["bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"],
            ["bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"],
        ]
        return (bin, views, accessors)
    }

    func testNodeHierarchyAndTransforms() throws {
        let (bin, views, accessors) = triangleBuffer()
        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [
                ["name": "Parent", "translation": [10, 0, 0], "children": [1]],
                ["name": "Child", "scale": [2, 2, 2], "rotation": [0, 0, 0.70710678, 0.70710678], "mesh": 0],
            ],
            "meshes": [["name": "M", "primitives": [["attributes": ["POSITION": 0], "indices": 1]]]],
            "bufferViews": views,
            "accessors": accessors,
            "buffers": [["byteLength": bin.count]],
        ]
        let model = try GLTFImporter.loadGLB(data: try glb(json: json, bin: bin), name: "t")
        XCTAssertEqual(model.objects.count, 1)
        XCTAssertEqual(model.objects[0].name, "Child")
        let p = model.objects[0].positions
        // (1,0,0) scaled by 2, rotated 90° about Z, then moved +10 X.
        XCTAssertLessThan(simd_length(p[1] - Vec3(10, 2, 0)), 1e-4)
        XCTAssertLessThan(simd_length(p[0] - Vec3(10, 0, 0)), 1e-4)
    }

    func testMirrorTransformFixesWinding() throws {
        let (bin, views, accessors) = triangleBuffer()
        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "scenes": [["nodes": [0]]],
            "nodes": [["scale": [-1, 1, 1], "mesh": 0]],
            "meshes": [["primitives": [["attributes": ["POSITION": 0], "indices": 1]]]],
            "bufferViews": views, "accessors": accessors, "buffers": [["byteLength": bin.count]],
        ]
        let o = try GLTFImporter.loadGLB(data: try glb(json: json, bin: bin), name: "t").objects[0]
        let a = o.positions[Int(o.indices[0])], b = o.positions[Int(o.indices[1])], c = o.positions[Int(o.indices[2])]
        XCTAssertGreaterThan(simd_cross(b - a, c - a).z, 0, "still faces +Z after mirroring")
    }

    func testMultipleMeshesBecomeSeparateObjects() throws {
        let (bin, views, accessors) = triangleBuffer()
        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "scenes": [["nodes": [0, 1]]],
            "nodes": [["name": "A", "mesh": 0], ["name": "B", "mesh": 0, "translation": [5, 0, 0]]],
            "meshes": [["primitives": [["attributes": ["POSITION": 0], "indices": 1]]]],
            "bufferViews": views, "accessors": accessors, "buffers": [["byteLength": bin.count]],
        ]
        let model = try GLTFImporter.loadGLB(data: try glb(json: json, bin: bin), name: "t")
        XCTAssertEqual(model.objects.map(\.name), ["A", "B"])
        XCTAssertEqual(model.objects[1].positions[0].x, 5)
    }

    func testStrideInterleavedAndNormalizedShorts() throws {
        // Interleaved: 3 shorts of position (quantized) + 2 bytes padding, with a stride of 8.
        var bin = Data()
        let vertices: [[Int16]] = [[0, 0, 0], [32767, 0, 0], [0, 32767, 0]]
        for v in vertices {
            v.withUnsafeBytes { bin.append(contentsOf: $0) }
            bin.append(contentsOf: [0, 0])
        }
        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "extensionsUsed": ["KHR_mesh_quantization"],
            "extensionsRequired": ["KHR_mesh_quantization"],
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "meshes": [["primitives": [["attributes": ["POSITION": 0]]]]],
            "bufferViews": [["buffer": 0, "byteLength": 24, "byteStride": 8]],
            "accessors": [["bufferView": 0, "componentType": 5122, "normalized": true, "count": 3, "type": "VEC3"]],
            "buffers": [["byteLength": bin.count]],
        ]
        let o = try GLTFImporter.loadGLB(data: try glb(json: json, bin: bin), name: "t").objects[0]
        XCTAssertLessThan(simd_length(o.positions[1] - Vec3(1, 0, 0)), 1e-4)
        XCTAssertEqual(o.triangleCount, 1, "non-indexed geometry gets its implicit indices")
    }

    func testTriangleStripsAndFans() throws {
        var bin = Data()
        let floats: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0]
        floats.withUnsafeBytes { bin.append(contentsOf: $0) }
        for mode in [5, 6] {
            let json: [String: Any] = [
                "asset": ["version": "2.0"],
                "scenes": [["nodes": [0]]],
                "nodes": [["mesh": 0]],
                "meshes": [["primitives": [["attributes": ["POSITION": 0], "mode": mode]]]],
                "bufferViews": [["buffer": 0, "byteLength": 48]],
                "accessors": [["bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3"]],
                "buffers": [["byteLength": 48]],
            ]
            let o = try GLTFImporter.loadGLB(data: try glb(json: json, bin: bin), name: "t").objects[0]
            XCTAssertEqual(o.triangleCount, 2, "mode \(mode)")
        }
    }

    func testEmbeddedDataURI() throws {
        let (bin, views, accessors) = triangleBuffer()
        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "meshes": [["primitives": [["attributes": ["POSITION": 0], "indices": 1]]]],
            "bufferViews": views, "accessors": accessors,
            "buffers": [["byteLength": bin.count, "uri": "data:application/octet-stream;base64," + bin.base64EncodedString()]],
        ]
        let model = try GLTFImporter.loadGLTF(json: try JSONSerialization.data(withJSONObject: json), name: "t", baseURL: nil)
        XCTAssertEqual(model.triangleCount, 1)
    }

    func testExternalBufferLoadsOrExplains() throws {
        let (bin, views, accessors) = triangleBuffer()
        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "meshes": [["primitives": [["attributes": ["POSITION": 0], "indices": 1]]]],
            "bufferViews": views, "accessors": accessors,
            "buffers": [["byteLength": bin.count, "uri": "model%20data.bin"]],
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: json)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try GLTFImporter.loadGLTF(json: jsonData, name: "t", baseURL: dir)) { error in
            XCTAssertEqual(error as? ImportError, .missingExternalFile("model data.bin"))
        }
        try bin.write(to: dir.appendingPathComponent("model data.bin"))
        XCTAssertEqual(try GLTFImporter.loadGLTF(json: jsonData, name: "t", baseURL: dir).triangleCount, 1)
    }

    func testDracoIsExplained() throws {
        let json: [String: Any] = ["asset": ["version": "2.0"], "extensionsRequired": ["KHR_draco_mesh_compression"]]
        XCTAssertThrowsError(try GLTFImporter.loadGLTF(json: try JSONSerialization.data(withJSONObject: json), name: "t", baseURL: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Draco"))
        }
    }

    func testTruncatedAndCorruptFilesFailCleanly() throws {
        XCTAssertThrowsError(try GLTFImporter.loadGLB(data: Data([1, 2, 3]), name: "t"))
        XCTAssertThrowsError(try GLTFImporter.loadGLB(data: Data(repeating: 0, count: 64), name: "t"))
        let good = GLBExporter.export(mesh: Fixtures.grid(columns: 1, rows: 1).mesh, name: "x")
        XCTAssertThrowsError(try GLTFImporter.loadGLB(data: good.prefix(good.count - 20), name: "t"))
        XCTAssertThrowsError(try GLTFImporter.loadGLTF(json: Data("{not json".utf8), name: "t", baseURL: nil))

        // An accessor that claims more data than the buffer holds.
        let (bin, views, _) = triangleBuffer()
        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "meshes": [["primitives": [["attributes": ["POSITION": 0]]]]],
            "bufferViews": views,
            "accessors": [["bufferView": 0, "componentType": 5126, "count": 99999, "type": "VEC3"]],
            "buffers": [["byteLength": bin.count]],
        ]
        XCTAssertThrowsError(try GLTFImporter.loadGLB(data: try glb(json: json, bin: bin), name: "t"))
    }
}

final class ProjectFileTests: XCTestCase {
    private func sampleEngine() -> RetopoEngine {
        let engine = Fixtures.engine(with: Fixtures.sphere(rings: 16, segments: 24), camera: Fixtures.frontCamera())
        engine.name = "My Character"
        engine.setSymmetryEnabled(true)
        engine.setSymmetryPlane(axis: .y, offset: 0.25)
        engine.setSymmetryPlane(axis: .x, offset: 0)
        engine.viewport.displayMode = .xray
        engine.viewport.sourceOpacity = 0.4
        engine.tools.strip.width = 0.77
        engine.camera.orbit(deltaPoints: Vec2(20, 10))
        engine.setTool(.quadPatch)
        engine.perform("seed") { mesh, selection in
            var (grid, _) = Fixtures.grid(columns: 3, rows: 3, spacing: 0.1)
            grid.deleteFaces(Set(grid.aliveFaces.prefix(2)))
            mesh = grid
            selection.mode = .face
            selection.faces = Set(grid.aliveFaces.prefix(3))
        }
        return engine
    }

    func testRoundTripPreservesEverythingNeededToResume() throws {
        let engine = sampleEngine()
        let snapshot = engine.makeSnapshot()
        let data = try ProjectCodec.encode(snapshot)
        let back = try ProjectCodec.decode(data)

        XCTAssertEqual(back.name, "My Character")
        XCTAssertEqual(back.mesh.positions, snapshot.mesh.positions)
        XCTAssertEqual(back.mesh.faceLoops, snapshot.mesh.faceLoops)
        XCTAssertEqual(back.mesh.faceEdgeLoops, snapshot.mesh.faceEdgeLoops)
        XCTAssertEqual(back.mesh.edgeEnds, snapshot.mesh.edgeEnds)
        XCTAssertEqual(back.mesh.edgeAlive, snapshot.mesh.edgeAlive)
        XCTAssertEqual(back.mesh.vertexAlive, snapshot.mesh.vertexAlive)
        XCTAssertEqual(back.mesh.mirrorPartner, snapshot.mesh.mirrorPartner)
        XCTAssertEqual(back.selection, snapshot.selection)
        XCTAssertEqual(back.symmetry, snapshot.symmetry)
        XCTAssertEqual(back.viewport, snapshot.viewport)
        XCTAssertEqual(back.tools, snapshot.tools)
        XCTAssertEqual(back.activeTool, .quadPatch)
        XCTAssertEqual(back.camera, snapshot.camera)
        XCTAssertEqual(back.sources.count, 1)
        XCTAssertEqual(back.sources[0].id, snapshot.sources[0].id)
        XCTAssertEqual(back.sources[0].positions, snapshot.sources[0].positions)
        XCTAssertEqual(back.sources[0].indices, snapshot.sources[0].indices)
        assertValid(back.mesh)
    }

    func testReopenedMeshIsFullyEditable() throws {
        let engine = sampleEngine()
        let back = try ProjectCodec.decode(try ProjectCodec.encode(engine.makeSnapshot()))
        let reopened = RetopoEngine(snapshot: back)
        reopened.installLoadedBVHs(RetopoEngine.buildBVHs(for: back.sources))
        XCTAssertTrue(reopened.hasSurface)
        let faces = reopened.mesh.faceCount
        reopened.deleteSelection()
        XCTAssertLessThan(reopened.mesh.faceCount, faces)
        // Freed slots get reused cleanly after reload.
        reopened.perform("add") { mesh, _ in
            let v = (0..<3).map { mesh.addVertex(Vec3(Float($0), 5, 0)) }
            try mesh.addFace(v)
        }
        assertValid(reopened.mesh)
        reopened.undo()
        reopened.undo()
        XCTAssertEqual(reopened.mesh.faceCount, faces)
    }

    func testFileIsSmallerThanRawThanksToCompression() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere())
        let data = try ProjectCodec.encode(engine.makeSnapshot())
        let raw = engine.sources[0].positions.count * 32 + engine.sources[0].indices.count * 4
        XCTAssertLessThan(data.count, raw)
    }

    func testRejectsForeignFiles() throws {
        XCTAssertThrowsError(try ProjectCodec.decode(Data("hello".utf8))) { XCTAssertEqual($0 as? ProjectFileError, .notAProject) }
        XCTAssertThrowsError(try ProjectCodec.decode(Data(repeating: 7, count: 100))) { XCTAssertEqual($0 as? ProjectFileError, .notAProject) }
    }

    func testRefusesNewerVersionWithExplanation() throws {
        var data = try ProjectCodec.encode(ProjectSnapshot(name: "x"))
        var future: UInt32 = 99
        withUnsafeBytes(of: &future) { data.replaceSubrange(8..<12, with: $0) }
        XCTAssertThrowsError(try ProjectCodec.decode(data)) { XCTAssertEqual($0 as? ProjectFileError, .newerVersion(99)) }
    }

    func testDetectsTruncation() throws {
        let data = try ProjectCodec.encode(sampleEngine().makeSnapshot())
        for cut in [20, data.count / 2, data.count - 1] {
            XCTAssertThrowsError(try ProjectCodec.decode(data.prefix(cut)), "cut at \(cut)")
        }
    }

    func testSkipsUnknownChunksFromFutureVersions() throws {
        var data = try ProjectCodec.encode(ProjectSnapshot(name: "x"))
        // Append a chunk this version doesn't know about, and bump the count.
        var count: UInt32 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) } + 1
        withUnsafeBytes(of: &count) { data.replaceSubrange(12..<16, with: $0) }
        data.append(Data("XTRA".utf8))
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
        put(UInt32(0))
        put(UInt64(3))
        put(UInt64(3))
        data.append(contentsOf: [1, 2, 3])
        XCTAssertEqual(try ProjectCodec.decode(data).name, "x")
    }

    func testDetectsCorruptMesh() throws {
        var snapshot = ProjectSnapshot(name: "x")
        snapshot.mesh = Fixtures.grid(columns: 1, rows: 1).mesh
        snapshot.mesh.edgeEnds[0] = SIMD2<Int32>(0, 0)
        XCTAssertThrowsError(try ProjectCodec.decode(try ProjectCodec.encode(snapshot)))
    }
}
