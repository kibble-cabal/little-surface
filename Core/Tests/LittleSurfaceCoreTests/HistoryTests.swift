import XCTest
import simd
@testable import LittleSurfaceCore

final class HistoryTests: XCTestCase {
    func testUndoRestoresConnectivityPositionsAndSelection() throws {
        let engine = RetopoEngine()
        engine.perform("seed") { mesh, selection in
            let (grid, _) = Fixtures.grid(columns: 2, rows: 2)
            mesh = grid
            selection.mode = .face
            selection.faces = Set(grid.aliveFaces.prefix(2))
        }
        let before = engine.mesh
        let beforeSelection = engine.selection
        engine.deleteSelection()
        XCTAssertEqual(engine.mesh.faceCount, 2)
        XCTAssertTrue(engine.selection.isEmpty)
        engine.undo()
        XCTAssertEqual(engine.mesh.faceLoops, before.faceLoops)
        XCTAssertEqual(engine.mesh.edgeEnds, before.edgeEnds)
        XCTAssertEqual(engine.mesh.positions, before.positions)
        XCTAssertEqual(engine.mesh.vertexAlive, before.vertexAlive)
        XCTAssertEqual(engine.selection, beforeSelection)
        assertValid(engine.mesh)
        engine.redo()
        XCTAssertEqual(engine.mesh.faceCount, 2)
        XCTAssertTrue(engine.selection.isEmpty)
        assertValid(engine.mesh)
    }

    func testFailedEditDoesNotEnterHistory() throws {
        let engine = RetopoEngine()
        engine.perform("seed") { mesh, _ in mesh = Fixtures.grid(columns: 1, rows: 1).mesh }
        let depth = engine.history.undoStack.count
        let mesh = engine.mesh
        let ok = engine.perform("bad") { mesh, _ in
            mesh.deleteVertices(Set(mesh.aliveVertices))
            throw MeshError.invalid("nope")
        }
        XCTAssertFalse(ok)
        XCTAssertEqual(engine.history.undoStack.count, depth)
        XCTAssertEqual(engine.mesh.vertexCount, mesh.vertexCount, "the half-done work was discarded")
        XCTAssertEqual(engine.message?.text, "nope")
    }

    func testNewEditClearsRedo() throws {
        let engine = RetopoEngine()
        engine.perform("a") { mesh, _ in _ = mesh.addVertex(.zero) }
        engine.perform("b") { mesh, _ in _ = mesh.addVertex(Vec3(1, 0, 0)) }
        engine.undo()
        XCTAssertTrue(engine.canRedo)
        engine.perform("c") { mesh, _ in _ = mesh.addVertex(Vec3(2, 0, 0)) }
        XCTAssertFalse(engine.canRedo)
    }

