import XCTest
import simd
@testable import LittleSurfaceCore

final class QuadStripTests: XCTestCase {
    private func straightPath(on projector: SurfaceProjector, from a: Vec3, to b: Vec3, points: Int = 21) -> ProcessedPath {
        let pts = (0..<points).map { i -> StrokePoint in
            let p = simd_mix(a, b, Vec3(repeating: Float(i) / Float(points - 1)))
            let hit = projector.closest(to: p)!
            return StrokePoint(position: hit.position, normal: hit.normal)
        }
        return ProcessedPath(points: pts, length: StrokeProcessor.polylineLength(pts), endGap: simd_length(a - b), canClose: false)
    }

    func testStripHasExpectedCountsAndWidth() throws {
        let plane = Fixtures.plane()
        let projector = Fixtures.projector(plane)
        let path = straightPath(on: projector, from: Vec3(-1, 0, 0), to: Vec3(1, 0, 0))
        var parameters = QuadStripParameters()
        parameters.width = 0.4
        parameters.segments = 8
        parameters.crossSegments = 2
        let plan = try QuadStripBuilder.plan(path: path, parameters: parameters, mesh: Mesh(), projector: projector, snapRadius: 0)
        XCTAssertEqual(plan.faces.count, 16)
        XCTAssertEqual(plan.nodes.count, 27)
        var mesh = Mesh()
        _ = try PlanApplier.apply(plan, to: &mesh)
        XCTAssertEqual(mesh.faceCount, 16)
        XCTAssertEqual(MeshStatistics(mesh).quads, 16)
        let box = mesh.bounds
        XCTAssertEqual(box.extent.y, 0.4, accuracy: 1e-3)
        XCTAssertEqual(box.extent.x, 2, accuracy: 1e-3)
        for f in mesh.aliveFaces { XCTAssertGreaterThan(mesh.faceNormal(f).z, 0.9, "faces point out of the surface") }
        assertValid(mesh)
        assertConsistentWinding(mesh)
    }

    func testSpacingDerivesSegmentCount() throws {
        let projector = Fixtures.projector(Fixtures.plane())
        let path = straightPath(on: projector, from: Vec3(-1, 0, 0), to: Vec3(1, 0, 0))
        var parameters = QuadStripParameters()
        parameters.width = 0.2
        parameters.segments = 0
        parameters.vertexSpacing = 0.25
        let plan = try QuadStripBuilder.plan(path: path, parameters: parameters, mesh: Mesh(), projector: projector, snapRadius: 0)
        XCTAssertEqual(plan.faces.count, 8)
    }

    func testDirectionKeepsPathAsRail() throws {
        let projector = Fixtures.projector(Fixtures.plane())
        let path = straightPath(on: projector, from: Vec3(-1, 0, 0), to: Vec3(1, 0, 0))
        var parameters = QuadStripParameters()
        parameters.width = 0.5
        parameters.segments = 4
        for (direction, expected) in [(StripDirection.left, Float(0.5)), (.right, Float(-0.5))] {
            parameters.direction = direction
            var mesh = Mesh()
            _ = try PlanApplier.apply(QuadStripBuilder.plan(path: path, parameters: parameters, mesh: Mesh(), projector: projector, snapRadius: 0), to: &mesh)
            let box = mesh.bounds
            XCTAssertEqual(expected > 0 ? box.maxCorner.y : box.minCorner.y, expected, accuracy: 1e-3, "\(direction)")
            XCTAssertEqual(expected > 0 ? box.minCorner.y : box.maxCorner.y, 0, accuracy: 1e-3, "\(direction)")
        }
    }

    func testStripFollowsCurvedSurface() throws {
        let sphere = Fixtures.sphere(rings: 64, segments: 96)
        let projector = Fixtures.projector(sphere)
        let a = simd_normalize(Vec3(-0.7, 0, 0.7)), b = simd_normalize(Vec3(0.7, 0, 0.7))
        let path = straightPath(on: projector, from: a, to: b, points: 33)
        var parameters = QuadStripParameters()
        parameters.width = 0.3
        parameters.segments = 12
        var mesh = Mesh()
        _ = try PlanApplier.apply(QuadStripBuilder.plan(path: path, parameters: parameters, mesh: Mesh(), projector: projector, snapRadius: 0), to: &mesh)
        for v in mesh.aliveVertices { XCTAssertEqual(simd_length(mesh.position(v)), 1, accuracy: 0.01) }
        for f in mesh.aliveFaces { XCTAssertGreaterThan(simd_dot(mesh.faceNormal(f), mesh.faceCenter(f)), 0) }
        assertConsistentWinding(mesh)
    }

    func testClosedStripIsARing() throws {
        let sphere = Fixtures.sphere(rings: 48, segments: 64)
        let projector = Fixtures.projector(sphere)
        let pts = (0..<32).map { i -> StrokePoint in
            let a = 2 * Float.pi * Float(i) / 32
            let hit = projector.closest(to: Vec3(cos(a), 0, sin(a)))!
            return StrokePoint(position: hit.position, normal: hit.normal)
        }
        var path = ProcessedPath(points: pts, length: StrokeProcessor.polylineLength(pts), endGap: 0.2, canClose: true)
        path.isClosed = true
        var parameters = QuadStripParameters()
        parameters.width = 0.2
        parameters.segments = 16
        var mesh = Mesh()
        _ = try PlanApplier.apply(QuadStripBuilder.plan(path: path, parameters: parameters, mesh: Mesh(), projector: projector, snapRadius: 0), to: &mesh)
        XCTAssertEqual(mesh.faceCount, 16)
        XCTAssertEqual(mesh.vertexCount, 32)
        XCTAssertEqual(ChainFinder.boundaryLoops(in: mesh).count, 2, "a ring has two open boundaries")
        assertValid(mesh)
        assertConsistentWinding(mesh)
    }

