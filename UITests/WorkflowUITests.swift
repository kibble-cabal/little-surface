import XCTest

/// The brief's end-to-end workflow, through the real interface with real touches. There's no Pencil in
/// the simulator, so one finger is set to draw, which feeds the same input path as the Pencil.
final class WorkflowUITests: XCTestCase {
    private var app: XCUIApplication!

    private struct Stats {
        let vertices, edges, faces, quads: Int
    }

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["-oneFingerAction", "draw", "-hasSeenTutorial", "YES", "-orbitInertia", "NO"]
        app.launch()
    }

    private var stats: Stats {
        let label = app.staticTexts["mesh-stats"].label
        let parts = label.split(whereSeparator: \.isWhitespace).map(String.init)
        func value(_ key: String) -> Int {
            guard let i = parts.firstIndex(of: key), i + 1 < parts.count else { return -1 }
            return Int(parts[i + 1]) ?? -1
        }
        return Stats(vertices: value("V"), edges: value("E"), faces: value("F"), quads: value("Quads"))
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

    private func dismissPopover() {
        let region = app.otherElements["PopoverDismissRegion"]
        if region.waitForExistence(timeout: 2) { region.tap() }
        settle()
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

    func testFullWorkflow() throws {
        button("Open Example").tap()

        // Import a detailed model, off the main thread.
        XCTAssertTrue(app.staticTexts["mesh-stats"].waitForExistence(timeout: 20))
        let imported = app.descendants(matching: .any)["message"]
        XCTAssertTrue(imported.waitForExistence(timeout: 60), "the import never finished")
        XCTAssertTrue(imported.label.contains("71,198"), imported.label)
        let name = app.buttons["Project Name"].label.replacingOccurrences(of: "Project name, ", with: "")
        shot("imported")

        // Rotate around it, then come back to the front.
        button("view-right").tap()
        settle()
        shot("right view")
        app.otherElements["viewport"].pinch(withScale: 1.2, velocity: 1)
        settle()
        button("view-front").tap()
        button("Display").tap()
        button("Frame Model").tap()
        dismissPopover()

        // Draw two lines. Each becomes real vertices and edges on the surface.
        draw(CGPoint(x: 320, y: 480), CGPoint(x: 500, y: 480))
        let first = stats
        XCTAssertGreaterThan(first.edges, 5)
        XCTAssertEqual(first.faces, 0)
        draw(CGPoint(x: 320, y: 585), CGPoint(x: 500, y: 585))
        let second = stats
        XCTAssertGreaterThan(second.edges, first.edges)
        shot("two lines")

        // Generate quads between them, previewing first.
        button("tool-quadPatch").tap()
        tap(410, 480)
        tap(410, 585)
        XCTAssertTrue(button("Create Patch").isEnabled)
        XCTAssertEqual(stats.faces, 0, "a preview doesn't touch the mesh")
        shot("patch preview")
        button("Create Patch").tap()
        settle()
        let patched = stats
        XCTAssertGreaterThan(patched.faces, 20)
        XCTAssertEqual(patched.quads, patched.faces, "all quads")
        shot("patch")

        // Move a single vertex, and undo and redo it.
        button("tool-select").tap()
        button("Undo").tap()
        settle()
        XCTAssertEqual(stats.faces, 0, "undo removes the whole patch in one step")
        button("Redo").tap()
        settle()
        XCTAssertEqual(stats.faces, patched.faces)
        draw(CGPoint(x: 410, y: 530), CGPoint(x: 425, y: 520))
        XCTAssertEqual(stats.faces, patched.faces, "moving doesn't change topology")
        XCTAssertTrue(app.staticTexts["selection-status"].exists)
        shot("moved vertex")

        // Add a face on the chest, then delete it.
        button("tool-face").tap()
        tap(370, 750)
        tap(450, 750)
        tap(450, 800)
        tap(370, 800)
        XCTAssertEqual(stats.faces, patched.faces + 1, "the fourth corner makes a quad")
        shot("added face")
        button("tool-select").tap()
        button("Toggle Options").tap()
        settle()
        button("Delete").tap()
        settle()
        XCTAssertEqual(stats.faces, patched.faces)

        // Turn on symmetry and draw on one side. It lands on both.
        button("Toggle Options").tap()
        button("Symmetry").tap()
        let symmetry = app.switches["Symmetry Toggle"]
        XCTAssertTrue(symmetry.waitForExistence(timeout: 5))
        flip(symmetry)
        settle()
        shot("symmetry popover")
        dismissPopover()
        button("tool-drawEdges").tap()
        let beforeMirror = stats
        shot("before mirror")
        draw(CGPoint(x: 430, y: 445), CGPoint(x: 475, y: 460))
        let mirrored = stats
        shot("symmetry")
        XCTAssertGreaterThanOrEqual(mirrored.vertices - beforeMirror.vertices, 4)
        XCTAssertEqual((mirrored.vertices - beforeMirror.vertices) % 2, 0, "every new vertex has a partner")

        // Preview subdivision. The real mesh doesn't change.
        button("Display").tap()
        let subdivision = app.switches["Subdivision Preview"]
        XCTAssertTrue(subdivision.waitForExistence(timeout: 5))
        if !subdivision.isHittable { button("Frame Selection").swipeUp() }
        flip(subdivision)
        XCTAssertTrue(app.staticTexts["subdivision-note"].waitForExistence(timeout: 10))
        dismissPopover()
        XCTAssertEqual(stats.faces, mirrored.faces)
        shot("subdivision")
        button("Display").tap()
        if !subdivision.isHittable { button("Frame Selection").swipeUp() }
        flip(subdivision)
        dismissPopover()

        // Save, close, and reopen.
        button("Save").tap()
        settle(1.5)
        let saved = stats
        button("Projects").tap()
        let card = button("project-\(name)")
        settle(1)
        shot("welcome")
        card.tap()
        XCTAssertTrue(app.staticTexts["mesh-stats"].waitForExistence(timeout: 20))
        settle(1)
        let reopened = stats
        XCTAssertEqual(reopened.vertices, saved.vertices)
        XCTAssertEqual(reopened.edges, saved.edges)
        XCTAssertEqual(reopened.faces, saved.faces)
        shot("reopened")

        // The surface is ready again, and reopened topology stays editable.
        draw(CGPoint(x: 340, y: 660), CGPoint(x: 360, y: 700))
        button("Undo").tap()
        settle()

        // Export through the share sheet, with and without the source. tools/verify_app_exports.sh reads the results.
        for (format, withSource) in [("OBJ", false), ("GLB", false), ("OBJ", true), ("GLB", true)] {
            button("Export").tap()
            let picker = app.segmentedControls["Export Format"]
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            picker.buttons[format].tap()
            if withSource {
                let field = app.textFields["Export Name"]
                field.tap()
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40) + "with-source")
                flip(app.switches["Include Source"])
            }
            button("Export Confirm").tap()
            settle(1.5)
            shot("export \(format)\(withSource ? " with source" : "")")
            // Dismiss the share sheet.
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

    func testDarkLandscapeLook() throws {
        app.terminate()
        app.launchArguments += ["-appearance", "dark"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        settle(1)
        shot("dark welcome")
        button("Open Example").tap()
        XCTAssertTrue(app.descendants(matching: .any)["message"].waitForExistence(timeout: 60))
        shot("dark landscape editor")
        XCUIDevice.shared.orientation = .portrait
        settle(1)
    }

    func testRefusedPatchExplainsAndChangesNothing() throws {
        button("Open Example").tap()
        XCTAssertTrue(app.descendants(matching: .any)["message"].waitForExistence(timeout: 60))
        draw(CGPoint(x: 320, y: 480), CGPoint(x: 500, y: 480))
        let before = stats
        button("tool-quadPatch").tap()
        tap(410, 480)
        XCTAssertFalse(button("Create Patch").isEnabled, "one line isn't enough to patch")
        XCTAssertEqual(stats.edges, before.edges)
    }

    /// Opens the example, draws two lines and makes a patch, which the other tests then work on.
    private func openPatchedExample() -> Stats {
        button("Open Example").tap()
        XCTAssertTrue(app.descendants(matching: .any)["message"].waitForExistence(timeout: 60))
        draw(CGPoint(x: 320, y: 480), CGPoint(x: 500, y: 480))
        draw(CGPoint(x: 320, y: 585), CGPoint(x: 500, y: 585))
        button("tool-quadPatch").tap()
        tap(410, 480)
        tap(410, 585)
        button("Create Patch").tap()
        settle()
        return stats
    }

    private func press(_ id: String) {
        let element = button(id)
        if !element.isHittable { app.swipeUp() }
        element.tap()
        settle(0.3)
    }

    private func pickSelectionMode(_ title: String) {
        app.segmentedControls["Selection Mode"].buttons[title].tap()
        settle(0.2)
    }

    private func assertUndoRestores(_ expected: Stats, file: StaticString = #filePath, line: UInt = #line) {
        button("Undo").tap()
        settle(0.3)
        XCTAssertEqual(stats.vertices, expected.vertices, file: file, line: line)
        XCTAssertEqual(stats.edges, expected.edges, file: file, line: line)
        XCTAssertEqual(stats.faces, expected.faces, file: file, line: line)
    }

    func testEveryEditKeepsItsPromiseAndUndoes() throws {
        let start = openPatchedExample()
        XCTAssertGreaterThan(start.faces, 20)
        button("tool-select").tap()
        button("Toggle Options").tap()
        settle()
        shot("select panel")

        // Whole-mesh operations.
        press("All")
        press("Subdivide")
        XCTAssertEqual(stats.faces, start.faces * 4, "subdividing every quad makes four")
        assertUndoRestores(start)
        press("Relax")
        XCTAssertEqual(stats.faces, start.faces)
        assertUndoRestores(start)
        press("Reverse")
        press("Fix Normals")
        XCTAssertEqual(stats.faces, start.faces)
        press("None")

        // The boundary, extruded.
        pickSelectionMode("Edge")
        tap(410, 530)
        XCTAssertTrue(app.staticTexts["selection-status"].exists, "a tap selects an edge")
        press("Loop")
        press("Ring")
        press("Connected")
        press("Boundary")
        press("Extrude")
        XCTAssertGreaterThan(stats.faces, start.faces)
        shot("extruded")
        assertUndoRestores(start)
        press("Split")
        XCTAssertGreaterThan(stats.vertices, start.vertices)
        assertUndoRestores(start)
        press("None")

        // A face deleted, then filled back.
        pickSelectionMode("Face")
        tap(410, 530)
        press("Delete")
        XCTAssertEqual(stats.faces, start.faces - 1)
        press("Fill")
        XCTAssertEqual(stats.faces, start.faces)
        assertUndoRestores(Stats(vertices: start.vertices, edges: start.edges, faces: start.faces - 1, quads: start.faces - 1))
        assertUndoRestores(start)
        press("None")

        // A vertex dissolved.
        pickSelectionMode("Vertex")
        tap(410, 530)
        press("Dissolve")
        XCTAssertLessThan(stats.vertices, start.vertices)
        assertUndoRestores(start)

        // Nothing selected is never a crash, only a note.
        press("None")
        for id in ["Weld", "Connect", "Flip", "Make Face", "Dissolve", "Delete"] { press(id) }
        XCTAssertEqual(stats.faces, start.faces)
        button("Toggle Options").tap()

        // The report reads the same mesh.
        button("Check Mesh").tap()
        XCTAssertTrue(app.staticTexts["Connected parts"].waitForExistence(timeout: 10))
        shot("report")
        app.buttons["Done"].firstMatch.tap()
        settle()
    }

    func testStripBrushesAndFingerUndo() throws {
        let start = openPatchedExample()

        // A strip from one stroke, previewed before it's real.
        button("tool-quadStrip").tap()
        draw(CGPoint(x: 340, y: 770), CGPoint(x: 480, y: 770))
        XCTAssertEqual(stats.faces, start.faces, "still a preview")
        shot("strip preview")
        button("Create Strip").tap()
        settle()
        XCTAssertGreaterThan(stats.faces, start.faces)
        let stripped = stats
        shot("strip")

        // Two fingers tapping undoes the strip in one step.
        app.otherElements["viewport"].twoFingerTap()
        settle()
        XCTAssertEqual(stats.faces, start.faces)
        button("Redo").tap()
        settle()
        XCTAssertEqual(stats.faces, stripped.faces)
        assertUndoRestores(start)

        // Brushes.
        button("tool-moveBrush").tap()
        draw(CGPoint(x: 400, y: 530), CGPoint(x: 420, y: 530))
        XCTAssertEqual(stats.faces, start.faces)
        assertUndoRestores(start)
        button("tool-relaxBrush").tap()
        draw(CGPoint(x: 340, y: 530), CGPoint(x: 480, y: 530))
        XCTAssertEqual(stats.faces, start.faces)
        assertUndoRestores(start)
        button("tool-erase").tap()
        draw(CGPoint(x: 380, y: 530), CGPoint(x: 440, y: 530))
        XCTAssertLessThan(stats.faces, start.faces)
        shot("erased")
        assertUndoRestores(start)
    }

    func testDisplayModes() throws {
        _ = openPatchedExample()
        button("Display").tap()
        let modes = app.segmentedControls["Display Mode"]
        XCTAssertTrue(modes.waitForExistence(timeout: 5))
        for mode in ["Wireframe", "X-ray", "Solid"] {
            modes.buttons[mode].tap()
            settle()
            dismissPopover()
            shot("display \(mode)")
            button("Display").tap()
            XCTAssertTrue(modes.waitForExistence(timeout: 5))
        }
        for toggle in ["Show Source", "Show Topology"] {
            flip(app.switches[toggle])
            dismissPopover()
            shot("hidden \(toggle)")
            button("Display").tap()
            XCTAssertTrue(app.switches[toggle].waitForExistence(timeout: 5))
            flip(app.switches[toggle])
        }
        dismissPopover()
    }
}
