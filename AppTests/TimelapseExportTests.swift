import AVFoundation
import LittleSurfaceCore
import Metal
import UIKit
import XCTest
@testable import LittleSurface

final class TimelapseExportTests: XCTestCase {
    private func sphere() -> SourceObject {
        var positions: [Vec3] = [], normals: [Vec3] = [], indices: [UInt32] = []
        let rings = 24, segments = 32
        for r in 0...rings {
            let phi = Float(r) / Float(rings) * .pi
            for s in 0...segments {
                let theta = Float(s) / Float(segments) * 2 * .pi
                let p = Vec3(sin(phi) * sin(theta), cos(phi), sin(phi) * cos(theta))
                positions.append(p)
                normals.append(p)
            }
        }
        let row = UInt32(segments + 1)
        for r in 0..<UInt32(rings) {
            for s in 0..<UInt32(segments) {
                let a = r * row + s, b = a + row
                indices += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        return SourceObject(id: UUID(), name: "Ball", positions: positions, normals: normals, indices: indices)
    }

    private func workedProject() throws -> RetopoEngine {
        let object = sphere()
        let engine = RetopoEngine(name: "Timelapse")
        engine.addSources([object], bvhs: [object.id: try XCTUnwrap(TriangleBVH(object: object))])
        engine.camera.viewSize = Vec2(800, 800)
        engine.frameAll()
        func draw(_ a: Vec2, _ b: Vec2) {
            engine.pencilBegan(at: a)
            for i in 1...12 { engine.pencilMoved(to: a + (b - a) * Float(i) / 12) }
            engine.pencilEnded(at: b)
        }
        engine.setTool(.sketch)
        draw(Vec2(320, 300), Vec2(480, 300))
        engine.setTool(.drawEdges)
        draw(Vec2(320, 340), Vec2(480, 340))
        engine.camera.setPreset(.left)
        draw(Vec2(320, 400), Vec2(480, 400))
        engine.undo()
        engine.redo()
        return engine
    }

    private func export(_ snapshot: ProjectSnapshot) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try TimelapseExporter.export(snapshot, device: try XCTUnwrap(MTLCreateSystemDefaultDevice()), to: url) { _ in }
        return url
    }

    func testMakesAVideoShowingTheWorkAndTheBadge() async throws {
        let snapshot = try workedProject().makeSnapshot()
        XCTAssertEqual(snapshot.timelapse.count, 5)
        let url = try export(snapshot)

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1080, height: 1080))
        let seconds = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(seconds, 8)
        XCTAssertLessThan(seconds, 12)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        func frame(_ time: Double) async throws -> CGImage {
            try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        }
        let opening = try await frame(0.2)
        let closing = try await frame(seconds - 0.2)
        XCTAssertGreaterThan(difference(opening, closing), 0.5, "the work shows up, and the view has moved")

        // The badge sits in the bottom left, at the same place throughout, and the corner opposite is bare.
        let badge = CGRect(x: 60, y: 980, width: 300, height: 60)
        XCTAssertLessThan(difference(opening, closing, in: badge), 5, "the pill is slightly see-through, so a little of the model shows")
        XCTAssertGreaterThan(contrast(opening, in: badge), 0.3, "there's something drawn there")
        XCTAssertLessThan(contrast(opening, in: CGRect(x: 780, y: 20, width: 280, height: 60)), 0.05)
    }

    func testCancellingLeavesNoFile() throws {
        let snapshot = try workedProject().makeSnapshot()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let finished = expectation(description: "stopped")
        let task = Task.detached {
            do {
                try TimelapseExporter.export(snapshot, device: device, to: url) { _ in }
                XCTFail("it should have stopped")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(error)")
            }
            finished.fulfill()
        }
        task.cancel()
        wait(for: [finished], timeout: 120)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testNothingRecordedIsAnError() throws {
        let empty = RetopoEngine(name: "Empty").makeSnapshot()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("never.mp4")
        XCTAssertThrowsError(try TimelapseExporter.export(empty, device: device, to: url) { _ in })
    }

    // MARK: Looking at pictures

    private func pixels(_ image: CGImage) -> (bytes: [UInt8], width: Int, height: Int) {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (bytes, width, height)
    }

    /// The percentage of pixels that differ noticeably.
    private func difference(_ a: CGImage, _ b: CGImage, in rect: CGRect? = nil) -> Double {
        let pa = pixels(a), pb = pixels(b)
        let area = rect ?? CGRect(x: 0, y: 0, width: pa.width, height: pa.height)
        var differing = 0, total = 0
        for y in Int(area.minY)..<Int(area.maxY) {
            for x in Int(area.minX)..<Int(area.maxX) {
                let i = (y * pa.width + x) * 4
                total += 1
                if (0..<3).contains(where: { abs(Int(pa.bytes[i + $0]) - Int(pb.bytes[i + $0])) > 24 }) { differing += 1 }
            }
        }
        return Double(differing) / Double(total) * 100
    }

    /// How far the region's brightness spreads, from 0 to 1.
    private func contrast(_ image: CGImage, in rect: CGRect) -> Double {
        let p = pixels(image)
        var low = 255, high = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let v = Int(p.bytes[(y * p.width + x) * 4 + 1])
                low = min(low, v)
                high = max(high, v)
            }
        }
        return Double(high - low) / 255
    }
}
