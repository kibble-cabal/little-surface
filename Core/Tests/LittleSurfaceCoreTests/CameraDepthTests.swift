import XCTest
import simd
@testable import LittleSurfaceCore

final class CameraDepthTests: XCTestCase {
    /// Lines and faces are pulled toward the eye by a fixed amount of depth, up to 0.0007. If the front and
    /// back of the model are closer together than that, what's drawn on the back shows through the front.
    func testTheFrontAndBackOfAModelStayFurtherApartThanTheDepthPullAtEveryZoom() {
        let radius: Float = 1
        for aspect: Float in [0.7, 1, 1.4] {
            var framed = Camera()
            framed.viewSize = Vec2(1000 * aspect, 1000)
            framed.sceneRadius = radius
            framed.frame(AABB(minCorner: Vec3(repeating: -0.57), maxCorner: Vec3(repeating: 0.57)))
            for zoom: Float in [0.4, 0.6, 0.85, 1, 1.5, 3, 8, 30] {
                var camera = framed
                camera.distance = framed.distance * zoom
                guard camera.distance > radius * 1.3 else { continue }
                func depth(_ z: Float) -> Float {
                    let clip = camera.viewProjection * Vec4(0, 0, z, 1)
                    return clip.z / clip.w
                }
                // A head a quarter the size of the scene, at its middle.
                XCTAssertGreaterThan(depth(-0.25) - depth(0.25), 0.002, "aspect \(aspect), zoom \(zoom)")
            }
        }
    }

    func testNothingInFrontOfTheCameraIsClippedFromOutsideTheModel() {
        for distance: Float in [1.2, 1.5, 2, 3, 3.5, 5, 10, 40] {
            var camera = Camera()
            camera.sceneRadius = 1
            camera.distance = distance
            XCTAssertLessThan(camera.nearPlane, distance - 1, "at \(distance) the nearest point of the model is still drawn")
            XCTAssertGreaterThan(camera.farPlane, distance + 1)
        }
    }

    func testZoomedInsideTheModelStillDraws() {
        var camera = Camera()
        camera.sceneRadius = 1
        for distance: Float in [0.1, 0.5, 1] {
            camera.distance = distance
            XCTAssertLessThan(camera.nearPlane, distance * 0.1)
            XCTAssertGreaterThan(camera.nearPlane, 0)
        }
    }
}
