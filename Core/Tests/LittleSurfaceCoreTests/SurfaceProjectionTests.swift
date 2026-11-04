import XCTest
import simd
@testable import LittleSurfaceCore

final class SurfaceProjectionTests: XCTestCase {
    func testRaycastMatchesAnalyticSphere() throws {
        let projector = Fixtures.projector(Fixtures.sphere())
        let ray = Ray(origin: Vec3(0.3, 0.2, 5), direction: Vec3(0, 0, -1))
        let hit = try XCTUnwrap(projector.raycast(ray))
        let expectedZ: Float = sqrt(1 - 0.09 - 0.04)
        XCTAssertEqual(hit.position.z, expectedZ, accuracy: 0.005)
        XCTAssertGreaterThan(simd_dot(hit.normal, hit.position), 0.99)
    }

    func testBVHAgreesWithBruteForce() throws {
        let object = Fixtures.sphere(rings: 24, segments: 32)
        let bvh = try XCTUnwrap(TriangleBVH(object: object))
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let p = Vec3(Float.random(in: -2...2, using: &generator), Float.random(in: -2...2, using: &generator), Float.random(in: -2...2, using: &generator))
            var bestDistance = Float.infinity
            var i = 0
            while i < object.indices.count {
                let a = object.positions[Int(object.indices[i])], b = object.positions[Int(object.indices[i + 1])], c = object.positions[Int(object.indices[i + 2])]
                bestDistance = min(bestDistance, simd_length(GeometryMath.closestPointOnTriangle(p, a, b, c).point - p))
                i += 3
            }
            let hit = try XCTUnwrap(bvh.closestPoint(to: p))
            XCTAssertEqual(hit.distance, bestDistance, accuracy: 1e-4)

            let target = Vec3(Float.random(in: -0.5...0.5, using: &generator), Float.random(in: -0.5...0.5, using: &generator), Float.random(in: -0.5...0.5, using: &generator))
            let ray = Ray(origin: p * 3, direction: simd_normalize(target - p * 3))
            var bruteT = Float.infinity
            i = 0
            while i < object.indices.count {
                let a = object.positions[Int(object.indices[i])], b = object.positions[Int(object.indices[i + 1])], c = object.positions[Int(object.indices[i + 2])]
                if let h = GeometryMath.intersectTriangle(ray, a, b, c, tMax: bruteT) { bruteT = h.t }
                i += 3
            }
            let rayHit = bvh.raycast(ray)
            if bruteT.isFinite {
                XCTAssertEqual(try XCTUnwrap(rayHit).distance, bruteT, accuracy: 1e-3)
            } else {
                XCTAssertNil(rayHit)
            }
        }
    }

    func testBVHHandlesDegenerateInput() throws {
        // Every triangle identical: the build still has to terminate.
        let positions = [Vec3](repeating: .zero, count: 90)
        let indices = (0..<UInt32(90)).map { $0 }
        let bvh = try XCTUnwrap(TriangleBVH(positions: positions, normals: positions, indices: indices))
        XCTAssertEqual(bvh.triangleCount, 30)
        XCTAssertNil(bvh.raycast(Ray(origin: Vec3(1, 1, 1), direction: Vec3(1, 0, 0))))
    }

    func testBVHBuildCancels() throws {
        let object = Fixtures.sphere(rings: 200, segments: 200)
        XCTAssertNil(TriangleBVH(object: object, isCancelled: { true }))
    }

    func testProjectionLandsOnSurface() throws {
        let projector = Fixtures.projector(Fixtures.sphere())
        let projected = try XCTUnwrap(projector.project(Vec3(0, 2, 0)))
        XCTAssertEqual(simd_length(projected.position), 1, accuracy: 0.005)
        XCTAssertEqual(projected.position.y, 1, accuracy: 0.01)
    }

    func testSurfaceOffsetLiftsAlongNormal() throws {
        let projector = Fixtures.projector(Fixtures.sphere(), offset: 0.1)
        let projected = try XCTUnwrap(projector.project(Vec3(0, 2, 0)))
        XCTAssertEqual(simd_length(projected.position), 1.1, accuracy: 0.005)
    }

    func testNormalHintStopsJumpToOppositeSideOfThinShell() throws {
        // Two parallel sheets, 0.02 apart: a closed thin shell with opposite normals.
        let front = Fixtures.plane(z: 0.01)
        var back = Fixtures.plane(z: -0.01)
        // Reverse the back sheet so it faces -Z.
        var i = 0
        while i < back.indices.count {
            back.indices.swapAt(i + 1, i + 2)
            i += 3
        }
        back.normals = back.normals.map { -$0 }
        let projector = SurfaceProjector(bvhs: [TriangleBVH(object: front)!, TriangleBVH(object: back)!])

        // Slightly closer to the back sheet, but this vertex belongs to the front.
        let p = Vec3(0, 0, -0.002)
        let free = try XCTUnwrap(projector.closest(to: p))
        XCTAssertEqual(free.position.z, -0.01, accuracy: 1e-4)
        let hinted = try XCTUnwrap(projector.closest(to: p, normalHint: Vec3(0, 0, 1)))
        XCTAssertEqual(hinted.position.z, 0.01, accuracy: 1e-4, "stays on the side it started on")
    }

    func testOcclusion() throws {
        let projector = Fixtures.projector(Fixtures.sphere())
        let eye = Vec3(0, 0, 5)
        XCTAssertFalse(projector.isOccluded(Vec3(0, 0, 1), from: eye, tolerance: 0.01))
        XCTAssertTrue(projector.isOccluded(Vec3(0, 0, -1), from: eye, tolerance: 0.01))
    }

    func testInsideOutClosedObjectIsCorrected() throws {
        var sphere = Fixtures.sphere(rings: 16, segments: 24)
        var i = 0
        while i < sphere.indices.count {
            sphere.indices.swapAt(i + 1, i + 2)
            i += 3
        }
        sphere.normals = sphere.normals.map { -$0 }
        XCTAssertLessThan(sphere.signedVolume, 0)
        sphere.normalizeOrientation()
        XCTAssertGreaterThan(sphere.signedVolume, 0)
        XCTAssertGreaterThan(simd_dot(sphere.normals[100], sphere.positions[100]), 0)
    }
}

