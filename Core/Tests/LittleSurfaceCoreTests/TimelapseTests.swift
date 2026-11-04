import XCTest
import simd
@testable import LittleSurfaceCore

final class TimelapseTests: XCTestCase {
    private func assertLastFrameShows(_ engine: RetopoEngine, file: StaticString = #filePath, line: UInt = #line) throws {
        let frames = engine.timelapse.frames
        guard let last = frames.last else { return XCTAssertEqual(engine.mesh.vertexCount, 0, file: file, line: line) }
        let shown = try last.decoded()
        XCTAssertEqual(shown.mesh.positions, engine.mesh.positions, "the replay ends where the work is", file: file, line: line)
        XCTAssertEqual(shown.mesh.vertexAlive, engine.mesh.vertexAlive, file: file, line: line)
        XCTAssertEqual(shown.mesh.edgeAlive, engine.mesh.edgeAlive, file: file, line: line)
        XCTAssertEqual(shown.mesh.faceAlive, engine.mesh.faceAlive, file: file, line: line)
        XCTAssertEqual(shown.mesh.faceLoops, engine.mesh.faceLoops, file: file, line: line)
        XCTAssertEqual(shown.sketches, engine.sketches, file: file, line: line)
    }

    func testEveryKindOfActionLeavesExactlyOneFrame() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        XCTAssertTrue(engine.timelapse.frames.isEmpty)
        var count = 0
        func expectFrame(_ what: String, file: StaticString = #filePath, line: UInt = #line, _ action: () -> Void) throws {
            action()
            count += 1
            XCTAssertEqual(engine.timelapse.frames.count, count, what, file: file, line: line)
            try assertLastFrameShows(engine, file: file, line: line)
        }

        engine.setTool(.sketch)
        try expectFrame("sketch") { Fixtures.draw(engine, from: Vec2(420, 300), to: Vec2(600, 300)) }
        try expectFrame("clear sketch") { engine.clearSketch() }
        engine.setTool(.drawEdges)
        try expectFrame("stroke") { Fixtures.draw(engine, from: Vec2(420, 380), to: Vec2(600, 380)) }
        try expectFrame("second stroke") { Fixtures.draw(engine, from: Vec2(420, 460), to: Vec2(600, 460)) }
        try expectFrame("undo") { engine.undo() }
        try expectFrame("redo") { engine.redo() }
        engine.selectAll()
        XCTAssertEqual(engine.timelapse.frames.count, count, "selecting isn't an edit")
        try expectFrame("split") { engine.splitSelectedEdges() }
        try expectFrame("relax") { engine.relaxSelection() }
        engine.setTool(.moveBrush)
        try expectFrame("brush") { Fixtures.draw(engine, from: Vec2(450, 380), to: Vec2(520, 380)) }
        engine.setTool(.erase)
        try expectFrame("erase") { Fixtures.draw(engine, from: Vec2(450, 450), to: Vec2(560, 470)) }
        engine.selectAll()
        try expectFrame("delete") { engine.deleteSelection() }

