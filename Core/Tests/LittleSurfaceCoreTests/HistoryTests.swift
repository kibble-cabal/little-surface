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
