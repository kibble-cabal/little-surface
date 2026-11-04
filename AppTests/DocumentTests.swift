import LittleSurfaceCore
import Metal
import XCTest
@testable import LittleSurface

final class DocumentTests: XCTestCase {
    func testSaveCloseAndReopenThroughUIDocument() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).littlesurface")
        defer { try? FileManager.default.removeItem(at: url) }

        var snapshot = ProjectSnapshot(name: "Round Trip")
        var mesh = Mesh()
        let v = (0..<4).map { mesh.addVertex(Vec3(Float($0 % 2), Float($0 / 2), 0)) }
        try mesh.addFace([v[0], v[1], v[3], v[2]])
        snapshot.mesh = mesh

        let document = ProjectDocument(fileURL: url)
        document.snapshotProvider = { snapshot }
        let saved = expectation(description: "saved")
        document.save(to: url, for: .forCreating) { ok in
            XCTAssertTrue(ok)
            document.close { _ in saved.fulfill() }
        }
        wait(for: [saved], timeout: 10)

        let reopened = ProjectDocument(fileURL: url)
        let opened = expectation(description: "opened")
        reopened.open { ok in
            XCTAssertTrue(ok)
            opened.fulfill()
        }
        wait(for: [opened], timeout: 10)
        let loaded = try XCTUnwrap(reopened.loaded)
        XCTAssertEqual(loaded.name, "Round Trip")
        XCTAssertEqual(loaded.mesh.faceCount, 1)
        XCTAssertEqual(loaded.mesh.positions, mesh.positions)
        let closed = expectation(description: "closed")
        reopened.close { _ in closed.fulfill() }
        wait(for: [closed], timeout: 10)
    }

    func testDamagedFileFailsToOpen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).littlesurface")
        try Data("not a project".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = ProjectDocument(fileURL: url)
        let opened = expectation(description: "opened")
        document.open { ok in
            XCTAssertFalse(ok)
            opened.fulfill()
        }
        wait(for: [opened], timeout: 10)
    }

    func testBundledExampleLoads() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Example", withExtension: "glb"))
        let model = try ModelImporter.load(url: url)
        XCTAssertGreaterThan(model.triangleCount, 50_000)
    }

    func testSafeFileNames() {
        XCTAssertEqual(ProjectLibrary.safeFileName("a/b:c"), "a-b-c")
        XCTAssertEqual(ProjectLibrary.safeFileName("   "), "Untitled")
    }
}

final class RendererTests: XCTestCase {
    func testShadersCompileAndAThumbnailRenders() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(ViewportRenderer(device: device), "shaders must compile")
        let engine = RetopoEngine(name: "Render")
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Example", withExtension: "glb"))
        let model = try ModelImporter.load(url: url)
        engine.addSources(model.objects, bvhs: [:])
        engine.camera.viewSize = Vec2(480, 320)
        engine.frameAll()
        let image = try XCTUnwrap(renderer.thumbnail(engine: engine, size: CGSize(width: 480, height: 320)))
        XCTAssertEqual(image.size.width, 480)
    }
}