        engine.cameraChanged()
        engine.frameAll()
        XCTAssertEqual(engine.timelapse.frames.count, count, "looking around isn't an edit")
    }

    /// Whatever anyone does, the mesh can't change without the replay knowing.
    func testARandomSessionNeverLeavesTheReplayBehind() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        var random = SystemRandomNumberGenerator()
        func point() -> Vec2 { Vec2(Float.random(in: 380...620, using: &random), Float.random(in: 340...660, using: &random)) }
        let tools: [Tool] = [.drawEdges, .quadStrip, .sketch, .moveBrush, .relaxBrush, .erase, .select]
        for step in 0..<400 {
            switch Int.random(in: 0..<19, using: &random) {
            case 0...4:
                engine.setTool(tools.randomElement(using: &random)!)
                Fixtures.draw(engine, from: point(), to: point())
                engine.commitPendingStrip()
                engine.commitPendingStroke(close: false)
            case 5: engine.undo()
            case 6: engine.redo()
            case 7: engine.selectAll()
            case 8: engine.subdivideSelection()
            case 9: engine.fillHoles()
            case 10: engine.deleteSelection()
            case 11: engine.setSymmetryEnabled(Bool.random(using: &random))
            case 12: engine.weldByDistance(0.01)
            case 13: engine.setSymmetryPlane(axis: MirrorAxis.allCases.randomElement(using: &random))
            case 14: engine.mergeCenterline()
            case 15: engine.applySymmetry()
            case 16: engine.reproject()
            case 17: engine.reverseNormals()
            default: engine.relaxSelection()
            }
            assertValid(engine.mesh)
            XCTAssertNoThrow(try assertLastFrameShows(engine), "step \(step)")
        }
    }

    func testAFrameRemembersWhereTheEditWasAndHowTheArtistWasLooking() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.drawEdges)
        Fixtures.draw(engine, from: Vec2(600, 450), to: Vec2(600, 550))
        let first = try XCTUnwrap(engine.timelapse.frames.last)
        let focus = try XCTUnwrap(first.focus)
        XCTAssertGreaterThan(focus.x, 0.2, "drawn on the right of the screen")
        XCTAssertEqual(focus.y, 0, accuracy: 0.1)
        XCTAssertEqual(first.orientation.vector, engine.camera.orientation.vector)

        engine.camera.setPreset(.left)
        Fixtures.draw(engine, from: Vec2(450, 450), to: Vec2(450, 550))
        let second = try XCTUnwrap(engine.timelapse.frames.last)
        XCTAssertEqual(second.orientation.vector, ViewPreset.left.orientation.vector)
        XCTAssertLessThan(try XCTUnwrap(second.focus).x, -0.2, "this one is around the side")
    }

    func testFillingWithoutMovingAVertexStillHasAFocus() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.drawEdges)
        Fixtures.draw(engine, from: Vec2(420, 340), to: Vec2(600, 340))
        Fixtures.draw(engine, from: Vec2(420, 430), to: Vec2(600, 430))
        engine.commitFillSuggestion()
        XCTAssertGreaterThan(engine.mesh.faceCount, 0)
        XCTAssertNotNil(engine.timelapse.frames.last?.focus)
    }

    func testTheReplaySavesWithTheProject() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.drawEdges)
        Fixtures.draw(engine, from: Vec2(420, 380), to: Vec2(600, 380))
        Fixtures.draw(engine, from: Vec2(420, 460), to: Vec2(600, 460))
        let saved = engine.timelapse.frames
        let reopened = RetopoEngine(snapshot: try ProjectCodec.decode(try ProjectCodec.encode(engine.makeSnapshot())))
        XCTAssertEqual(reopened.timelapse.frames, saved)
        XCTAssertEqual(try reopened.timelapse.frames[1].decoded().mesh.positions, engine.mesh.positions)
    }

    func testAProjectFromBeforeTimelapsesStartsFromHowItIs() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.drawEdges)
        Fixtures.draw(engine, from: Vec2(420, 380), to: Vec2(600, 380))
        var snapshot = engine.makeSnapshot()
        snapshot.timelapse = []
        let reopened = RetopoEngine(snapshot: try ProjectCodec.decode(try ProjectCodec.encode(snapshot)))
        let frames = reopened.timelapse.frames
        XCTAssertEqual(frames.count, 1)
        XCTAssertNil(frames[0].focus)
        try assertLastFrameShows(reopened)
    }

    func testRunningOutOfRoomThinsEvenlyAndKeepsBothEnds() throws {
        let recorder = TimelapseRecorder(byteBudget: 400_000)
        var mesh = Fixtures.grid(columns: 30, rows: 30).mesh
        let look = simd_quatf(angle: 0, axis: Vec3(0, 1, 0))
        var firstPosition: Vec3?
        for i in 0..<200 {
            var positions = mesh.positions
            for p in positions.indices { positions[p].z = Float.random(in: -1...1) * Float(i + 1) }
            mesh.positions = positions
            if i == 0 { firstPosition = positions[0] }
            recorder.record(mesh: mesh, sketches: [], orientation: look)
        }
        let frames = recorder.frames
        XCTAssertGreaterThan(frames.count, 2)
        XCTAssertLessThan(frames.count, 200)
        XCTAssertLessThanOrEqual(frames.reduce(0) { $0 + $1.geometry.count }, 400_000)
        XCTAssertEqual(try frames[0].decoded().mesh.positions[0], firstPosition)
        XCTAssertEqual(try frames[frames.count - 1].decoded().mesh.positions, mesh.positions)
    }

    func testADamagedReplayDoesNotCostTheProject() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.drawEdges)
        Fixtures.draw(engine, from: Vec2(420, 380), to: Vec2(600, 380))
        var snapshot = engine.makeSnapshot()
        snapshot.timelapse[0].geometry = Data([1, 2, 3])
        let reopened = RetopoEngine(snapshot: try ProjectCodec.decode(try ProjectCodec.encode(snapshot)))
        XCTAssertEqual(reopened.mesh.vertexCount, engine.mesh.vertexCount)
    }

    func testKnowingThereIsSomethingToReplayDoesNotWait() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        XCTAssertFalse(engine.timelapse.hasFrames)
        engine.setTool(.drawEdges)
        Fixtures.draw(engine, from: Vec2(420, 380), to: Vec2(600, 380))
        XCTAssertTrue(engine.timelapse.hasFrames)
        let reopened = RetopoEngine(snapshot: try ProjectCodec.decode(try ProjectCodec.encode(engine.makeSnapshot())))
        XCTAssertTrue(reopened.timelapse.hasFrames)
    }

    func testReplayingDoesNotCountAsEditing() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.drawEdges)
        Fixtures.draw(engine, from: Vec2(420, 380), to: Vec2(600, 380))
        let snapshot = engine.makeSnapshot()
        let replay = RetopoEngine.forReplay(of: snapshot)
        XCTAssertEqual(replay.mesh.vertexCount, 0)
        XCTAssertTrue(replay.timelapse.frames.isEmpty)
        let frame = try snapshot.timelapse[0].decoded()
        replay.showForReplay(mesh: frame.mesh, sketches: frame.sketches)
        XCTAssertEqual(replay.mesh.vertexCount, engine.mesh.vertexCount)
        XCTAssertTrue(replay.timelapse.frames.isEmpty)
        XCTAssertFalse(replay.canUndo)
    }

    // MARK: The director

    private func frames(_ count: Int, turning: Bool = true) -> [TimelapseFrame] {
        (0..<count).map { i in
            let group = i / 6
            let angle = turning ? Float(group % 4) * .pi / 2 : 0
            return TimelapseFrame(geometry: Data(), focus: Vec3(sin(angle), Float(group % 3) * 0.2, cos(angle)),
                                  orientation: simd_quatf(angle: angle, axis: Vec3(0, 1, 0)))
        }
    }

    private let box = AABB(minCorner: Vec3(repeating: -1), maxCorner: Vec3(repeating: 1))
    private let view = Vec2(540, 540)

    func testEveryStepAppearsInOrderAndTheVideoStaysShort() {
        for count in [1, 2, 7, 40, 400, TimelapseRecorder.frameLimit] {
            let shots = TimelapseDirector.shots(for: frames(count), bounds: box, camera: Camera(), viewSize: view)
            let seen = shots.map(\.frameIndex)
            XCTAssertEqual(seen, seen.sorted(), "\(count) steps stay in order")
            XCTAssertEqual(Set(seen.filter { $0 >= 0 }), Set(0..<count), "\(count) steps are all shown")
            XCTAssertEqual(seen.first, -1, "opens on the bare model")
            XCTAssertEqual(seen.last, count - 1, "ends on the finished work")
            let seconds = Float(shots.count) / Float(TimelapseDirector.framesPerSecond)
            XCTAssertGreaterThanOrEqual(seconds, 8)
            XCTAssertLessThanOrEqual(seconds, 47)
        }
    }

    func testAProjectThatStartedWithAMeshOpensOnThatMesh() {
        var list = frames(5)
        list[0].focus = nil
        XCTAssertEqual(TimelapseDirector.shots(for: list, bounds: box, camera: Camera(), viewSize: view).first?.frameIndex, 0)
    }

    func testNothingRecordedMakesNoVideo() {
        XCTAssertTrue(TimelapseDirector.shots(for: [], bounds: box, camera: Camera(), viewSize: view).isEmpty)
    }

    func testTheCameraEasesWithoutJumpsAndEachTurnStartsAndEndsGently() {
        let shots = TimelapseDirector.shots(for: frames(60), bounds: box, camera: Camera(), viewSize: view)
        var angles: [Float] = []
        for (a, b) in zip(shots, shots.dropFirst()) {
            let delta = simd_mul(b.camera.orientation, a.camera.orientation.inverse)
            let angle = 2 * acos(min(abs(delta.vector.w), 1)) * 180 / .pi
            angles.append(angle)
            XCTAssertLessThan(angle, 12, "a quarter turn is spread over more than a second")
            XCTAssertLessThan(simd_length(b.camera.target - a.camera.target), 0.08)
            XCTAssertLessThan(abs(b.camera.distance - a.camera.distance), 0.1)
        }
        XCTAssertLessThan(angles.first!, 0.2)
        XCTAssertLessThan(angles.last!, 0.01, "it comes to rest")
        // Acceleration stays small, which is what easing means here.
        for (a, b) in zip(angles, angles.dropFirst()) { XCTAssertLessThan(abs(a - b), 1.5) }
    }

    func testTheCameraTurnsToEachPartAsTheWorkReachesIt() throws {
        let list = frames(60)
        let shots = TimelapseDirector.shots(for: list, bounds: box, camera: Camera(), viewSize: view)
        // A quarter of the way through a beat's hold, the camera should be looking as the artist was.
        var checked = 0
        var lastStep = -1
        for shot in shots where shot.frameIndex >= 0 && shot.frameIndex != lastStep {
            lastStep = shot.frameIndex
            guard shot.frameIndex % 12 == 2, shot.frameIndex < list.count - 2 else { continue }
            let want = list[shot.frameIndex].orientation
            let delta = simd_mul(shot.camera.orientation, want.inverse)
            XCTAssertLessThan(2 * acos(min(abs(delta.vector.w), 1)) * 180 / .pi, 40, "step \(shot.frameIndex)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 2)
    }

    func testEvenAShortSessionTurnsToTheSideTheArtistMovedTo() {
        var list = frames(4, turning: false)
        list[3].orientation = ViewPreset.left.orientation
        let shots = TimelapseDirector.shots(for: list, bounds: box, camera: Camera(), viewSize: view)
        let step = shots.first { $0.frameIndex == 3 }!
        let delta = simd_mul(step.camera.orientation, ViewPreset.left.orientation.inverse)
        XCTAssertLessThan(2 * acos(min(abs(delta.vector.w), 1)) * 180 / .pi, 10, "already there when that step appears")
    }

    func testItEndsWithOneFullTurnBackWhereTheTurnStarted() {
        let shots = TimelapseDirector.shots(for: frames(12, turning: false), bounds: box, camera: Camera(), viewSize: view)
        let outro = Int(TimelapseDirector.outro) * TimelapseDirector.framesPerSecond
        let hold = Int(TimelapseDirector.hold * Float(TimelapseDirector.framesPerSecond))
        let start = shots[shots.count - hold - outro].camera.orientation
        let middle = shots[shots.count - hold - outro / 2].camera.orientation
        let end = shots[shots.count - 1].camera.orientation
        XCTAssertLessThan(2 * acos(min(abs(simd_mul(end, start.inverse).vector.w), 1)) * 180 / .pi, 5, "all the way round")
        XCTAssertGreaterThan(2 * acos(min(abs(simd_mul(middle, start.inverse).vector.w), 1)) * 180 / .pi, 120, "by way of the far side")
        XCTAssertEqual(shots[shots.count - 1].camera.target, box.center)
    }
}
