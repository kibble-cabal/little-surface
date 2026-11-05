import XCTest

/// The whole way of working, through the real interface with real touches. There's no Pencil in the
/// simulator, so one finger is set to draw, which feeds the same input path as the Pencil.
final class WorkflowUITests: XCTestCase {
    private var app: XCUIApplication!

    /// What the viewport reports to assistive technology.
    private struct Stats: Equatable {
        let points, lines, quads, shapes, marks: Int
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
        return Stats(points: numbers[0], lines: numbers[1], quads: numbers[2], shapes: numbers[3], marks: numbers[4])
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
        button("Examples").tap()
        button("Open Marble Bust").tap()
        XCTAssertTrue(viewport.waitForExistence(timeout: 20))
        // The model is ready once a stroke can land on it.
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, stats.lines == 0 {
            settle(1)
            if !app.descendants(matching: .any)["busy"].exists {
                draw(CGPoint(x: 322, y: 430), CGPoint(x: 438, y: 430))
            }
        }
        XCTAssertGreaterThan(stats.lines, 0, "the surface never became ready")
        button("Undo").tap()
        settle()
        XCTAssertEqual(stats.lines, 0)
    }

    /// Four lines that close into a quad on the model's face.
    private func drawBox() {
        draw(CGPoint(x: 335, y: 430), CGPoint(x: 425, y: 430))
        draw(CGPoint(x: 425, y: 430), CGPoint(x: 425, y: 530))
        draw(CGPoint(x: 425, y: 530), CGPoint(x: 335, y: 530))
        draw(CGPoint(x: 335, y: 530), CGPoint(x: 335, y: 430))
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

    func testLinesBecomeAQuadAndCuttingItMakesMore() throws {
        openExample()
        shot("paper and a matte model")
        for gone in ["tool-select", "tool-quadPatch", "Display", "Save", "Check Mesh", "Toggle Options", "Fill with Quads"] {
            XCTAssertFalse(app.buttons[gone].exists, "\(gone) is gone")
        }

        draw(CGPoint(x: 370, y: 600), CGPoint(x: 460, y: 600))
        XCTAssertEqual(stats, Stats(points: 2, lines: 1, quads: 0, shapes: 0, marks: 0), "a line has its two ends and no more")

        draw(CGPoint(x: 460, y: 600), CGPoint(x: 460, y: 700))
        draw(CGPoint(x: 460, y: 700), CGPoint(x: 370, y: 700))
        shot("three lines")
        draw(CGPoint(x: 370, y: 700), CGPoint(x: 370, y: 600))
        XCTAssertEqual(stats, Stats(points: 4, lines: 4, quads: 1, shapes: 0, marks: 0))
        shot("a quad")

        button("Undo").tap()
        settle()
        XCTAssertEqual(stats, Stats(points: 4, lines: 3, quads: 0, shapes: 0, marks: 0), "undo takes the last line and the quad")
        draw(CGPoint(x: 370, y: 700), CGPoint(x: 370, y: 600))

        draw(CGPoint(x: 415, y: 578), CGPoint(x: 415, y: 722))
        XCTAssertEqual(stats, Stats(points: 6, lines: 7, quads: 2, shapes: 0, marks: 0), "a cut makes two")
        draw(CGPoint(x: 357, y: 650), CGPoint(x: 473, y: 650))
        XCTAssertEqual(stats, Stats(points: 9, lines: 12, quads: 4, shapes: 0, marks: 0), "and a cut across both makes four")
        shot("cut into four")
    }

    func testThreeLinesAreAShapeUntilACutMakesAQuad() throws {
        openExample()
        draw(CGPoint(x: 365, y: 722), CGPoint(x: 455, y: 722))
        draw(CGPoint(x: 455, y: 722), CGPoint(x: 410, y: 589))
        draw(CGPoint(x: 410, y: 589), CGPoint(x: 365, y: 722))
        XCTAssertEqual(stats, Stats(points: 3, lines: 3, quads: 0, shapes: 1, marks: 0))
        shot("a shape")
        draw(CGPoint(x: 365, y: 667), CGPoint(x: 455, y: 667))
        XCTAssertEqual(stats, Stats(points: 5, lines: 6, quads: 1, shapes: 1, marks: 0), "a cut leaves a triangle and a quad")
        shot("a shape cut")
    }

    func testZoomDoesNotChangeThePointsOnALine() throws {
        openExample()
        viewport.pinch(withScale: 2, velocity: 1)
        settle()
        draw(CGPoint(x: 335, y: 430), CGPoint(x: 425, y: 430))
        XCTAssertEqual(stats, Stats(points: 2, lines: 1, quads: 0, shapes: 0, marks: 0))
    }

    func testTicksSetOutTheRowsThatFillMakes() throws {
        openExample()
        drawBox()
        draw(CGPoint(x: 380, y: 413), CGPoint(x: 380, y: 447))
        XCTAssertEqual(stats, Stats(points: 5, lines: 5, quads: 0, shapes: 1, marks: 0), "a tick is a point, and a fifth corner")
        tap(380, 480)
        XCTAssertFalse(app.buttons["Fill"].exists, "five corners can't become quads")
        tap(300, 900)

        draw(CGPoint(x: 380, y: 513), CGPoint(x: 380, y: 547))
        tap(380, 480)
        shot("a shape picked")
        button("Fill").tap()
        settle()
        XCTAssertEqual(stats, Stats(points: 6, lines: 7, quads: 2, shapes: 0, marks: 0), "the rows you set out and no others")
        button("Undo").tap()
        settle()
        XCTAssertEqual(stats.shapes, 1)
    }

    func testAPickedLineCanBeDeleted() throws {
        openExample()
        draw(CGPoint(x: 335, y: 430), CGPoint(x: 425, y: 430))
        tap(380, 430)
        button("Delete").tap()
        settle()
        XCTAssertEqual(stats.lines, 0)
        button("Undo").tap()
        settle()
        XCTAssertEqual(stats.lines, 1)
    }

    func testHoldingAPointMovesItAndDrawingDoesNot() throws {
        openExample()
        draw(CGPoint(x: 335, y: 430), CGPoint(x: 425, y: 430))
        let before = stats

        point(335, 430).press(forDuration: 0.6, thenDragTo: point(329, 386), withVelocity: 200, thenHoldForDuration: 0.05)
        settle()
        XCTAssertEqual(stats, before, "a held point moves, adding nothing")
        XCTAssertFalse(app.buttons["Delete"].exists, "and doesn't stay picked")
        XCTAssertTrue(button("Undo").isEnabled)
    }

    func testAPickCanBeUndoneAndDraggedAndAStrokeElsewhereStillDraws() throws {
        openExample()
        draw(CGPoint(x: 335, y: 430), CGPoint(x: 425, y: 430))
        let drawn = stats

        tap(335, 430)
        XCTAssertTrue(button("Delete").exists, "a tap picks the point")
        button("Undo").tap()
        settle()
        XCTAssertFalse(app.buttons["Delete"].exists, "undo lets it go")
        XCTAssertEqual(stats, drawn, "and leaves the drawing alone")
        button("Redo").tap()
        settle()
        XCTAssertTrue(button("Delete").exists)

        point(335, 430).press(forDuration: 0.05, thenDragTo: point(329, 386), withVelocity: 200, thenHoldForDuration: 0.05)
        settle()
        XCTAssertEqual(stats, drawn, "dragging it moves it, and draws nothing")
        XCTAssertTrue(button("Delete").exists, "and it stays picked")
        shot("a point moved")

        tap(300, 900)
        XCTAssertFalse(app.buttons["Delete"].exists)
        draw(CGPoint(x: 335, y: 519), CGPoint(x: 425, y: 519))
        XCTAssertEqual(stats.lines, drawn.lines + 1)
    }

    // MARK: The brushes

    func testEraserAndSmoothAreOneTapAway() throws {
        openExample()
        drawBox()
        XCTAssertFalse(app.sliders["Brush Size"].exists, "the pencil has no size")

        button("tool-relaxBrush").tap()
        settle()
        let inked = stats
        XCTAssertTrue(app.sliders["Brush Size"].waitForExistence(timeout: 3))
        shot("smooth")
        draw(CGPoint(x: 361, y: 452), CGPoint(x: 399, y: 508))
        XCTAssertEqual(stats, inked, "smoothing changes no topology")

        button("tool-erase").tap()
        settle()
        draw(CGPoint(x: 380, y: 419), CGPoint(x: 380, y: 541))
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
        draw(CGPoint(x: 329, y: 430), CGPoint(x: 354, y: 430))
        let single = stats
        button("Undo").tap()
        settle()

        button("Symmetry").tap()
        settle()
        XCTAssertEqual(button("Symmetry").value as? String, "On")
        draw(CGPoint(x: 329, y: 430), CGPoint(x: 354, y: 430))
        XCTAssertEqual(stats.lines, single.lines * 2, "the far side has it too")
        shot("mirrored")
    }

    func testMirrorShowsItsAxisWhileOn() throws {
        openExample()
        XCTAssertFalse(app.buttons["mirror-axis-X"].exists)
        button("Symmetry").tap()
        settle()
        XCTAssertTrue(button("mirror-axis-X").isSelected)
        button("mirror-axis-Y").tap()
        settle()
        XCTAssertTrue(button("mirror-axis-Y").isSelected)
        XCTAssertFalse(button("mirror-axis-X").isSelected)
        shot("mirror across y")
        button("Symmetry").tap()
        settle()
        XCTAssertFalse(app.buttons["mirror-axis-X"].exists)
    }

    func testTheCompassLooksAlongAnAxis() throws {
        openExample()
        XCTAssertTrue(button("view-right").exists)
        button("view-right").tap()
        settle()
        shot("looking from the right")
    }

    func testMoveNudgesWithoutChangingTheDrawing() throws {
        openExample()
        drawBox()
        let inked = stats
        button("tool-moveBrush").tap()
        settle()
        XCTAssertTrue(app.sliders["Brush Size"].waitForExistence(timeout: 3))
        draw(CGPoint(x: 361, y: 452), CGPoint(x: 374, y: 474))
        XCTAssertEqual(stats, inked)
    }

    // MARK: What stayed, in the menu

    func testPolyBudgetShowsOnlyOnceThereIsATarget() throws {
        openExample()
        drawBox()
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
        draw(CGPoint(x: 335, y: 430), CGPoint(x: 425, y: 430))
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
        drawBox()
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
        drawBox()
        shot("dark")
    }
}
