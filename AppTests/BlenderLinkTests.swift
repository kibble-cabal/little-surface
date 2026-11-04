import LittleSurfaceCore
import XCTest
@testable import LittleSurface

final class BlenderLinkServerTests: XCTestCase {
    private var server: BlenderLinkServer?

    override func tearDown() {
        server?.stop()
        server = nil
    }

    private func start(port: UInt16, handler: @escaping (LinkRequest) async -> LinkResponse = { _ in .message("hello") }) throws {
        let server = BlenderLinkServer(code: "123456", port: port, handler: handler)
        let ready = expectation(description: "listening")
        ready.assertForOverFulfill = false
        server.onStateChange = { state in
            if case .listening = state { ready.fulfill() }
        }
        server.start()
        self.server = server
        wait(for: [ready], timeout: 10)
    }

    private func call(_ path: String, port: UInt16, code: String? = "123456", method: String = "GET", body: Data? = nil) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)")))
        request.httpMethod = method
        request.httpBody = body
        if let code { request.setValue(code, forHTTPHeaderField: "X-Little-Surface-Code") }
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return (try XCTUnwrap(response as? HTTPURLResponse).statusCode, data)
    }

    func testTheRightCodeGetsAnAnswerOverARealSocket() async throws {
        try start(port: 48711)
        let answer = try await call("/status", port: 48711)
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: answer.data) as? [String: String], ["message": "hello"])
    }

    func testNoCodeOrTheWrongOneReachesNothing() async throws {
        let reached = expectation(description: "handler")
        reached.isInverted = true
        try start(port: 48712) { _ in
            reached.fulfill()
            return .message("in")
        }
        let none = try await call("/status", port: 48712, code: nil)
        XCTAssertEqual(none.status, 401)
        let wrong = try await call("/status", port: 48712, code: "000000")
        XCTAssertEqual(wrong.status, 401)
        await fulfillment(of: [reached], timeout: 0.5)
    }

    func testGuessingTurnsTheLinkOff() async throws {
        try start(port: 48713)
        let stopped = expectation(description: "gave up")
        stopped.assertForOverFulfill = false
        server?.onStateChange = { state in
            if case .failed = state { stopped.fulfill() }
        }
        for _ in 0..<BlenderLinkServer.wrongCodeLimit {
            _ = try await call("/status", port: 48713, code: "000000")
        }
        await fulfillment(of: [stopped], timeout: 5)
        do {
            _ = try await call("/status", port: 48713)
            XCTFail("it should no longer answer")
        } catch {}
    }

    func testALargeBodyArrivesWhole() async throws {
        let body = Data((0..<(6 * 1024 * 1024)).map { UInt8($0 % 251) })
        try start(port: 48714) { request in
            .json(["count": request.body.count, "matches": request.body == body])
        }
        let answer = try await call("/sculpt", port: 48714, method: "POST", body: body)
        let reply = try XCTUnwrap(try JSONSerialization.jsonObject(with: answer.data) as? [String: Any])
        XCTAssertEqual(reply["count"] as? Int, body.count)
        XCTAssertEqual(reply["matches"] as? Bool, true)
    }

    func testTheCodeIsSixDigitsAndKept() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let code = BlenderLinkServer.savedCode(in: defaults)
        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.allSatisfy(\.isNumber))
        XCTAssertEqual(BlenderLinkServer.savedCode(in: defaults), code)
    }
}

@MainActor
final class BlenderLinkModelTests: XCTestCase {
    private let quad = Data("o Quad\nv 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\n".utf8)
    private let sculptOBJ = Data("""
    o Ball
    v -1 -1 1
    v 1 -1 1
    v 1 1 1
    v -1 1 1
    v -1 -1 -1
    v 1 -1 -1
    v 1 1 -1
    v -1 1 -1
    f 1 2 3 4
    f 8 7 6 5
    f 1 4 8 5
    f 2 6 7 3
    f 4 3 7 8
    f 1 5 6 2

    """.utf8)

    private func openEditor() async throws -> EditorModel {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Project.littlesurface")
        let snapshot = ProjectSnapshot(name: "Linked")
        let document = ProjectDocument(fileURL: url)
        document.snapshotProvider = { snapshot }
        let created = expectation(description: "created")
        document.save(to: url, for: .forCreating) { ok in
            XCTAssertTrue(ok)
            created.fulfill()
        }
        await fulfillment(of: [created], timeout: 10)
        return EditorModel(document: document, snapshot: snapshot)
    }

    private func post(_ model: EditorModel, _ path: String, _ query: [String: String], _ body: Data) async -> LinkResponse {
        await model.handleLinkRequest(LinkRequest(method: "POST", path: path, query: query, body: body))
    }

    func testAMeshFromBlenderArrivesWithItsQuadsAndUndoes() async throws {
        let model = try await openEditor()
        let answer = await post(model, "/mesh", ["name": "Quad"], quad)
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(model.engine.statistics.quads, 1)
        let again = await post(model, "/mesh", ["name": "Quad"], quad)
        XCTAssertEqual(again.status, 200)
        XCTAssertEqual(model.engine.statistics.quads, 2, "adds by default")
        let replaced = await post(model, "/mesh", ["name": "Quad", "replace": "1"], quad)
        XCTAssertEqual(replaced.status, 200)
        XCTAssertEqual(model.engine.statistics.quads, 1, "asked to replace")
        model.engine.undo()
        XCTAssertEqual(model.engine.statistics.quads, 2)
    }