    func testWholeStrokeIsOneUndoStep() throws {
        let engine = Fixtures.engine(with: Fixtures.plane(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(300, 500), to: Vec2(700, 500))
        XCTAssertEqual(engine.history.undoStack.count, 1)
        XCTAssertGreaterThan(engine.mesh.edgeCount, 2)
        engine.undo()
        XCTAssertEqual(engine.mesh.edgeCount, 0)
    }

    func testWholeBrushStrokeIsOneUndoStep() throws {
        let engine = Fixtures.engine(with: Fixtures.plane(), camera: Fixtures.frontCamera())
        engine.perform("seed") { mesh, _ in
            mesh = Fixtures.grid(columns: 6, rows: 6, spacing: 0.1).mesh
            for v in mesh.aliveVertices { mesh.setPosition(v, mesh.position(v) - Vec3(0.3, 0.3, 0)) }
        }
        let depth = engine.history.undoStack.count
        let before = engine.mesh.positions
        engine.setTool(.moveBrush)
        engine.tools.brush.radiusPoints = 100
        Fixtures.draw(engine, from: Vec2(450, 500), to: Vec2(600, 500), steps: 30)
        XCTAssertEqual(engine.history.undoStack.count, depth + 1)
        XCTAssertNotEqual(engine.mesh.positions, before)
        engine.undo()
        XCTAssertEqual(engine.mesh.positions, before)
    }

    func testVersionsAdvanceAcrossUndoSoRendererRefreshes() throws {
        let engine = RetopoEngine()
        engine.perform("a") { mesh, _ in _ = mesh.addVertex(.zero) }
        var seen = Set<UInt64>([engine.mesh.topologyVersion])
        engine.perform("b") { mesh, _ in _ = mesh.addVertex(Vec3(1, 0, 0)) }
        XCTAssertTrue(seen.insert(engine.mesh.topologyVersion).inserted)
        engine.undo()
        XCTAssertTrue(seen.insert(engine.mesh.topologyVersion).inserted, "an undo must not reuse a version number")
        engine.redo()
        XCTAssertTrue(seen.insert(engine.mesh.topologyVersion).inserted)
    }

    func testByteBudgetTrimsOldestButKeepsARecentStep() throws {
        var history = EditHistory(byteBudget: 2_000, maxEntries: 1000)
        var mesh = Mesh()
        for i in 0..<400 { mesh.addVertex(Vec3(Float(i), 0, 0)) }
        for i in 0..<50 {
            history.record(before: EditSnapshot(mesh: mesh, selection: Selection()), label: "\(i)")
            mesh.setPosition(0, Vec3(Float(i), 1, 0))
        }
        XCTAssertLessThan(history.undoStack.count, 50)
        XCTAssertGreaterThanOrEqual(history.undoStack.count, 1)
        XCTAssertEqual(history.undoStack.last?.label, "49")
    }

    func testEntryLimit() throws {
        var history = EditHistory(byteBudget: .max, maxEntries: 3)
        for i in 0..<10 { history.record(before: EditSnapshot(mesh: Mesh(), selection: Selection()), label: "\(i)") }
        XCTAssertEqual(history.undoStack.map(\.label), ["7", "8", "9"])
    }

    func testRealisticSessionStaysFarWithinBudget() throws {
        // A 10,000-face mesh with moves: copy-on-write means most snapshots add only positions.
        var history = EditHistory()
        var (mesh, _) = Fixtures.grid(columns: 100, rows: 100, spacing: 0.01)
        for i in 0..<100 {
            history.record(before: EditSnapshot(mesh: mesh, selection: Selection()), label: "move \(i)")
            mesh.setPosition(VertexID(i), Vec3(0, 0, 1))
        }
        XCTAssertEqual(history.undoStack.count, 100)
        XCTAssertLessThan(history.usedBytes, 40 * 1024 * 1024)
    }
}

/// Undo and redo checked against a record of what every state looked like.
final class UndoSessionTests: XCTestCase {
    private struct State: Equatable {
        var positions: [Vec3]
        var vertexAlive: [Bool]
        var edgeEnds: [SIMD2<Int32>]
        var edgeAlive: [Bool]
        var faceLoops: [[VertexID]]
        var faceAlive: [Bool]
        var selection: Selection
    }

    private func state(_ engine: RetopoEngine) -> State {
        let m = engine.mesh
        return State(positions: m.positions, vertexAlive: m.vertexAlive, edgeEnds: m.edgeEnds, edgeAlive: m.edgeAlive, faceLoops: m.faceLoops, faceAlive: m.faceAlive, selection: engine.selection)
    }

    /// A deterministic generator, so a failure repeats.
    private struct Numbers: RandomNumberGenerator {
        var value: UInt64
        mutating func next() -> UInt64 {
            value = value &* 6364136223846793005 &+ 1442695040888963407
            return value ^ (value >> 29)
        }
    }

