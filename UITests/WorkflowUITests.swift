import XCTest

/// The whole way of working, through the real interface with real touches. There's no Pencil in the
/// simulator, so one finger is set to draw, which feeds the same input path as the Pencil.
final class WorkflowUITests: XCTestCase {
    private var app: XCUIApplication!

    /// What the viewport reports to assistive technology.
    private struct Stats: Equatable {
        let points, lines, quads, pencilled, marks: Int
    }

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["-oneFingerAction", "draw", "-orbitInertia", "NO"]
        app.launch()
    }

    private var viewport: XCUIElement { app.otherElements["viewport"] }

    private var stats: Stats {
        let numbers = (viewport.value as? String ?? "").split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        XCTAssertEqual(numbers.count, 5, "the viewport reports its counts")
        return Stats(points: numbers[0], lines: numbers[1], quads: numbers[2], pencilled: numbers[3], marks: numbers[4])
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    private func draw(_ a: CGPoint, _ b: CGPoint) {
        point(a.x, a.y).press(forDuration: 0.05, thenDragTo: point(b.x, b.y), withVelocity: 400, thenHoldForDuration: 0.05)
        settle()
    }

    private func tap(_ x: CGFloat, _ y: CGFloat) {
        point(x, y).tap()
        settle()
    }

    private func settle(_ time: TimeInterval = 0.4) {
        RunLoop.current.run(until: Date().addingTimeInterval(time))
    }

    private func button(_ id: String) -> XCUIElement {
        // By identifier alone: a project card's label can read the same as a button's identifier.
        let element = app.buttons.matching(NSPredicate(format: "identifier == %@", id)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(id) didn't appear")
        return element
    }

    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        settle()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openExample() {
        button("Add").tap()
        button("Open Example").tap()
        XCTAssertTrue(viewport.waitForExistence(timeout: 20))
        // The model is ready once a stroke can land on it.
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, stats.lines == 0 {
            settle(1)
            if !app.descendants(matching: .any)["busy"].exists {
                draw(CGPoint(x: 320, y: 480), CGPoint(x: 500, y: 480))
            }
        }
        XCTAssertGreaterThan(stats.lines, 0, "the surface never became ready")
        button("Undo").tap()
        settle()
        XCTAssertEqual(stats.lines, 0)
    }

    private func more(_ id: String) {
        button("More").tap()
        settle()
        button(id).tap()
        settle()
    }

    private func dismissSheet() {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)).tap()
        settle(0.8)
    }

    // MARK: Drawing

    func testDrawingAppearsAsAPencilledFillThatFirmsUpAndUndoes() throws {
        openExample()
        shot("paper and a matte model")
        for gone in ["tool-select", "tool-quadPatch", "Display", "Save", "Check Mesh", "Toggle Options", "Fill with Quads"] {
            XCTAssertFalse(app.buttons[gone].exists, "\(gone) is gone")
        }

        draw(CGPoint(x: 340, y: 480), CGPoint(x: 480, y: 480))
        let first = stats
        XCTAssertGreaterThan(first.lines, 0)
        XCTAssertEqual(first.quads, 0)
        XCTAssertEqual(first.pencilled, 0)

        draw(CGPoint(x: 340, y: 570), CGPoint(x: 480, y: 570))
        XCTAssertEqual(stats.pencilled, 1, "quads appear with nothing to tap")
        XCTAssertEqual(stats.quads, 0)
        shot("pencilled quads")

        button("Undo").tap()
        settle()
        XCTAssertEqual(stats.pencilled, 0, "undo takes the quads and leaves the line")
        XCTAssertEqual(stats.lines, first.lines * 2)
        button("Undo").tap()
        settle()
        XCTAssertEqual(stats.lines, first.lines)

        draw(CGPoint(x: 340, y: 570), CGPoint(x: 480, y: 570))
        XCTAssertEqual(stats.pencilled, 1)
        tap(300, 900)
        XCTAssertEqual(stats.pencilled, 0, "moving on firms them up")
        XCTAssertGreaterThan(stats.quads, 0)
        shot("inked quads")
    }

    func testZoomSetsTheSizeOfTheQuads() throws {
        openExample()
        draw(CGPoint(x: 340, y: 480), CGPoint(x: 480, y: 480))
        let wide = stats.lines
        button("Undo").tap()
        settle()

        viewport.pinch(withScale: 2, velocity: 1)
        settle()
        draw(CGPoint(x: 340, y: 480), CGPoint(x: 480, y: 480))
        // The same length on screen, whatever the zoom.
        XCTAssertEqual(Double(stats.lines), Double(wide), accuracy: 1)
    }

    func testAMarkOverQuadsStaysAsPencilAndCanBeDeleted() throws {
        openExample()
        draw(CGPoint(x: 340, y: 480), CGPoint(x: 480, y: 480))
        draw(CGPoint(x: 340, y: 570), CGPoint(x: 480, y: 570))
        tap(300, 900)
        let inked = stats
        XCTAssertGreaterThan(inked.quads, 0)

        draw(CGPoint(x: 370, y: 525), CGPoint(x: 450, y: 525))
        XCTAssertEqual(stats.marks, 1, "nothing is refused")
        XCTAssertFalse(app.descendants(matching: .any)["message"].exists, "and nothing is said about it")
        shot("a mark")

        tap(410, 525)
        button("Delete").tap()
        settle()
        XCTAssertEqual(stats.marks, 0)
        button("Undo").tap()
        settle()
        XCTAssertEqual(stats.marks, 1)
        XCTAssertEqual(stats.quads, inked.quads)
    }

    func testHoldingAPointMovesItAndDrawingDoesNot() throws {
        openExample()
        draw(CGPoint(x: 340, y: 480), CGPoint(x: 480, y: 480))
        let before = stats

        point(340, 480).press(forDuration: 0.6, thenDragTo: point(330, 440), withVelocity: 200, thenHoldForDuration: 0.05)
        settle()
        XCTAssertEqual(stats, before, "a held point moves, adding nothing")
        XCTAssertFalse(app.buttons["Delete"].exists, "and doesn't stay picked")
        XCTAssertTrue(button("Undo").isEnabled)
    }

    // MARK: The brushes

    func testEraserAndSmoothAreOneTapAway() throws {
        openExample()
        draw(CGPoint(x: 340, y: 480), CGPoint(x: 480, y: 480))
        draw(CGPoint(x: 340, y: 570), CGPoint(x: 480, y: 570))
        XCTAssertFalse(app.sliders["Brush Size"].exists, "the pencil has no size")

        button("tool-relaxBrush").tap()
        settle()
        XCTAssertEqual(stats.pencilled, 0, "changing tools moves on")
        let inked = stats
        XCTAssertTrue(app.sliders["Brush Size"].waitForExistence(timeout: 3))
        shot("smooth")
        draw(CGPoint(x: 380, y: 500), CGPoint(x: 440, y: 550))
        XCTAssertEqual(stats, inked, "smoothing changes no topology")

        button("tool-erase").tap()
        settle()
        draw(CGPoint(x: 410, y: 470), CGPoint(x: 410, y: 580))
        XCTAssertLessThan(stats.quads, inked.quads)
        shot("erased")
        button("Undo").tap()
        settle()
        XCTAssertEqual(stats.quads, inked.quads)

        button("tool-pencil").tap()
        settle()
        XCTAssertFalse(app.sliders["Brush Size"].exists)
    }

    func testSymmetryMirrorsAStroke() throws {
        openExample()
        draw(CGPoint(x: 330, y: 480), CGPoint(x: 370, y: 480))
        let single = stats
        button("Undo").tap()
        settle()

        button("Symmetry").tap()
        settle()
        XCTAssertEqual(button("Symmetry").value as? String, "On")
        draw(CGPoint(x: 330, y: 480), CGPoint(x: 370, y: 480))
        XCTAssertEqual(stats.lines, single.lines * 2, "the far side has it too")
        shot("mirrored")
    }

    // MARK: What stayed, in the menu

    func testPolyBudgetShowsOnlyOnceThereIsATarget() throws {
        openExample()
        draw(CGPoint(x: 340, y: 480), CGPoint(x: 480, y: 480))
        draw(CGPoint(x: 340, y: 570), CGPoint(x: 480, y: 570))
        tap(300, 900)
        let inked = stats
        XCTAssertFalse(app.buttons["budget-status"].exists)

        more("Poly Budget")
        XCTAssertTrue(app.staticTexts["budget-summary"].waitForExistence(timeout: 5))
        button("budget-preset-1000").tap()
        settle()
        XCTAssertTrue(button("jump-poles").waitForExistence(timeout: 5))
        shot("the budget sheet")
        dismissSheet()

        XCTAssertEqual(button("budget-status").label, "\(inked.quads * 2) / 1,000 tris", "quads count as two")
        XCTAssertEqual(stats, inked, "a budget changes nothing about the mesh")
    }

    func testBlenderLinkTakesAMeshOverTheNetwork() throws {
        openExample()
        draw(CGPoint(x: 340, y: 480), CGPoint(x: 480, y: 480))
        let before = stats
        more("Blender Link")
        XCTAssertTrue(app.switches["Blender Link Toggle"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Blender Link Code"].exists, "the code stays hidden until the link is on")
        flip(app.switches["Blender Link Toggle"])
        let code = app.staticTexts["Blender Link Code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        // VoiceOver reads the row whole, so the digits may sit in its label or its value.
        let shown = "\(code.label) \(code.value ?? "")".filter(\.isNumber)
        XCTAssertEqual(shown.count, 6, "the code on screen")
        shot("the Blender Link sheet")

        // Stands in for the add-on, which has its own run against real Blender.
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:48620/mesh?name=Card")))
        request.httpMethod = "POST"
        request.setValue(shown, forHTTPHeaderField: "X-Little-Surface-Code")
        request.httpBody = Data("v 0 0 2\nv 1 0 2\nv 1 1 2\nv 0 1 2\nf 1 2 3 4\n".utf8)
        let answered = expectation(description: "the app answers")
        var status = 0
        URLSession.shared.dataTask(with: request) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            answered.fulfill()
        }.resume()
        wait(for: [answered], timeout: 30)
        XCTAssertEqual(status, 200)

        button("Blender Link Done").tap()
        settle()
        XCTAssertEqual(stats.points, before.points + 4, "the mesh arrived beside what was there")
        XCTAssertEqual(stats.quads, before.quads + 1)
        button("Undo").tap()
        settle()
        XCTAssertEqual(stats.quads, before.quads, "undo here takes it back")
    }

    func testSavesReopensAndExports() throws {
        openExample()
        draw(CGPoint(x: 340, y: 480), CGPoint(x: 480, y: 480))
        draw(CGPoint(x: 340, y: 570), CGPoint(x: 480, y: 570))
        tap(300, 900)
        let inked = stats
        XCTAssertGreaterThan(inked.quads, 0)

        more("Rename")
        let name = "Reopened \(Int(Date().timeIntervalSince1970))"
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40) + name)
        app.alerts.buttons["Rename"].tap()
        settle(1)

        button("Projects").tap()
        let card = button("project-\(name)")
        settle(1)
        shot("welcome")
        card.tap()
        XCTAssertTrue(viewport.waitForExistence(timeout: 20))
        settle(2)
        XCTAssertEqual(stats.lines, inked.lines, "autosave kept it all")
        XCTAssertEqual(stats.quads, inked.quads)

        // Export through the share sheet, with and without the source. tools/verify_app_exports.sh reads the results.
        for (format, withSource) in [("OBJ", false), ("GLB", false), ("OBJ", true), ("GLB", true)] {
            more("Export")
            let picker = app.segmentedControls["Export Format"]
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            picker.buttons[format].tap()
            if withSource {
                let exportName = app.textFields["Export Name"]
                exportName.tap()
                exportName.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40) + "with-source")
                flip(app.switches["Include Source"])
            }
            button("Export Confirm").tap()
            settle(1.5)
            shot("export \(format)\(withSource ? " with source" : "")")
            let close = app.buttons["Close"]
            if close.waitForExistence(timeout: 3) {
                close.tap()
            } else {
                point(60, 600).tap()
            }
            settle(1)
        }
        button("Projects").tap()
        XCTAssertTrue(button("project-\(name)").waitForExistence(timeout: 10))
    }

    func testDarkLook() throws {
        app.terminate()
        app.launchArguments += ["-appearance", "dark"]
        app.launch()
        openExample()
        draw(CGPoint(x: 340, y: 480), CGPoint(x: 480, y: 480))
        draw(CGPoint(x: 340, y: 570), CGPoint(x: 480, y: 570))
        shot("dark")
    }
}