    func testASculptAddsThenUpdatesTheOneWithItsName() async throws {
        let model = try await openEditor()
        let first = await post(model, "/sculpt", ["name": "Ball"], sculptOBJ)
        XCTAssertEqual(first.status, 200, String(decoding: first.body, as: UTF8.self))
        XCTAssertEqual(model.engine.sources.map(\.name), ["Ball"])
        let id = model.engine.sources[0].id
        let second = await post(model, "/sculpt", ["name": "Ball"], sculptOBJ)
        XCTAssertEqual(second.status, 200)
        XCTAssertEqual(model.engine.sources.count, 1, "the same name updates it")
        XCTAssertEqual(model.engine.sources[0].id, id)
        let other = await post(model, "/sculpt", ["name": "Other"], sculptOBJ)
        XCTAssertEqual(other.status, 200)
        XCTAssertEqual(model.engine.sources.map(\.name), ["Ball", "Other"])
    }

    func testAFileThatCannotBeReadSaysWhy() async throws {
        let model = try await openEditor()
        let answer = await post(model, "/mesh", ["name": "Bad"], Data("this is not an obj".utf8))
        XCTAssertEqual(answer.status, 422)
        let reply = try XCTUnwrap(try JSONSerialization.jsonObject(with: answer.body) as? [String: String])
        XCTAssertFalse(try XCTUnwrap(reply["message"]).isEmpty)
        XCTAssertEqual(model.engine.mesh.vertexCount, 0)
    }

    func testAnEmptyBodyIsRefused() async throws {
        let model = try await openEditor()
        let answer = await post(model, "/mesh", [:], Data())
        XCTAssertEqual(answer.status, 400)
    }

    func testWhileBusyItAsksToTryAgainAndTakesNothing() async throws {
        let model = try await openEditor()
        model.busy = BusyTask(title: "Something", cancellable: false)
        let answer = await post(model, "/mesh", ["name": "Quad"], quad)
        XCTAssertEqual(answer.status, 409)
        XCTAssertEqual(model.engine.mesh.vertexCount, 0)
    }

    func testBlenderCanFetchTheMeshAndItReadsBackTheSame() async throws {
        let model = try await openEditor()
        let empty = await model.handleLinkRequest(LinkRequest(method: "GET", path: "/mesh"))
        XCTAssertEqual(empty.status, 204)
        _ = await post(model, "/mesh", ["name": "Quad"], quad)
        let answer = await model.handleLinkRequest(LinkRequest(method: "GET", path: "/mesh"))
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(answer.headers["X-Little-Surface-Name"], "Linked")
        let back = try MeshImporter.build(try OBJImporter.parse(data: answer.body), name: "Back")
        XCTAssertEqual(back.mesh.faceCount, 1)
        XCTAssertEqual(back.mesh.vertexCount, 4)
    }

    func testAMeshSentFromTheIPadWaitsForBlenderAndGoesOnce() async throws {
        let model = try await openEditor()
        _ = await post(model, "/mesh", ["name": "Quad"], quad)
        let before = await model.handleLinkRequest(LinkRequest(method: "GET", path: "/outbox"))
        XCTAssertEqual(before.status, 204, "nothing was sent yet")
        model.sendMeshToBlender()
        var answer = LinkResponse(status: 204)
        for _ in 0..<100 where answer.status == 204 {
            try await Task.sleep(nanoseconds: 50_000_000)
            answer = await model.handleLinkRequest(LinkRequest(method: "GET", path: "/outbox"))
        }
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(try MeshImporter.build(try OBJImporter.parse(data: answer.body), name: "Back").mesh.faceCount, 1)
        let after = await model.handleLinkRequest(LinkRequest(method: "GET", path: "/outbox"))
        XCTAssertEqual(after.status, 204)
    }

    func testStatusSaysWhatIsOpen() async throws {
        let model = try await openEditor()
        _ = await post(model, "/mesh", ["name": "Quad"], quad)
        let answer = await model.handleLinkRequest(LinkRequest(method: "GET", path: "/status"))
        let reply = try XCTUnwrap(try JSONSerialization.jsonObject(with: answer.body) as? [String: Any])
        XCTAssertEqual(reply["project"] as? String, "Linked")
        XCTAssertEqual(reply["faces"] as? Int, 1)
    }

    func testUnknownRequestsAreRefused() async throws {
        let model = try await openEditor()
        let answer = await model.handleLinkRequest(LinkRequest(method: "DELETE", path: "/everything"))
        XCTAssertEqual(answer.status, 404)
    }

    func testTurningTheLinkOnAndOff() async throws {
        let model = try await openEditor()
        XCTAssertFalse(model.linkIsOn, "off until asked for")
        model.setBlenderLink(true)
        XCTAssertTrue(model.linkIsOn)
        for _ in 0..<100 where model.linkStatus != "Waiting for Blender." {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(model.linkStatus, "Waiting for Blender.")
        model.blenderLinkSceneChanged(isActive: false)
        XCTAssertTrue(model.linkIsOn, "it remembers, for when the app comes back")
        model.setBlenderLink(false)
        XCTAssertFalse(model.linkIsOn)
    }
}
