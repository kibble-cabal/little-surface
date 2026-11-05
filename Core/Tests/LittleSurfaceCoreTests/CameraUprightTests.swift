import XCTest
import simd
@testable import LittleSurfaceCore

final class CameraUprightTests: XCTestCase {
    func testOrbitingStaysLevel() {
        var camera = Fixtures.frontCamera()
        for delta in [Vec2(120, 30), Vec2(-40, 70), Vec2(200, -90), Vec2(-300, 20), Vec2(60, -40)] {
            camera.orbit(deltaPoints: delta)
            XCTAssertEqual(camera.right.y, 0, accuracy: 0.0001, "No tilt builds up")
        }
    }

    func testOrbitingUpsideDownStillFollowsTheFinger() {
        var camera = Fixtures.frontCamera()
        let turnOver = Float.pi / (2 * .pi / camera.viewSize.y * 0.6)
        camera.orbit(deltaPoints: Vec2(0, turnOver))
        XCTAssertLessThan(camera.up.y, 0)
        // Having tipped right over, the side facing the camera is the back.
        let point = Vec3(0, 0, -1)
        let before = camera.project(point)!.screen.x
        camera.orbit(deltaPoints: Vec2(40, 0))
        XCTAssertGreaterThan(camera.project(point)!.screen.x, before)
    }

    func testTwistingTurnsThePictureClockwise() {
        var camera = Fixtures.frontCamera()
        let point = Vec3(1, 0, 0)
        let before = camera.project(point)!.screen
        camera.twist(by: .pi / 2)
        let after = camera.project(point)!.screen
        XCTAssertGreaterThan(before.x, 500)
        XCTAssertEqual(before.y, 500, accuracy: 0.01)
        XCTAssertEqual(after.x, 500, accuracy: 0.01)
        XCTAssertGreaterThan(after.y, 500, "On screen, down is clockwise from the right")
    }

    func testAPresetLevelsTheViewAfterATwist() {
        var camera = Fixtures.frontCamera()
        camera.twist(by: 0.7)
        camera.setPreset(.front)
        XCTAssertEqual(camera.up.y, 1, accuracy: 0.0001)
    }
}