    func testEngineStripPreviewsThenCommits() throws {
        let engine = Fixtures.engine(with: Fixtures.plane(), camera: Fixtures.frontCamera())
        engine.setTool(.quadStrip)
        Fixtures.draw(engine, from: Vec2(300, 500), to: Vec2(700, 500))
        XCTAssertEqual(engine.mesh.faceCount, 0, "a strip waits as a preview")
        XCTAssertGreaterThan(engine.overlay.previewTriangles.count, 0)
        let before = try XCTUnwrap(engine.pendingStrip?.plan?.faces.count)
        engine.tools.strip.segments = before * 2
        engine.rebuildStripPlan()
        XCTAssertEqual(engine.pendingStrip?.plan?.faces.count, before * 2, "changing a parameter changes the preview")
        XCTAssertEqual(engine.mesh.faceCount, 0)
        engine.commitPendingStrip()
        XCTAssertEqual(engine.mesh.faceCount, before * 2)
        engine.undo()
        XCTAssertEqual(engine.mesh.faceCount, 0)
    }
}

final class QuadPatchTests: XCTestCase {
    /// Open wire chain along a line on the surface.
    private func addChain(_ mesh: inout Mesh, from a: Vec3, to b: Vec3, segments: Int) -> BoundaryChain {
        var vertices: [VertexID] = []
        for i in 0...segments {
            vertices.append(mesh.addVertex(simd_mix(a, b, Vec3(repeating: Float(i) / Float(segments)))))
        }
        var edges: [EdgeID] = []
        for i in 0..<segments { edges.append(try! mesh.ensureEdge(vertices[i], vertices[i + 1])) }
        return BoundaryChain(vertices: vertices, edges: edges, isClosed: false)
    }

    private func patch(_ chains: [BoundaryChain], mesh: inout Mesh, parameters: QuadPatchParameters = QuadPatchParameters(), projector: SurfaceProjector?) throws -> (PatchPlan, PlanResult) {
        let plan = try QuadPatchBuilder.plan(chains: chains, parameters: parameters, mesh: mesh, projector: projector)
        let result = try PlanApplier.apply(plan.plan, to: &mesh, projector: projector)
        return (plan, result)
    }

    func testTwoEqualChains() throws {
        let projector = Fixtures.projector(Fixtures.plane())
        var mesh = Mesh()
        let a = addChain(&mesh, from: Vec3(-1, -0.5, 0), to: Vec3(1, -0.5, 0), segments: 4)
        let b = addChain(&mesh, from: Vec3(-1, 0.5, 0), to: Vec3(1, 0.5, 0), segments: 4)
        var parameters = QuadPatchParameters()
        parameters.rows = 2
        let (plan, _) = try patch([a, b], mesh: &mesh, parameters: parameters, projector: projector)
        XCTAssertEqual(plan.columns, 4)
        XCTAssertEqual(plan.rows, 2)
        XCTAssertEqual(mesh.faceCount, 8)
        XCTAssertEqual(MeshStatistics(mesh).quads, 8)
        XCTAssertEqual(mesh.vertexCount, 15, "the drawn chains' vertices are reused")
        XCTAssertEqual(MeshValidator.connectedComponents(mesh).count, 1)
        for f in mesh.aliveFaces { XCTAssertGreaterThan(mesh.faceNormal(f).z, 0.9) }
        assertValid(mesh)
        assertConsistentWinding(mesh)
    }

    func testChainsDrawnInOppositeDirectionsDontTwist() throws {
        let projector = Fixtures.projector(Fixtures.plane())
        var mesh = Mesh()
        let a = addChain(&mesh, from: Vec3(-1, -0.5, 0), to: Vec3(1, -0.5, 0), segments: 4)
        let b = addChain(&mesh, from: Vec3(1, 0.5, 0), to: Vec3(-1, 0.5, 0), segments: 4)
        var parameters = QuadPatchParameters()
        parameters.rows = 1
        _ = try patch([a, b], mesh: &mesh, parameters: parameters, projector: projector)
        let widths = mesh.aliveFaces.map { mesh.bounds.extent.x / 4 + 0 * Float($0) }
        XCTAssertEqual(widths.count, 4)
        // Untwisted rungs are straight up: each quad spans only one column.
        for f in mesh.aliveFaces {
            let box = AABB(points: mesh.facePositions(f))
            XCTAssertEqual(box.extent.x, 0.5, accuracy: 1e-3)
        }
    }

    func testMismatchedCountsSplitTheShorterChain() throws {
        let projector = Fixtures.projector(Fixtures.plane())
        var mesh = Mesh()
        let a = addChain(&mesh, from: Vec3(-1, -0.5, 0), to: Vec3(1, -0.5, 0), segments: 6)
        let b = addChain(&mesh, from: Vec3(-1, 0.5, 0), to: Vec3(1, 0.5, 0), segments: 3)
        var parameters = QuadPatchParameters()
        parameters.rows = 1
        let (plan, _) = try patch([a, b], mesh: &mesh, parameters: parameters, projector: projector)
        XCTAssertEqual(plan.boundarySplits, 3)
        XCTAssertEqual(mesh.faceCount, 6)
        XCTAssertEqual(MeshStatistics(mesh).quads, 6)
        XCTAssertEqual(mesh.vertexCount, 14)
        assertValid(mesh)
    }