    /// One action, which makes at most one undo step.
    private func edit(_ engine: RetopoEngine, using numbers: inout Numbers) {
        let x = Float.random(in: 340...620, using: &numbers), y = Float.random(in: 240...520, using: &numbers)
        switch Int.random(in: 0..<6, using: &numbers) {
        case 0, 1:
            engine.setTool(.drawEdges)
            Fixtures.draw(engine, from: Vec2(x, y), to: Vec2(x + 90, y + 40), steps: 12)
        case 2:
            engine.setTool(.moveBrush)
            Fixtures.draw(engine, from: Vec2(x, y), to: Vec2(x + 30, y), steps: 6)
        case 3:
            engine.setTool(.erase)
            Fixtures.draw(engine, from: Vec2(x, y), to: Vec2(x + 30, y), steps: 6)
        case 4:
            let chosen = engine.mesh.aliveVertices.shuffled(using: &numbers).prefix(2)
            engine.perform("Delete some") { mesh, _ in mesh.deleteVertices(Set(chosen)) }
        default:
            let chosen = Set(engine.mesh.aliveVertices.shuffled(using: &numbers).prefix(4))
            engine.perform("Choose some") { _, selection in
                selection.mode = .vertex
                selection.vertices = chosen
            }
        }
    }

    func testRandomEditsAndUndoRedoAlwaysLandOnARecordedState() throws {
        for seed in 1...6 {
            var numbers = Numbers(value: UInt64(seed))
            let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
            // Every state so far, and which of them undo has stepped back to.
            var states = [state(engine)]
            var position = 0
            for _ in 0..<80 {
                switch Int.random(in: 0..<10, using: &numbers) {
                case 0..<5:
                    let depth = engine.history.undoStack.count
                    let before = state(engine)
                    edit(engine, using: &numbers)
                    let added = engine.history.undoStack.count - depth
                    XCTAssertLessThanOrEqual(added, 1, "seed \(seed)")
                    if added == 1 {
                        states.removeSubrange((position + 1)...)
                        states.append(state(engine))
                        position += 1
                        XCTAssertFalse(engine.canRedo)
                    } else {
                        XCTAssertEqual(state(engine), before, "no undo step means nothing changed (seed \(seed))")
                    }
                case 5..<8:
                    XCTAssertEqual(engine.canUndo, position > 0)
                    engine.undo()
                    position = max(position - 1, 0)
                    XCTAssertEqual(state(engine), states[position], "undo (seed \(seed))")
                default:
                    XCTAssertEqual(engine.canRedo, position + 1 < states.count)
                    engine.redo()
                    position = min(position + 1, states.count - 1)
                    XCTAssertEqual(state(engine), states[position], "redo (seed \(seed))")
                }
                assertValid(engine.mesh)
            }
        }
    }

