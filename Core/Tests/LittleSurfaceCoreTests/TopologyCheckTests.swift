import XCTest
import simd
@testable import LittleSurfaceCore

/// Rewrites a saved project without some settings, the way an older version of the app wrote it.
func projectData(_ data: Data, withoutSettings keys: [String]) throws -> Data {
    var out = Data(data.prefix(16))
    var offset = 16
    func int<T: FixedWidthInteger>(_ type: T.Type) -> T {
        defer { offset += MemoryLayout<T>.size }
        return data.subdata(in: offset..<(offset + MemoryLayout<T>.size)).withUnsafeBytes { $0.loadUnaligned(as: T.self) }
    }
    let count = data.subdata(in: 12..<16).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    for _ in 0..<count {
        let tag = data.subdata(in: offset..<(offset + 4))
        offset += 4
        let flags = int(UInt32.self)
        let stored = Int(int(UInt64.self))
        let raw = int(UInt64.self)
        var chunk = data.subdata(in: offset..<(offset + stored))
        offset += stored
        guard String(decoding: tag, as: UTF8.self) == "META" else {
            out.append(tag)
            withUnsafeBytes(of: flags) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt64(stored)) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: raw) { out.append(contentsOf: $0) }
            out.append(chunk)
            continue
        }
        if flags & 1 != 0 { chunk = try (chunk as NSData).decompressed(using: .lzfse) as Data }
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: chunk) as? [String: Any])
        for key in keys {
            XCTAssertNotNil(json[key], "the file should have held \(key) to begin with")
            json[key] = nil
        }
        let rewritten = try JSONSerialization.data(withJSONObject: json)
        out.append(tag)
        withUnsafeBytes(of: UInt32(0)) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(rewritten.count)) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(rewritten.count)) { out.append(contentsOf: $0) }
        out.append(rewritten)
    }
    return out
}