    func testMismatchedCountsCanBeRefused() throws {
        var mesh = Mesh()
        let a = addChain(&mesh, from: Vec3(-1, -0.5, 0), to: Vec3(1, -0.5, 0), segments: 6)
        let b = addChain(&mesh, from: Vec3(-1, 0.5, 0), to: Vec3(1, 0.5, 0), segments: 3)
        var parameters = QuadPatchParameters()
        parameters.matchVertexCounts = false
        XCTAssertThrowsError(try QuadPatchBuilder.plan(chains: [a, b], parameters: parameters, mesh: mesh, projector: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("6 segments"))
        }
    }

    func testDensityMultipliesColumns() throws {
        var mesh = Mesh()
        let a = addChain(&mesh, from: Vec3(-1, -0.5, 0), to: Vec3(1, -0.5, 0), segments: 3)
        let b = addChain(&mesh, from: Vec3(-1, 0.5, 0), to: Vec3(1, 0.5, 0), segments: 3)
        var parameters = QuadPatchParameters()
        parameters.columnDensity = 2
        parameters.rows = 1
        let (plan, _) = try patch([a, b], mesh: &mesh, parameters: parameters, projector: nil)
        XCTAssertEqual(plan.columns, 6)
        XCTAssertEqual(mesh.faceCount, 6)
        assertValid(mesh)
    }

    func testAutoRowsGiveRoughlySquareQuads() throws {
        var mesh = Mesh()
        let a = addChain(&mesh, from: Vec3(-1, -1, 0), to: Vec3(1, -1, 0), segments: 4)
        let b = addChain(&mesh, from: Vec3(-1, 1, 0), to: Vec3(1, 1, 0), segments: 4)
        let plan = try QuadPatchBuilder.plan(chains: [a, b], parameters: QuadPatchParameters(), mesh: mesh, projector: nil)
        XCTAssertEqual(plan.rows, 4)
    }

    func testInteriorConformsToCurvedSurface() throws {
        let sphere = Fixtures.sphere(rings: 96, segments: 128)
        let projector = Fixtures.projector(sphere)
        var mesh = Mesh()
        func onSphere(_ p: Vec3) -> Vec3 { projector.closest(to: p)!.position }
        var verticesA: [VertexID] = [], verticesB: [VertexID] = []
        for i in 0...8 {
            let t = Float(i) / 8 - 0.5
            verticesA.append(mesh.addVertex(onSphere(simd_normalize(Vec3(t, -0.4, 1)))))
            verticesB.append(mesh.addVertex(onSphere(simd_normalize(Vec3(t, 0.4, 1)))))
        }
        var edgesA: [EdgeID] = [], edgesB: [EdgeID] = []
        for i in 0..<8 {
            edgesA.append(try mesh.ensureEdge(verticesA[i], verticesA[i + 1]))
            edgesB.append(try mesh.ensureEdge(verticesB[i], verticesB[i + 1]))
        }
        var parameters = QuadPatchParameters()
        parameters.rows = 6
        _ = try patch([BoundaryChain(vertices: verticesA, edges: edgesA, isClosed: false), BoundaryChain(vertices: verticesB, edges: edgesB, isClosed: false)], mesh: &mesh, parameters: parameters, projector: projector)
        for v in mesh.aliveVertices { XCTAssertEqual(simd_length(mesh.position(v)), 1, accuracy: 0.01, "interior vertices are projected, not left on the chord") }
        for f in mesh.aliveFaces { XCTAssertGreaterThan(simd_dot(mesh.faceNormal(f), mesh.faceCenter(f)), 0.5) }
        assertConsistentWinding(mesh)
    }

    func testFourSidedPatch() throws {
        let projector = Fixtures.projector(Fixtures.plane())
        var mesh = Mesh()
        let corners = [Vec3(-1, -1, 0), Vec3(1, -1, 0), Vec3(1, 1, 0), Vec3(-1, 1, 0)]
        let cornerIDs = corners.map { mesh.addVertex($0) }
        func side(_ a: Int, _ b: Int, segments: Int) -> BoundaryChain {
            var vertices = [cornerIDs[a]]
            for i in 1..<segments {
                vertices.append(mesh.addVertex(simd_mix(corners[a], corners[b], Vec3(repeating: Float(i) / Float(segments)))))
            }
            vertices.append(cornerIDs[b])
            var edges: [EdgeID] = []
            for i in 0..<segments { edges.append(try! mesh.ensureEdge(vertices[i], vertices[i + 1])) }
            return BoundaryChain(vertices: vertices, edges: edges, isClosed: false)
        }
        let chains = [side(0, 1, segments: 4), side(1, 2, segments: 3), side(2, 3, segments: 4), side(3, 0, segments: 3)]
        let (plan, _) = try patch(chains, mesh: &mesh, projector: projector)
        XCTAssertEqual(plan.columns, 4)
        XCTAssertEqual(plan.rows, 3)
        XCTAssertEqual(mesh.faceCount, 12)
        XCTAssertEqual(mesh.vertexCount, 20)
        XCTAssertEqual(MeshStatistics(mesh).quads, 12)
        XCTAssertEqual(ChainFinder.boundaryLoops(in: mesh).count, 1)
        for f in mesh.aliveFaces { XCTAssertGreaterThan(mesh.faceNormal(f).z, 0.9) }
        assertValid(mesh)
        assertConsistentWinding(mesh)
    }

