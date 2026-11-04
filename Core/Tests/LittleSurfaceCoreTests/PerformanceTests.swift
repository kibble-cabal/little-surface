import Foundation
import XCTest
@testable import LittleSurfaceCore

/// Prints timings for a large model. Skipped unless LS_PERF_MODEL names one, and only meaningful optimized:
/// LS_PERF_MODEL=model.glb swift test -c release -Xswiftc -enable-testing --filter PerformanceTests
final class PerformanceTests: XCTestCase {
    private func timed<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
        let start = Date()
        let result = try work()
        print("PERF \(label): \(String(format: "%.3f", Date().timeIntervalSince(start))) s")
        return result
    }

    func testLargeModel() throws {
        guard let path = ProcessInfo.processInfo.environment["LS_PERF_MODEL"] else {
            throw XCTSkip("Set LS_PERF_MODEL to run this.")
        }
        let model = try timed("parse") { try ModelImporter.load(url: URL(fileURLWithPath: path), isCancelled: { false }) }
        print("PERF triangles: \(model.objects.reduce(0) { $0 + $1.indices.count / 3 })")
        let bvhs = timed("build BVH") { RetopoEngine.buildBVHs(for: model.objects) }

        let engine = RetopoEngine()
        engine.camera.viewSize = Vec2(800, 1100)
        engine.addSources(model.objects, bvhs: bvhs)
        var hits = 0
        timed("10,000 surface raycasts") {
            for i in 0..<10_000 {
                let t = Float(i) / 10_000
                if engine.projector?.raycast(engine.camera.ray(through: Vec2(250 + 300 * t, 550))) != nil { hits += 1 }
            }
        }
        print("PERF raycast hits: \(hits)")
        XCTAssertGreaterThan(hits, 5_000)
        timed("draw a stroke, 240 samples") {
            engine.setTool(.drawEdges)
            engine.pencilBegan(at: Vec2(250, 550))
            for i in 1..<240 { engine.pencilMoved(to: Vec2(250 + Float(i) * 1.25, 550), pressure: 1, predicted: []) }
            engine.pencilEnded(at: Vec2(550, 550))
            if engine.pendingStroke != nil { engine.commitPendingStroke(close: false) }
        }
        print("PERF stroke vertices: \(engine.mesh.vertexCount)")
        XCTAssertGreaterThan(engine.mesh.vertexCount, 5)
        let snapshot = engine.makeSnapshot()
        let encoded = try timed("encode project") { try ProjectCodec.encode(snapshot) }
        print("PERF project size: \(encoded.count / 1_000_000) MB")
        _ = try timed("decode project") { try ProjectCodec.decode(encoded) }
    }
}