final class TopologyCheckTests: XCTestCase {
    /// A closed cube made of six quads: every corner has three edges.
    private func cube() throws -> Mesh {
        var mesh = Mesh()
        var v: [VertexID] = []
        for x in [Float(-1), 1] {
            for y in [Float(-1), 1] {
                for z in [Float(-1), 1] { v.append(mesh.addVertex(Vec3(x, y, z))) }
            }
        }
        for loop in [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]] {
            try mesh.addFace(loop.map { v[$0] })
        }
        return mesh
    }

    func testTrianglesCountEveryFaceAsItWouldBeTriangulated() throws {
        var mesh = Mesh()
        let v = (0..<5).map { i in mesh.addVertex(Vec3(cos(Float(i)), sin(Float(i)), 0)) }
        try mesh.addFace([v[0], v[1], v[2]])
        XCTAssertEqual(MeshStatistics(mesh).triangleEquivalent, 1)
        var quad = Mesh()
        let q = (0..<4).map { quad.addVertex(Vec3(Float($0 % 2), Float($0 / 2), 0)) }
        try quad.addFace([q[0], q[1], q[3], q[2]])
        XCTAssertEqual(MeshStatistics(quad).triangleEquivalent, 2)
        var ngon = Mesh()
        let n = (0..<6).map { i in ngon.addVertex(Vec3(cos(Float(i)), sin(Float(i)), 0)) }
        try ngon.addFace(n)
        XCTAssertEqual(MeshStatistics(ngon).triangleEquivalent, 4)
    }

    func testPoleCountsOnlyVerticesSurroundedByFaces() throws {
        XCTAssertEqual(MeshValidator.poles(try cube()).count, 8, "three edges at every corner")
        let (grid, rows) = Fixtures.grid(columns: 4, rows: 4)
        XCTAssertEqual(MeshValidator.poles(grid), [], "boundary vertices and four-edge vertices aren't poles")
        XCTAssertEqual(grid.edgesOf(rows[2][2]).count, 4)
        var wire = Mesh()
        let a = wire.addVertex(.zero), b = wire.addVertex(Vec3(1, 0, 0))
        _ = try wire.ensureEdge(a, b)
        XCTAssertEqual(MeshValidator.poles(wire), [], "a loose edge says nothing about edge flow")
    }

    func testPolesAreReportedButNotAsAnError() throws {
        let report = MeshValidator.analyze(try cube())
        XCTAssertEqual(report.issue(.poles)?.count, 8)
        XCTAssertTrue(report.hasNoStructuralErrors, "a few poles are normal and needed")
    }

    private func engine(with mesh: Mesh) -> RetopoEngine {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.perform("seed") { target, _ in try target.append(mesh) }
        return engine
    }

    func testJumpSelectsEachInTurnAndComesBackRound() throws {
        let engine = engine(with: try cube())
        var seen: [Set<VertexID>] = []
        for step in 1...8 {
            let at = try XCTUnwrap(engine.jump(to: .poles))
            XCTAssertEqual(at.position, step)
            XCTAssertEqual(at.count, 8)
            XCTAssertEqual(engine.selection.mode, .vertex)
            XCTAssertEqual(engine.selection.vertices.count, 1)
            seen.append(engine.selection.vertices)
        }
        XCTAssertEqual(Set(seen.flatMap { $0 }).count, 8, "every one was visited")
        XCTAssertEqual(try XCTUnwrap(engine.jump(to: .poles)).position, 1)
        XCTAssertEqual(engine.selection.vertices, seen[0])
    }

    func testJumpTurnsTheViewToFaceWhatItFound() throws {
        // A face on the far side of a model, which framing alone would leave hidden.
        var mesh = Mesh()
        let z: Float = -1
        let v = [Vec3(-0.1, -0.1, z), Vec3(0.1, -0.1, z), Vec3(0, 0.1, z)].map { mesh.addVertex($0) }
        // Wound to face away from the front camera.
        try mesh.addFace([v[0], v[2], v[1]], autoOrient: false)
        let engine = engine(with: mesh)
        let f = engine.mesh.aliveFaces[0]
        XCTAssertLessThan(simd_dot(engine.camera.eye - engine.mesh.faceCenter(f), engine.mesh.faceNormal(f)), 0, "it starts out facing away")
        engine.jump(to: .triangles)
        XCTAssertEqual(engine.selection.faces, [f])
        XCTAssertEqual(simd_dot(simd_normalize(engine.camera.eye - engine.mesh.faceCenter(f)), engine.mesh.faceNormal(f)), 1, accuracy: 1e-3)
        XCTAssertEqual(simd_length(engine.camera.up - Vec3(0, 1, 0)), 0, accuracy: 0.01, "the model stays upright")
    }

    func testJumpLeavesTheMeshAndUndoAlone() throws {
        let engine = engine(with: try cube())
        let positions = engine.mesh.positions
        let depth = engine.history.undoStack.count
        let generation = engine.editGeneration
        engine.jump(to: .poles)
        XCTAssertEqual(engine.mesh.positions, positions)
        XCTAssertEqual(engine.history.undoStack.count, depth)
        XCTAssertEqual(engine.editGeneration, generation)
        XCTAssertEqual(engine.activeTool, .select)
    }

    func testNothingToFindDoesNothing() throws {
        let engine = engine(with: try cube())
        let selection = engine.selection
        XCTAssertNil(engine.jump(to: .triangles))
        XCTAssertNil(engine.jump(to: .ngons))
        XCTAssertNil(engine.jump(to: .badGeometry, report: nil), "not known yet")
        XCTAssertEqual(engine.selection, selection)
    }

    func testBadGeometryComesFromErrorsInTheReportOnly() throws {
        var mesh = Mesh()
        let v = (0..<4).map { mesh.addVertex(Vec3(Float($0 % 2), Float($0 / 2), 0)) }
        try mesh.addFace([v[0], v[1], v[2]], autoOrient: false)
        // Same shared edge, wound the same way: the neighbours disagree about which side is out.
        try mesh.addFace([v[1], v[2], v[3]], autoOrient: false)
        let engine = engine(with: mesh)
        let report = MeshValidator.analyze(engine.mesh)
        XCTAssertNotNil(report.issue(.inconsistentNormals))
        XCTAssertNotNil(report.issue(.holes), "an open edge isn't an error, so it shouldn't be listed")
        let spots = engine.spots(of: .badGeometry, report: report)
        XCTAssertEqual(spots.count, report.issues.filter(\.kind.isError).reduce(0) { $0 + $1.faces.count + $1.edges.count + $1.vertices.count })
        XCTAssertFalse(spots.isEmpty)
        XCTAssertNotNil(engine.jump(to: .badGeometry, report: report))
        XCTAssertFalse(engine.selection.isEmpty)
    }

    func testAfterAnEditJumpingStillLandsOnSomethingThatExists() throws {
        let engine = engine(with: try cube())
        for _ in 0..<7 { engine.jump(to: .poles) }
        engine.deleteSelection()
        let at = try XCTUnwrap(engine.jump(to: .poles))
        XCTAssertLessThanOrEqual(at.position, at.count)
        XCTAssertTrue(engine.selection.vertices.allSatisfy(engine.mesh.isVertexAlive))
    }

    func testBudgetSavesWithTheProjectAndOldProjectsStillOpen() throws {
        let engine = RetopoEngine()
        XCTAssertNil(engine.polyBudget)
        engine.setPolyBudget(5000)
        let data = try ProjectCodec.encode(engine.makeSnapshot())
        XCTAssertEqual(RetopoEngine(snapshot: try ProjectCodec.decode(data)).polyBudget, 5000)
        let old = try projectData(data, withoutSettings: ["polyBudget"])
        XCTAssertNil(try ProjectCodec.decode(old).polyBudget)
        engine.setPolyBudget(nil)
        XCTAssertNil(engine.polyBudget)
    }
}