    func testFourSidedWithOutOfOrderAndReversedChains() throws {
        var mesh = Mesh()
        let corners = [Vec3(-1, -1, 0), Vec3(1, -1, 0), Vec3(1, 1, 0), Vec3(-1, 1, 0)]
        let c = corners.map { mesh.addVertex($0) }
        func edgeChain(_ a: VertexID, _ b: VertexID) throws -> BoundaryChain {
            BoundaryChain(vertices: [a, b], edges: [try mesh.ensureEdge(a, b)], isClosed: false)
        }
        // Sides given out of order, one stated backwards.
        let chains = [try edgeChain(c[0], c[1]), try edgeChain(c[3], c[2]), try edgeChain(c[1], c[2]), try edgeChain(c[3], c[0])]
        let (_, result) = try patch(chains, mesh: &mesh, projector: nil)
        XCTAssertEqual(result.faces.count, 1)
        XCTAssertEqual(mesh.loop(result.faces[0]).count, 4)
    }

    func testFourChainsWithAGapAreExplained() throws {
        var mesh = Mesh()
        let a = addChain(&mesh, from: Vec3(-1, -1, 0), to: Vec3(1, -1, 0), segments: 2)
        let b = addChain(&mesh, from: Vec3(1, -0.9, 0), to: Vec3(1, 1, 0), segments: 2)
        let c = addChain(&mesh, from: Vec3(1, 1.1, 0), to: Vec3(-1, 1, 0), segments: 2)
        let d = addChain(&mesh, from: Vec3(-1, 1.1, 0), to: Vec3(-1, -1.1, 0), segments: 2)
        let before = mesh
        XCTAssertThrowsError(try QuadPatchBuilder.plan(chains: [a, b, c, d], parameters: QuadPatchParameters(), mesh: mesh, projector: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("join"), error.localizedDescription)
        }
        XCTAssertEqual(mesh.faceCount, before.faceCount)
    }

    func testThreeChainsAreExplained() throws {
        var mesh = Mesh()
        let a = addChain(&mesh, from: Vec3(-1, -1, 0), to: Vec3(1, -1, 0), segments: 2)
        let b = addChain(&mesh, from: Vec3(1, -1, 1), to: Vec3(0, 1, 1), segments: 2)
        let c = addChain(&mesh, from: Vec3(0, 1, 2), to: Vec3(-1, -1, 2), segments: 2)
        XCTAssertThrowsError(try QuadPatchBuilder.plan(chains: [a, b, c], parameters: QuadPatchParameters(), mesh: mesh, projector: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("three sides"))
        }
    }

    func testChainsMeetingAtAPointAreExplained() throws {
        var mesh = Mesh()
        let a = addChain(&mesh, from: Vec3(-1, 0, 0), to: Vec3(0, 0, 0), segments: 2)
        var b = addChain(&mesh, from: Vec3(1, 0, 0), to: Vec3(0.5, 0, 0), segments: 1)
        let shared = a.vertices.last!
        let extra = b.vertices[1]
        let e = try mesh.ensureEdge(extra, shared)
        b = BoundaryChain(vertices: b.vertices + [shared], edges: b.edges + [e], isClosed: false)
        XCTAssertThrowsError(try QuadPatchBuilder.plan(chains: [a, b], parameters: QuadPatchParameters(), mesh: mesh, projector: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("single vertex"))
        }
    }

    func testRingBetweenTwoLoops() throws {
        let sphere = Fixtures.sphere(rings: 64, segments: 96)
        let projector = Fixtures.projector(sphere)
        var mesh = Mesh()
        func loop(height: Float, count: Int, phase: Float) throws -> BoundaryChain {
            var vertices: [VertexID] = []
            let radius = sqrt(1 - height * height)
            for i in 0..<count {
                let a = 2 * Float.pi * Float(i) / Float(count) + phase
                vertices.append(mesh.addVertex(Vec3(cos(a) * radius, height, sin(a) * radius)))
            }
            var edges: [EdgeID] = []
            for i in 0..<count { edges.append(try mesh.ensureEdge(vertices[i], vertices[(i + 1) % count])) }
            return BoundaryChain(vertices: vertices, edges: edges, isClosed: true)
        }
        let a = try loop(height: 0.3, count: 16, phase: 0)
        let b = try loop(height: -0.3, count: 16, phase: 0.7)
        var parameters = QuadPatchParameters()
        parameters.rows = 2
        let (plan, _) = try patch([a, b], mesh: &mesh, parameters: parameters, projector: projector)
        XCTAssertEqual(plan.kind, .ring)
        XCTAssertEqual(mesh.faceCount, 32)
        XCTAssertEqual(ChainFinder.boundaryLoops(in: mesh).count, 2)
        for f in mesh.aliveFaces { XCTAssertGreaterThan(simd_dot(mesh.faceNormal(f), mesh.faceCenter(f)), 0) }
        assertValid(mesh)
        assertConsistentWinding(mesh)
    }