    func testUndoMidBrushCancelsTheBrushAndKeepsEarlierWork() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(420, 380), to: Vec2(600, 380))
        let drawn = engine.mesh.positions
        let depth = engine.history.undoStack.count
        engine.setTool(.moveBrush)
        engine.pencilBegan(at: Vec2(500, 380))
        for x in stride(from: Float(500), to: 540, by: 4) { engine.pencilMoved(to: Vec2(x, 400)) }
        XCTAssertNotEqual(engine.mesh.positions, drawn, "the brush moved something, so there's something to take back")
        engine.undo()
        XCTAssertEqual(engine.mesh.positions, drawn)
        XCTAssertEqual(engine.history.undoStack.count, depth, "the edit before the brush is still there")
        XCTAssertFalse(engine.canRedo)
        engine.pencilEnded(at: Vec2(540, 400))
        XCTAssertEqual(engine.history.undoStack.count, depth, "lifting afterwards adds nothing")
    }

    func testUndoMidDragPutsVerticesBack() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(420, 380), to: Vec2(600, 380))
        let drawn = engine.mesh.positions
        let depth = engine.history.undoStack.count
        engine.setTool(.select)
        let v = try XCTUnwrap(engine.mesh.aliveVertices.first { engine.camera.project(engine.mesh.position($0)) != nil })
        let start = try XCTUnwrap(engine.camera.project(engine.mesh.position(v))).screen
        engine.pencilBegan(at: start)
        for step in 1...8 { engine.pencilMoved(to: start + Vec2(Float(step) * 6, 0)) }
        engine.undo()
        XCTAssertEqual(engine.mesh.positions, drawn)
        XCTAssertEqual(engine.history.undoStack.count, depth)
    }

    func testRedoMidBrushDoesNotKeepHalfABrush() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(420, 380), to: Vec2(600, 380))
        let drawn = engine.mesh.positions
        Fixtures.draw(engine, from: Vec2(420, 300), to: Vec2(600, 300))
        let both = engine.mesh.positions
        engine.undo()
        XCTAssertEqual(engine.mesh.positions.filter { _ in true }.count, drawn.count)
        engine.setTool(.moveBrush)
        engine.pencilBegan(at: Vec2(500, 380))
        for x in stride(from: Float(500), to: 540, by: 4) { engine.pencilMoved(to: Vec2(x, 400)) }
        engine.redo()
        XCTAssertEqual(engine.mesh.positions, both, "redo starts from the state before the brush")
    }

    func testBrushOverEmptySpaceAddsNoUndoStep() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(420, 380), to: Vec2(600, 380))
        let depth = engine.history.undoStack.count
        engine.setTool(.moveBrush)
        Fixtures.draw(engine, from: Vec2(10, 10), to: Vec2(60, 10), steps: 6)
        XCTAssertEqual(engine.history.undoStack.count, depth)
    }

    func testUndoTakesBackAFaceCornerBeforeAnyEdit() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(420, 380), to: Vec2(600, 380))
        let depth = engine.history.undoStack.count
        engine.setTool(.face)
        for point in [Vec2(500, 300), Vec2(560, 300)] {
            engine.pencilBegan(at: point)
            engine.pencilEnded(at: point)
        }
        XCTAssertEqual(engine.faceCorners.count, 2)
        engine.undo()
        XCTAssertEqual(engine.faceCorners.count, 1)
        engine.undo()
        XCTAssertEqual(engine.faceCorners.count, 0)
        XCTAssertEqual(engine.history.undoStack.count, depth, "no edit was taken back")
        engine.undo()
        XCTAssertEqual(engine.history.undoStack.count, depth - 1)
    }

    func testMovingAVertexClearsOffersLikeAnyOtherEdit() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(420, 340), to: Vec2(600, 340))
        Fixtures.draw(engine, from: Vec2(420, 430), to: Vec2(600, 430))
        XCTAssertNotNil(engine.fillSuggestion)
        let generation = engine.editGeneration
        engine.setTool(.select)
        let v = engine.mesh.aliveVertices[0]
        let start = try XCTUnwrap(engine.camera.project(engine.mesh.position(v))).screen
        engine.pencilBegan(at: start)
        for step in 1...8 { engine.pencilMoved(to: start + Vec2(0, Float(step) * 3)) }
        engine.pencilEnded(at: start + Vec2(0, 24))
        XCTAssertGreaterThan(engine.editGeneration, generation)
        XCTAssertNil(engine.fillSuggestion, "an offer built on the old position would no longer fit")
    }

    func testMemoryPressureDropsOldestStepsAndUndoStillWorks() throws {
        let engine = RetopoEngine()
        var history = EditHistory(byteBudget: 4000)
        for i in 0..<30 {
            var mesh = Mesh()
            for j in 0...i { _ = mesh.addVertex(Vec3(Float(j), 0, 0)) }
            history.record(before: EditSnapshot(mesh: mesh, selection: Selection()), label: "step \(i)")
        }
        let before = history.undoStack.count
        history.shrink(toFractionOfBudget: 0.25)
        XCTAssertLessThan(history.undoStack.count, before)
        XCTAssertGreaterThanOrEqual(history.undoStack.count, 1)
        XCTAssertEqual(history.undoLabel, "step 29", "the newest step survives")
        engine.perform("a") { mesh, _ in _ = mesh.addVertex(.zero) }
        engine.releaseUndoMemory()
        XCTAssertTrue(engine.canUndo)
    }
}
