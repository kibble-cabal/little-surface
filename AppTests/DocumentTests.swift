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

    private func openEditor(in folder: URL) throws -> EditorModel {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Project.littlesurface")
        let snapshot = ProjectSnapshot(name: "Autosave")
        let document = ProjectDocument(fileURL: url)
        document.snapshotProvider = { snapshot }
        let created = expectation(description: "created")
        document.save(to: url, for: .forCreating) { ok in
            XCTAssertTrue(ok)
            created.fulfill()
        }
        wait(for: [created], timeout: 10)
        return EditorModel(document: document, snapshot: snapshot)
    }

    private func waitForSaveState(_ model: EditorModel, _ matches: @escaping (EditorModel.SaveState) -> Bool, timeout: TimeInterval) {
        let reached = expectation(description: "save state")
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            if matches(model.saveState) {
                timer.invalidate()
                reached.fulfill()
            }
        }
        wait(for: [reached], timeout: timeout)
        timer.invalidate()
    }

    func testAnEditReachesTheFileWithinSeconds() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try openEditor(in: folder)
        model.engine.perform("Add") { mesh, _ in _ = mesh.addVertex(.zero) }
        XCTAssertEqual(model.saveState, .unsaved)
        waitForSaveState(model, { $0 == .saved }, timeout: 8)
        let onDisk = try ProjectCodec.decode(Data(contentsOf: model.document.fileURL))
        XCTAssertEqual(onDisk.mesh.vertexCount, 1, "nothing but the autosave wrote this")
        let closed = expectation(description: "closed")
        model.close { ok in
            XCTAssertTrue(ok)
            closed.fulfill()
        }
        wait(for: [closed], timeout: 10)
    }

    func testAnEditMadeDuringASaveIsNotCountedAsSaved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try openEditor(in: folder)
        let first = expectation(description: "first save")
        model.engine.perform("Add") { mesh, _ in _ = mesh.addVertex(.zero) }
        model.save { _ in first.fulfill() }
        // Made after that save took its copy.
        model.engine.perform("Add") { mesh, _ in _ = mesh.addVertex(Vec3(1, 0, 0)) }
        wait(for: [first], timeout: 10)
        XCTAssertNotEqual(model.saveState, .saved)
        waitForSaveState(model, { $0 == .saved }, timeout: 8)
        let onDisk = try ProjectCodec.decode(Data(contentsOf: model.document.fileURL))
        XCTAssertEqual(onDisk.mesh.vertexCount, 2)
    }

    func testAFailedSaveIsReportedKeepsTheProjectOpenAndRecovers() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = FileManager.default
        defer {
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? manager.removeItem(at: folder)
        }
        let model = try openEditor(in: folder)
        let url = model.document.fileURL
        let lastGood = try Data(contentsOf: url)
        // Nothing can be written here now, the way a full or revoked location behaves.
        try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)

        model.engine.perform("Add") { mesh, _ in _ = mesh.addVertex(.zero) }
        let refused = expectation(description: "close refused")
        model.close { ok in
            XCTAssertFalse(ok, "closing must not pretend this was saved")
            refused.fulfill()
        }
        wait(for: [refused], timeout: 10)
        guard case .failed = model.saveState else { return XCTFail("expected a failed state, got \(model.saveState)") }
        XCTAssertEqual(try Data(contentsOf: url), lastGood, "the last good copy is untouched")
        XCTAssertEqual(model.engine.mesh.vertexCount, 1, "the work is still in memory")

        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let retried = expectation(description: "saved")
        model.save { ok in
            XCTAssertTrue(ok)
            retried.fulfill()
        }
        wait(for: [retried], timeout: 10)
        XCTAssertEqual(try ProjectCodec.decode(Data(contentsOf: url)).mesh.vertexCount, 1)
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