    func testClosedLoopFillsWithQuads() throws {
        let projector = Fixtures.projector(Fixtures.plane())
        var mesh = Mesh()
        var vertices: [VertexID] = []
        let n = 12
        // A square loop with four true corners and two vertices along each side.
        let corners = [Vec3(-1, -1, 0), Vec3(1, -1, 0), Vec3(1, 1, 0), Vec3(-1, 1, 0)]
        for c in 0..<4 {
            for k in 0..<3 {
                vertices.append(mesh.addVertex(simd_mix(corners[c], corners[(c + 1) % 4], Vec3(repeating: Float(k) / 3))))
            }
        }
        var edges: [EdgeID] = []
        for i in 0..<n { edges.append(try mesh.ensureEdge(vertices[i], vertices[(i + 1) % n])) }
        let (plan, _) = try patch([BoundaryChain(vertices: vertices, edges: edges, isClosed: true)], mesh: &mesh, projector: projector)
        XCTAssertEqual(plan.kind, .filledLoop)
        XCTAssertEqual(plan.columns, 3, "corners were found at the square's actual corners")
        XCTAssertEqual(plan.rows, 3)
        XCTAssertEqual(mesh.faceCount, 9)
        XCTAssertEqual(MeshStatistics(mesh).quads, 9)
        assertValid(mesh)
        assertConsistentWinding(mesh)
    }

    func testOddLoopGetsOneSplit() throws {
        let projector = Fixtures.projector(Fixtures.plane())
        var mesh = Mesh()
        let positions: [Vec3] = [Vec3(-1, -1, 0), Vec3(0, -1, 0), Vec3(1, -1, 0), Vec3(1, 1, 0), Vec3(-1, 1, 0)]
        let vertices = positions.map { mesh.addVertex($0) }
        var edges: [EdgeID] = []
        for i in 0..<5 { edges.append(try mesh.ensureEdge(vertices[i], vertices[(i + 1) % 5])) }
        let (plan, _) = try patch([BoundaryChain(vertices: vertices, edges: edges, isClosed: true)], mesh: &mesh, projector: projector)
        XCTAssertEqual(plan.boundarySplits, 1)
        XCTAssertEqual(MeshStatistics(mesh).ngons, 0)
        XCTAssertEqual(MeshStatistics(mesh).triangles, 0)
        assertValid(mesh)
    }

    func testPatchAttachesToExistingFaces() throws {
        var (mesh, ids) = Fixtures.grid(columns: 2, rows: 1)
        // Boundary along the top of the grid, plus a new chain above it.
        let topEdges = [try XCTUnwrap(mesh.edge(between: ids[1][0], ids[1][1])), try XCTUnwrap(mesh.edge(between: ids[1][1], ids[1][2]))]
        let top = BoundaryChain(vertices: ids[1], edges: topEdges, isClosed: false)
        let above = addChain(&mesh, from: Vec3(0, 2, 0), to: Vec3(2, 2, 0), segments: 2)
        var parameters = QuadPatchParameters()
        parameters.rows = 1
        _ = try patch([top, above], mesh: &mesh, parameters: parameters, projector: nil)
        XCTAssertEqual(mesh.faceCount, 4)
        assertConsistentWinding(mesh)
        assertValid(mesh)
        for f in mesh.aliveFaces { XCTAssertGreaterThan(mesh.faceNormal(f).z, 0.9, "matches the winding of what it attached to") }
    }

    func testSplittingABoundaryThatHasAFaceNotesTheNgon() throws {
        var (mesh, ids) = Fixtures.grid(columns: 1, rows: 1)
        let top = BoundaryChain(vertices: ids[1], edges: [try XCTUnwrap(mesh.edge(between: ids[1][0], ids[1][1]))], isClosed: false)
        let above = addChain(&mesh, from: Vec3(0, 2, 0), to: Vec3(1, 2, 0), segments: 2)
        var parameters = QuadPatchParameters()
        parameters.rows = 1
        let plan = try QuadPatchBuilder.plan(chains: [top, above], parameters: parameters, mesh: mesh, projector: nil)
        XCTAssertTrue(plan.plan.notes.contains { $0.contains("n-gon") })
        _ = try PlanApplier.apply(plan.plan, to: &mesh)
        assertValid(mesh)
        XCTAssertEqual(MeshStatistics(mesh).ngons, 1)
    }

    func testExistingWireSideIsReplacedByRows() throws {
        var mesh = Mesh()
        let a = addChain(&mesh, from: Vec3(-1, -1, 0), to: Vec3(1, -1, 0), segments: 2)
        let b = addChain(&mesh, from: Vec3(-1, 1, 0), to: Vec3(1, 1, 0), segments: 2)
        try mesh.ensureEdge(a.vertices[0], b.vertices[0])
        var parameters = QuadPatchParameters()
        parameters.rows = 2
        _ = try patch([a, b], mesh: &mesh, parameters: parameters, projector: nil)
        XCTAssertEqual(mesh.faceCount, 4)
        XCTAssertNil(mesh.edge(between: a.vertices[0], b.vertices[0]), "the side rail replaced the long straight edge")
        XCTAssertEqual(MeshValidator.analyze(mesh).issue(.looseEdges)?.count ?? 0, 0)
        assertValid(mesh)
    }

