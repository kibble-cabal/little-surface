import XCTest
import simd
@testable import LittleSurfaceCore

final class SculptUpdateTests: XCTestCase {
    private func patchedEngine() throws -> RetopoEngine {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(420, 340), to: Vec2(600, 340))
        Fixtures.draw(engine, from: Vec2(420, 430), to: Vec2(600, 430))
        engine.commitFillSuggestion()
        XCTAssertGreaterThan(engine.mesh.faceCount, 0)
        return engine
    }

    private func replacement(for engine: RetopoEngine, radius: Float, center: Vec3 = .zero) throws -> (SourceObject, TriangleBVH) {
        let id = engine.sources[0].id
        let sphere = Fixtures.sphere(radius: radius, center: center)
        let object = SourceObject(id: id, name: engine.sources[0].name, positions: sphere.positions, normals: sphere.normals, indices: sphere.indices)
        return (object, try XCTUnwrap(TriangleBVH(object: object)))
    }

    func testTopologyFollowsAChangedSurfaceAndKeepsItsConnectivity() throws {
        let engine = try patchedEngine()
        let loops = engine.mesh.faceLoops
        let edges = engine.mesh.edgeEnds
        let partners = engine.mesh.mirrorPartner
        let (object, bvh) = try replacement(for: engine, radius: 1.2)
        let result = try XCTUnwrap(engine.updateSource(id: object.id, with: object, bvh: bvh))
        XCTAssertEqual(result.movedVertices, engine.mesh.vertexCount)
        XCTAssertEqual(result.unreachableVertices, 0)
        XCTAssertEqual(result.sizeRatio, 1.2, accuracy: 0.02)
        XCTAssertEqual(engine.mesh.faceLoops, loops)
        XCTAssertEqual(engine.mesh.edgeEnds, edges)
        XCTAssertEqual(engine.mesh.mirrorPartner, partners)
        for v in engine.mesh.aliveVertices {
            // The surface is faceted, so a point on it can sit just inside the true sphere.
            XCTAssertEqual(simd_length(engine.mesh.position(v)), 1.2, accuracy: 0.01)
        }
        assertValid(engine.mesh)
        XCTAssertEqual(engine.sources[0].positions, object.positions)
    }

    func testVerticesTravelAlongTheNormalSoLinesStayInOrder() throws {
        let engine = try patchedEngine()
        let before = engine.mesh.positions
        let (object, bvh) = try replacement(for: engine, radius: 1.2)
        engine.updateSource(id: object.id, with: object, bvh: bvh)
        for v in engine.mesh.aliveVertices {
            let was = simd_normalize(before[Int(v)]), now = simd_normalize(engine.mesh.position(v))
            XCTAssertGreaterThan(simd_dot(was, now), 0.9995, "growing a sphere moves points straight out")
        }
    }

    func testABumpDoesNotPullNeighboursOutOfLine() throws {
        // A plane, replaced by one higher up with a ridge beside the line. The nearest point on the
        // new surface would drag vertices sideways onto the ridge; following the normal doesn't.
        let flat = Fixtures.plane(size: 4, divisions: 60)
        let engine = Fixtures.engine(with: flat, camera: Fixtures.frontCamera())
        let middle = engine.camera.viewSize.x / 2
        Fixtures.draw(engine, from: Vec2(middle - 150, middle), to: Vec2(middle + 150, middle), steps: 30)
        let before = engine.mesh.aliveVertices.map { engine.mesh.position($0) }
        XCTAssertGreaterThan(before.count, 4)
        var raised = flat.positions
        for i in raised.indices {
            let y = raised[i].y
            raised[i].z = 0.3 + 0.28 * exp(-pow((y - 0.4) / 0.12, 2))
        }
        let object = SourceObject(id: engine.sources[0].id, name: "Raised", positions: raised, indices: flat.indices)
        engine.updateSource(id: object.id, with: object, bvh: try XCTUnwrap(TriangleBVH(object: object)))
        for (v, was) in zip(engine.mesh.aliveVertices, before) {
            let now = engine.mesh.position(v)
            XCTAssertEqual(now.x, was.x, accuracy: 0.001)
            XCTAssertEqual(now.y, was.y, accuracy: 0.001)
            XCTAssertEqual(now.z, 0.3, accuracy: 0.02)
        }
    }

    func testOneUndoPutsBackTheOldSurfaceAndPositionsAndRedoReturns() throws {
        let engine = try patchedEngine()
        let oldPositions = engine.mesh.positions
        let oldSurface = engine.sources[0].positions
        let oldRevision = engine.sources[0].geometryRevision
        let (object, bvh) = try replacement(for: engine, radius: 1.2)
        engine.updateSource(id: object.id, with: object, bvh: bvh)
        let newPositions = engine.mesh.positions
        let newRevision = engine.sources[0].geometryRevision
        XCTAssertNotEqual(newRevision, oldRevision, "the renderer needs to know to redraw it")

        engine.undo()
        XCTAssertEqual(engine.mesh.positions, oldPositions)
        XCTAssertEqual(engine.sources[0].positions, oldSurface)
        XCTAssertEqual(engine.sources[0].geometryRevision, oldRevision)
        let onOld = try XCTUnwrap(engine.projector?.closest(to: Vec3(0, 0, 3)))
        XCTAssertEqual(simd_length(onOld.position), 1, accuracy: 0.01, "drawing goes back to the old surface")

        engine.redo()
        XCTAssertEqual(engine.mesh.positions, newPositions)
        XCTAssertEqual(engine.sources[0].positions, object.positions)
        let onNew = try XCTUnwrap(engine.projector?.closest(to: Vec3(0, 0, 3)))
        XCTAssertEqual(simd_length(onNew.position), 1.2, accuracy: 0.01)
    }

    func testUndoAcrossEditsDoneOnEitherSurface() throws {
        let engine = try patchedEngine()
        let depthBefore = engine.history.undoStack.count
        let (object, bvh) = try replacement(for: engine, radius: 1.2)
        engine.updateSource(id: object.id, with: object, bvh: bvh)
        Fixtures.draw(engine, from: Vec2(420, 500), to: Vec2(600, 500))
        let afterDrawing = engine.mesh.positions
        // Back past the drawing: the surface stays new. Back past the update: it goes old.
        engine.undo()
        XCTAssertEqual(engine.sources[0].positions, object.positions)
        engine.undo()
        XCTAssertNotEqual(engine.sources[0].positions, object.positions)
        XCTAssertEqual(engine.history.undoStack.count, depthBefore)
        engine.undo()
        XCTAssertNotEqual(engine.sources[0].positions, object.positions)
        engine.redo(); engine.redo(); engine.redo()
        XCTAssertEqual(engine.mesh.positions, afterDrawing)
        XCTAssertEqual(engine.sources[0].positions, object.positions)
    }

    func testAFarAwaySculptLeavesVerticesWhereTheyWereAndSelectsThem() throws {
        let engine = try patchedEngine()
        let positions = engine.mesh.positions
        let count = engine.mesh.vertexCount
        let (object, bvh) = try replacement(for: engine, radius: 0.2, center: Vec3(40, 0, 0))
        let result = try XCTUnwrap(engine.updateSource(id: object.id, with: object, bvh: bvh))
        XCTAssertEqual(result.movedVertices, 0)
        XCTAssertEqual(result.unreachableVertices, count)
        XCTAssertEqual(engine.mesh.positions, positions)
        XCTAssertEqual(engine.selection.vertices.count, count)
        XCTAssertEqual(engine.selection.mode, .vertex)
    }

    func testASourceThatIsntASurfaceSwapsWithoutMovingAnything() throws {
        let engine = try patchedEngine()
        let positions = engine.mesh.positions
        engine.setSourceSnapTarget(id: engine.sources[0].id, false)
        let (object, bvh) = try replacement(for: engine, radius: 1.2)
        let result = try XCTUnwrap(engine.updateSource(id: object.id, with: object, bvh: bvh))
        XCTAssertFalse(result.snapped)
        XCTAssertEqual(engine.mesh.positions, positions)
        XCTAssertFalse(engine.sources[0].isSnapTarget, "its settings are kept")
    }

    func testSymmetryKeepsCenterlineVerticesOnThePlane() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setSymmetryEnabled(true)
        let middle = engine.camera.viewSize.x / 2
        Fixtures.draw(engine, from: Vec2(middle, 300), to: Vec2(middle, 460))
        let centered = engine.mesh.aliveVertices.filter { engine.mesh.mirrorPartner[Int($0)] == $0 }
        XCTAssertFalse(centered.isEmpty)
        let (object, bvh) = try replacement(for: engine, radius: 1.1, center: Vec3(0.05, 0, 0))
        engine.updateSource(id: object.id, with: object, bvh: bvh)
        for v in centered { XCTAssertEqual(engine.mesh.position(v).x, 0, accuracy: 1e-5) }
    }

    func testAnUpdatedSculptSavesAndReopens() throws {
        let engine = try patchedEngine()
        let (object, bvh) = try replacement(for: engine, radius: 1.2)
        engine.updateSource(id: object.id, with: object, bvh: bvh)
        let reopened = try ProjectCodec.decode(ProjectCodec.encode(engine.makeSnapshot()))
        XCTAssertEqual(reopened.sources[0].positions, object.positions)
        XCTAssertEqual(reopened.mesh.positions, engine.mesh.positions)
    }

    func testPartsMergeIntoOneObject() {
        let a = Fixtures.sphere(rings: 6, segments: 8)
        let b = Fixtures.plane(divisions: 2)
        let merged = SourceObject.merged([a, b], name: "Both")
        XCTAssertEqual(merged.positions.count, a.positions.count + b.positions.count)
        XCTAssertEqual(merged.triangleCount, a.triangleCount + b.triangleCount)
        XCTAssertEqual(merged.indices.max(), UInt32(merged.positions.count - 1))
    }
}
