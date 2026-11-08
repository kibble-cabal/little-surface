import LittleSurfaceCore
import Metal
import UIKit
import XCTest
@testable import LittleSurface

final class GuideClipTests: XCTestCase {
    /// Every example draws something: lines and a model, not just the background.
    func testEveryExampleDraws() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let size = CGSize(width: 480, height: 320)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GuideClips", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for example in GuideExample.allCases {
            let player = ExamplePlayer(example: example, device: device, start: Date())
            let renderer = try XCTUnwrap(player.renderer)
            player.show(at: example.stillTime, size: size)
            let image = try XCTUnwrap(renderer.thumbnail(engine: player.engine, size: size), "\(example)")
            let cg = try XCTUnwrap(image.cgImage)
            let pixels = try XCTUnwrap(cg.dataProvider?.data as Data?)
            XCTAssertGreaterThan(Set(stride(from: 0, to: pixels.count, by: 4 * 97).map { pixels[$0] }).count, 8, "\(example) looks empty")
            try image.pngData()?.write(to: folder.appendingPathComponent("\(example.rawValue).png"))
        }
        print("Guide clips written to \(folder.path)")
    }
}