    func testFailedPatchLeavesMeshUnchanged() throws {
        let engine = Fixtures.engine(with: Fixtures.plane(), camera: Fixtures.frontCamera())
        engine.setTool(.quadPatch)
        engine.perform("seed") { mesh, _ in
            let a = mesh.addVertex(Vec3(-1, 0, 0)), b = mesh.addVertex(Vec3(0, 0, 0)), c = mesh.addVertex(Vec3(1, 0, 0))
            try mesh.ensureEdge(a, b)
            try mesh.ensureEdge(b, c)
        }
        let topology = engine.mesh.topologyVersion
        let screen = try XCTUnwrap(engine.camera.project(Vec3(-0.5, 0, 0))?.screen)
        engine.patchTap(at: screen)
        engine.commitPatch()
        XCTAssertEqual(engine.mesh.topologyVersion, topology)
        XCTAssertEqual(engine.mesh.faceCount, 0)
    }

    func testChainFinderStopsAtJunctions() throws {
        var mesh = Mesh()
        let v = (0..<5).map { mesh.addVertex(Vec3(Float($0), 0, 0)) }
        let branch = mesh.addVertex(Vec3(2, 1, 0))
        for i in 0..<4 { try mesh.ensureEdge(v[i], v[i + 1]) }
        try mesh.ensureEdge(v[2], branch)
        let chain = try XCTUnwrap(ChainFinder.chain(through: try XCTUnwrap(mesh.edge(between: v[0], v[1])), in: mesh))
        XCTAssertEqual(chain.vertices, [v[0], v[1], v[2]])
    }

    func testChainFromUnorderedEdges() throws {
        var mesh = Mesh()
        let v = (0..<5).map { mesh.addVertex(Vec3(Float($0), 0, 0)) }
        var edges: [EdgeID] = []
        for i in 0..<4 { edges.append(try mesh.ensureEdge(v[i], v[i + 1])) }
        let chain = try XCTUnwrap(ChainFinder.chain(from: Set(edges), in: mesh))
        XCTAssertEqual(chain.vertices.count, 5)
        XCTAssertEqual(chain.edges.count, 4)
        XCTAssertFalse(chain.isClosed)
        XCTAssertNil(ChainFinder.chain(from: [edges[0], edges[2]], in: mesh), "a disconnected selection isn't a chain")
    }

    // MARK: Drawing shapes and lines in place