final class AxisAlignedRayTests: XCTestCase {
    func testRaysLyingInBoxFacesStillHit() throws {
        // The plane's triangle edges fill BVH faces at y = 0 and x = 0, exactly where these rays run.
        let projector = Fixtures.projector(Fixtures.plane())
        for d in [Vec3(0, 0, -1), Vec3(-0.0, -0.0, -1), simd_normalize(Vec3(0.2, 0, -1)), simd_normalize(Vec3(-0.2, -0.0, -1)), simd_normalize(Vec3(0, -0.2, -1))] {
            let hit = projector.raycast(Ray(origin: Vec3(0, 0, 5), direction: d))
            XCTAssertNotNil(hit, "\(d)")
            XCTAssertEqual(hit?.position.z ?? 1, 0, accuracy: 1e-4)
        }
        XCTAssertNil(projector.raycast(Ray(origin: Vec3(9, 0, 5), direction: Vec3(0, 0, -1))), "rays beside the plane still miss")
    }

    func testStrokeAlongAnAxisOfASymmetricModelIsContinuous() throws {
        var capture = StrokeCapture(camera: Fixtures.frontCamera(), projector: Fixtures.projector(Fixtures.plane()))
        for x in stride(from: Float(300), through: 700, by: 10) { capture.add(screen: Vec2(x, 500)) }
        XCTAssertEqual(capture.runs.count, 1)
        XCTAssertEqual(capture.missCount, 0)
    }
}

final class CameraTests: XCTestCase {
    func testProjectAndRayAreInverse() throws {
        for mode in ProjectionMode.allCases {
            var camera = Fixtures.frontCamera(projection: mode)
            camera.orbit(deltaPoints: Vec2(80, 30))
            camera.pan(deltaPoints: Vec2(10, -20))
            let p = Vec3(0.3, -0.2, 0.1)
            let screen = try XCTUnwrap(camera.project(p)?.screen)
            let ray = camera.ray(through: screen)
            let closest = ray.origin + ray.direction * simd_dot(p - ray.origin, ray.direction)
            XCTAssertLessThan(simd_length(closest - p), 1e-3, "\(mode)")
        }
    }

    func testProjectMatchesViewProjectionMatrix() throws {
        for mode in ProjectionMode.allCases {
            var camera = Fixtures.frontCamera(projection: mode)
            camera.orbit(deltaPoints: Vec2(-50, 70))
            let p = Vec3(0.4, 0.1, -0.3)
            let clip = camera.viewProjection * Vec4(p.x, p.y, p.z, 1)
            let ndc = Vec2(clip.x / clip.w, clip.y / clip.w)
            let fromMatrix = Vec2((ndc.x + 1) * 0.5 * camera.viewSize.x, (1 - ndc.y) * 0.5 * camera.viewSize.y)
            let direct = try XCTUnwrap(camera.project(p)?.screen)
            XCTAssertLessThan(simd_length(fromMatrix - direct), 0.01, "\(mode)")
        }
    }

    func testDepthIsInMetalRange() throws {
        for mode in ProjectionMode.allCases {
            let camera = Fixtures.frontCamera(projection: mode)
            let clip = camera.viewProjection * Vec4(0, 0, 0, 1)
            let z = clip.z / clip.w
            XCTAssertGreaterThan(z, 0)
            XCTAssertLessThan(z, 1)
        }
    }

    func testViewPresetsLookFromTheNamedSide() {
        var camera = Fixtures.frontCamera()
        for (preset, expected) in [(ViewPreset.front, Vec3(0, 0, 1)), (.back, Vec3(0, 0, -1)), (.right, Vec3(1, 0, 0)), (.left, Vec3(-1, 0, 0)), (.top, Vec3(0, 1, 0)), (.bottom, Vec3(0, -1, 0))] {
            camera.setPreset(preset)
            let eye = simd_normalize(camera.eye - camera.target)
            XCTAssertLessThan(simd_length(eye - expected), 1e-5, "\(preset)")
        }
    }

    func testZoomKeepsFocusPointStill() throws {
        var camera = Fixtures.frontCamera()
        let focus = Vec2(700, 300)
        let ray = camera.ray(through: focus)
        // The point where the focus ray meets the plane through the target.
        let t = simd_dot(camera.target - ray.origin, camera.forward) / simd_dot(ray.direction, camera.forward)
        let world = ray.at(t)
        camera.zoom(factor: 1.5, focus: focus)
        let after = try XCTUnwrap(camera.project(world)?.screen)
        XCTAssertLessThan(simd_length(after - focus), 0.5)
    }
}
