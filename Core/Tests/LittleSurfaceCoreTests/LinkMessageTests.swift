import XCTest
@testable import LittleSurfaceCore

final class LinkMessageTests: XCTestCase {
    private func parse(_ text: String) -> LinkRequestParser.Result { LinkRequestParser.parse(Data(text.utf8)) }

    func testAPostWithAQueryAndBody() {
        let result = parse("POST /mesh?name=Head%20Two&replace=1 HTTP/1.1\r\nHost: x\r\nX-Little-Surface-Code: 123456\r\nContent-Length: 5\r\n\r\nhello")
        guard case .complete(let request) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/mesh")
        XCTAssertEqual(request.query, ["name": "Head Two", "replace": "1"])
        XCTAssertEqual(request.headers["x-little-surface-code"], "123456", "names are case-insensitive")
        XCTAssertEqual(request.body, Data("hello".utf8))
    }

    func testAGetWithNoBody() {
        guard case .complete(let request) = parse("GET /status HTTP/1.1\r\n\r\n") else { return XCTFail() }
        XCTAssertEqual(request.path, "/status")
        XCTAssertTrue(request.body.isEmpty)
    }

    func testItWaitsForAllOfARequestHoweverItArrives() {
        let whole = Data("POST /m HTTP/1.1\r\nContent-Length: 4\r\n\r\nabcd".utf8)
        for cut in 0..<whole.count {
            XCTAssertEqual(LinkRequestParser.parse(whole.prefix(cut)), .incomplete, "cut at \(cut)")
        }
        guard case .complete(let request) = LinkRequestParser.parse(whole) else { return XCTFail() }
        XCTAssertEqual(request.body, Data("abcd".utf8))
    }

    func testAnOffsetBufferStillParses() {
        let padded = Data("xxGET /status HTTP/1.1\r\n\r\n".utf8).dropFirst(2)
        guard case .complete(let request) = LinkRequestParser.parse(padded) else { return XCTFail() }
        XCTAssertEqual(request.path, "/status")
    }

    func testNonsenseIsRefused() {
        XCTAssertEqual(parse("hello\r\n\r\n"), .invalid)
        XCTAssertEqual(parse("GET /a FTP/1\r\n\r\n"), .invalid)
        XCTAssertEqual(parse("GET /a HTTP/1.1\r\nno colon here\r\n\r\n"), .invalid)
        XCTAssertEqual(parse("POST /a HTTP/1.1\r\nContent-Length: -4\r\n\r\n"), .invalid)
        XCTAssertEqual(parse("POST /a HTTP/1.1\r\nContent-Length: lots\r\n\r\n"), .invalid)
        XCTAssertEqual(LinkRequestParser.parse(Data([0xFF, 0xFE, 0x0D, 0x0A, 0x0D, 0x0A])), .invalid)
    }

    func testTooMuchIsRefusedBeforeItIsAllRead() {
        XCTAssertEqual(parse("POST /a HTTP/1.1\r\nContent-Length: \(LinkRequestParser.bodyLimit + 1)\r\n\r\n"), .tooLarge)
        XCTAssertEqual(LinkRequestParser.parse(Data(repeating: 65, count: LinkRequestParser.headerLimit + 1)), .tooLarge)
    }

    func testAResponseHasWhatPythonNeeds() throws {
        let response = LinkResponse(status: 200, contentType: "text/plain", headers: ["X-Name": "a\r\nb"], body: Data("hi".utf8))
        let text = try XCTUnwrap(String(data: response.encoded, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.contains("X-Name: ab\r\n"), "a name can't smuggle in a header")
        XCTAssertTrue(text.hasSuffix("\r\n\r\nhi"))
    }

    func testAMeshCanReplaceWhatIsThereInOneUndo() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.drawEdges)
        Fixtures.draw(engine, from: Vec2(420, 380), to: Vec2(600, 380))
        let drawn = engine.mesh.vertexCount
        let obj = "v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\n"
        let imported = try MeshImporter.build(try OBJImporter.parse(data: Data(obj.utf8)), name: "Quad")

        XCTAssertTrue(engine.addEditableMesh(imported, surface: nil))
        XCTAssertEqual(engine.mesh.vertexCount, drawn + 4, "adding keeps what's there")
        XCTAssertTrue(engine.addEditableMesh(imported, surface: nil, replacing: true))
        XCTAssertEqual(engine.mesh.vertexCount, 4)
        assertValid(engine.mesh)
        engine.undo()
        XCTAssertEqual(engine.mesh.vertexCount, drawn + 4)
    }

    func testAMeshArrivingMidStrokeCancelsTheStrokeCleanly() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.drawEdges)
        engine.pencilBegan(at: Vec2(420, 380))
        engine.pencilMoved(to: Vec2(500, 380))
        let obj = "v 0 0 0\nv 1 0 0\nv 1 1 0\nf 1 2 3\n"
        let imported = try MeshImporter.build(try OBJImporter.parse(data: Data(obj.utf8)), name: "Tri")
        XCTAssertTrue(engine.addEditableMesh(imported, surface: nil))
        engine.pencilEnded(at: Vec2(600, 380))
        XCTAssertEqual(engine.mesh.vertexCount, 3, "lifting the Pencil doesn't finish the cancelled stroke")
    }
}