    func testDrawingAShapeWithQuadPatchPreviewsAFill() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.quadPatch)
        Fixtures.drawPath(engine, Fixtures.circle(center: Vec2(500, 500), radius: 120))
        XCTAssertEqual(engine.patchChains.count, 1)
        XCTAssertTrue(engine.patchChains[0].isClosed, "a shape whose ends nearly meet is a loop")
        XCTAssertNotNil(engine.patchPreview)
        engine.commitPatch()
        XCTAssertGreaterThan(engine.mesh.faceCount, 0)
        assertValid(engine.mesh)
    }

    func testASmoothOvalFillsWithStraightRowsNotASliver() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.quadPatch)
        let oval = (0...48).map { i -> Vec2 in
            let a = Float.pi * 1.97 * Float(i) / 48
            return Vec2(500 + cos(a) * 140 + sin(a * 7) * 1.5, 500 + sin(a) * 70 + cos(a * 5) * 1.5)
        }
        Fixtures.drawPath(engine, oval)
        let preview = try XCTUnwrap(engine.patchPreview)
        XCTAssertGreaterThanOrEqual(min(preview.rows, preview.columns) * 4, max(preview.rows, preview.columns), "\(preview.columns) x \(preview.rows)")
        engine.commitPatch()
        assertValid(engine.mesh)
    }

    func testClearingPatchPicksRefreshesTheInterface() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.quadPatch)
        Fixtures.draw(engine, from: Vec2(400, 450), to: Vec2(600, 450))
        XCTAssertEqual(engine.patchChains.count, 1)
        var changes = 0
        engine.onChange = { changes += 1 }
        engine.clearPatchPicks()
        XCTAssertTrue(engine.patchChains.isEmpty)
        XCTAssertGreaterThan(changes, 0, "without a change notice the buttons stay on screen and seem dead")
    }

    func testALineBesideAnotherOffersToFill() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(400, 450), to: Vec2(600, 450))
        XCTAssertNil(engine.fillSuggestion, "one line has nothing beside it")
        Fixtures.draw(engine, from: Vec2(400, 520), to: Vec2(600, 520))
        let suggestion = try XCTUnwrap(engine.fillSuggestion)
        XCTAssertEqual(suggestion.chains.count, 2)
        XCTAssertEqual(engine.mesh.faceCount, 0, "it's an offer until accepted")
        XCTAssertFalse(engine.overlay.previewTriangles.isEmpty, "the offer shows what it would make")

        engine.commitFillSuggestion()
        XCTAssertNil(engine.fillSuggestion)
        XCTAssertEqual(engine.mesh.faceCount, suggestion.preview.columns * suggestion.preview.rows)
        assertValid(engine.mesh)
        engine.undo()
        XCTAssertEqual(engine.mesh.faceCount, 0)
    }

    func testAFillOfferFollowsTheLinesWhicheverWayTheyWereDrawn() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(400, 450), to: Vec2(600, 450))
        Fixtures.draw(engine, from: Vec2(600, 520), to: Vec2(400, 520))
        let suggestion = try XCTUnwrap(engine.fillSuggestion)
        engine.commitFillSuggestion()
        XCTAssertEqual(engine.mesh.faceCount, suggestion.preview.columns * suggestion.preview.rows)
        assertValid(engine.mesh)
    }

    func testAFillOfferGoesAwayWithTheNextStroke() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(400, 450), to: Vec2(600, 450))
        Fixtures.draw(engine, from: Vec2(400, 520), to: Vec2(600, 520))
        XCTAssertNotNil(engine.fillSuggestion)
        engine.pencilBegan(at: Vec2(300, 300))
        XCTAssertNil(engine.fillSuggestion)
        XCTAssertTrue(engine.overlay.previewTriangles.isEmpty)
        engine.pencilCancelled()
    }

    func testLinesThatAreNotNeighboursOfferNothing() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(440, 400), to: Vec2(560, 400))
        Fixtures.draw(engine, from: Vec2(440, 620), to: Vec2(560, 620))
        XCTAssertNil(engine.fillSuggestion, "further apart than they are long")

        let other = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(other, from: Vec2(350, 450), to: Vec2(650, 450))
        Fixtures.draw(other, from: Vec2(470, 500), to: Vec2(530, 500))
        XCTAssertNil(other.fillSuggestion, "very different lengths")

        let crossing = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(crossing, from: Vec2(400, 450), to: Vec2(600, 450))
        Fixtures.draw(crossing, from: Vec2(400, 450), to: Vec2(420, 650))
        XCTAssertNil(crossing.fillSuggestion, "lines that fan out aren't side by side")
    }

    func testFillOfferCanBeTurnedOff() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.suggestsFills = false
        Fixtures.draw(engine, from: Vec2(400, 450), to: Vec2(600, 450))
        Fixtures.draw(engine, from: Vec2(400, 520), to: Vec2(600, 520))
        XCTAssertNil(engine.fillSuggestion)
    }

    // MARK: Offers beside finished faces and between loops

    private func isolatedVertices(_ mesh: Mesh) -> Int {
        mesh.aliveVertices.filter { mesh.edgesOf($0).isEmpty }.count
    }

    /// A patch between two lines, ready for something to be drawn beside it.
    private func patchedEngine() throws -> RetopoEngine {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(400, 440), to: Vec2(600, 440))
        Fixtures.draw(engine, from: Vec2(400, 500), to: Vec2(600, 500))
        XCTAssertNotNil(engine.fillSuggestion)
        engine.commitFillSuggestion()
        XCTAssertGreaterThan(engine.mesh.faceCount, 0)
        return engine
    }

    func testALineBesideAPatchOffersToFillUpToItsEdge() throws {
        let engine = try patchedEngine()
        let before = engine.mesh.faceCount
        Fixtures.draw(engine, from: Vec2(400, 560), to: Vec2(600, 560))
        let suggestion = try XCTUnwrap(engine.fillSuggestion)
        XCTAssertEqual(engine.mesh.faceCount, before, "it's an offer until accepted")
        engine.commitFillSuggestion()
        XCTAssertEqual(engine.mesh.faceCount, before + suggestion.preview.columns * suggestion.preview.rows)
        XCTAssertEqual(engine.statistics.ngons, 0)
        assertValid(engine.mesh)
        engine.undo()
        XCTAssertEqual(engine.mesh.faceCount, before)
    }

    func testADenserLineGivesWayRatherThanSplittingThePatch() throws {
        let engine = try patchedEngine()
        let side = engine.fillSuggestion?.preview.columns
        XCTAssertNil(side)
        engine.tools.stroke.edgeLength *= 0.5
        Fixtures.draw(engine, from: Vec2(400, 560), to: Vec2(600, 560))
        let suggestion = try XCTUnwrap(engine.fillSuggestion)
        XCTAssertEqual(suggestion.preview.boundarySplits, 0)
        XCTAssertFalse(suggestion.preview.plan.removeEdges.isEmpty, "the line's own edges are replaced")
        engine.commitFillSuggestion()
        XCTAssertEqual(engine.statistics.ngons, 0, "the finished quads stay quads")
        XCTAssertEqual(isolatedVertices(engine.mesh), 0, "no vertices are left over from the line")
        assertValid(engine.mesh)
    }

    func testASparserLineTakesTheSplitsItself() throws {
        let engine = try patchedEngine()
        engine.tools.stroke.edgeLength *= 2
        Fixtures.draw(engine, from: Vec2(400, 560), to: Vec2(600, 560))
        engine.commitFillSuggestion()
        XCTAssertEqual(engine.statistics.ngons, 0)
        assertValid(engine.mesh)
    }

    func testALineFarFromAPatchOffersNothing() throws {
        let engine = try patchedEngine()
        Fixtures.draw(engine, from: Vec2(460, 720), to: Vec2(540, 720))
        XCTAssertNil(engine.fillSuggestion)
    }

    func testALoopInsideALoopOffersARing() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.drawPath(engine, Fixtures.circle(center: Vec2(500, 500), radius: 150))
        XCTAssertNil(engine.fillSuggestion, "one loop has nothing to join")
        Fixtures.drawPath(engine, Fixtures.circle(center: Vec2(500, 500), radius: 80))
        let suggestion = try XCTUnwrap(engine.fillSuggestion)
        XCTAssertEqual(suggestion.preview.kind, .ring)
        XCTAssertNotNil(engine.reopenablePlans, "the loop can still be kept open")
        XCTAssertEqual(engine.mesh.faceCount, 0)
        engine.commitFillSuggestion()
        XCTAssertEqual(engine.mesh.faceCount, suggestion.preview.columns * suggestion.preview.rows)
        XCTAssertNil(engine.reopenablePlans)
        XCTAssertEqual(engine.statistics.ngons, 0)
        assertValid(engine.mesh)
    }

    func testKeepingTheInnerLoopOpenWithdrawsTheRing() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.drawPath(engine, Fixtures.circle(center: Vec2(500, 500), radius: 150))
        Fixtures.drawPath(engine, Fixtures.circle(center: Vec2(500, 500), radius: 80))
        XCTAssertNotNil(engine.fillSuggestion)
        engine.keepLoopOpen()
        XCTAssertNil(engine.fillSuggestion)
        XCTAssertNil(engine.reopenablePlans)
    }

    func testALoopAroundAPatchOffersARing() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        engine.setTool(.quadPatch)
        Fixtures.drawPath(engine, Fixtures.circle(center: Vec2(500, 500), radius: 80))
        engine.commitPatch()
        let before = engine.mesh.faceCount
        XCTAssertGreaterThan(before, 0)
        engine.setTool(.drawEdges)
        Fixtures.drawPath(engine, Fixtures.circle(center: Vec2(500, 500), radius: 160))
        XCTAssertEqual(engine.fillSuggestion?.preview.kind, .ring)
        engine.commitFillSuggestion()
        XCTAssertGreaterThan(engine.mesh.faceCount, before)
        XCTAssertEqual(engine.statistics.ngons, 0)
        XCTAssertEqual(isolatedVertices(engine.mesh), 0)
        assertValid(engine.mesh)
    }

    func testTwoLoopsSideBySideOfferNothing() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.drawPath(engine, Fixtures.circle(center: Vec2(420, 500), radius: 55))
        Fixtures.drawPath(engine, Fixtures.circle(center: Vec2(580, 500), radius: 55))
        XCTAssertEqual(engine.mesh.faceCount, 0)
        XCTAssertNil(engine.fillSuggestion, "a pair of eyes isn't a ring")
    }

    // MARK: Picking lines in Draw Edges

    private func tap(_ engine: RetopoEngine, _ point: Vec2) {
        engine.pencilBegan(at: point)
        engine.pencilEnded(at: point)
    }

    func testTappingTwoLinesInDrawEdgesPreviewsAPatch() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(400, 400), to: Vec2(600, 400))
        Fixtures.draw(engine, from: Vec2(400, 600), to: Vec2(600, 600))
        tap(engine, Vec2(500, 400))
        XCTAssertEqual(engine.patchChains.count, 1)
        XCTAssertEqual(engine.activeTool, .drawEdges)
        tap(engine, Vec2(500, 600))
        XCTAssertNotNil(engine.patchPreview)
        var events: [RetopoEngine.EngineEvent] = []
        engine.onEvent = { events.append($0) }
        engine.commitPatch()
        XCTAssertGreaterThan(engine.mesh.faceCount, 0)
        XCTAssertTrue(events.contains(.patchCreated))
        XCTAssertTrue(engine.patchChains.isEmpty)
        assertValid(engine.mesh)
    }

    func testAStrokeAfterPickingALineBecomesTheNextSide() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(400, 400), to: Vec2(600, 400))
        tap(engine, Vec2(500, 400))
        Fixtures.draw(engine, from: Vec2(400, 600), to: Vec2(600, 600))
        XCTAssertEqual(engine.patchChains.count, 2)
        XCTAssertNotNil(engine.patchPreview)
        XCTAssertNil(engine.fillSuggestion, "it's already on its way to being a patch")
    }

    func testPicksLastAcrossDrawEdgesAndQuadPatchOnly() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(400, 400), to: Vec2(600, 400))
        tap(engine, Vec2(500, 400))
        engine.setTool(.quadPatch)
        XCTAssertEqual(engine.patchChains.count, 1)
        engine.setTool(.drawEdges)
        XCTAssertEqual(engine.patchChains.count, 1)
        engine.setTool(.select)
        XCTAssertTrue(engine.patchChains.isEmpty)
    }

    func testATapAwayFromAnyLineInDrawEdgesPicksNothing() throws {
        let engine = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera())
        Fixtures.draw(engine, from: Vec2(400, 400), to: Vec2(600, 400))
        tap(engine, Vec2(500, 600))
        XCTAssertTrue(engine.patchChains.isEmpty)
        XCTAssertNotNil(engine.message)
    }

    func testLinesOnOppositeSidesOfTheModelAreNotNeighbours() throws {
        var mesh = Mesh()
        let front = (0...5).map { mesh.addVertex(simd_normalize(Vec3(Float($0) * 0.04 - 0.1, 0, 1))) }
        let back = (0...5).map { mesh.addVertex(simd_normalize(Vec3(Float($0) * 0.04 - 0.1, 0, -1))) }
        for ids in [front, back] { for i in 0..<5 { _ = try mesh.ensureEdge(ids[i], ids[i + 1]) } }
        let projector = Fixtures.engine(with: Fixtures.sphere(), camera: Fixtures.frontCamera()).projector
        let chain = try XCTUnwrap(ChainFinder.chain(through: mesh.edge(between: front[0], front[1])!, in: mesh))
        XCTAssertNil(NeighborChains.neighbor(of: chain, in: mesh, projector: projector, mirror: nil))
    }
}
