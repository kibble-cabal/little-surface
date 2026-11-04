import Foundation
import simd

public enum ProjectionMode: String, Codable, CaseIterable {
    case perspective
    case orthographic
}

public enum ViewPreset: String, CaseIterable, Codable {
    case front, back, left, right, top, bottom

    /// Rotation that takes camera space (looking down -Z, Y up) to world space.
    public var orientation: simd_quatf {
        let up = Vec3(0, 1, 0), side = Vec3(1, 0, 0)
        switch self {
        case .front: return simd_quatf(angle: 0, axis: up)
        case .back: return simd_quatf(angle: .pi, axis: up)
        case .right: return simd_quatf(angle: .pi / 2, axis: up)
        case .left: return simd_quatf(angle: -.pi / 2, axis: up)
        case .top: return simd_quatf(angle: -.pi / 2, axis: side)
        case .bottom: return simd_quatf(angle: .pi / 2, axis: side)
        }
    }
}

/// Orbit camera. All screen coordinates are in points with the origin at the top left, matching UIKit.
public struct Camera: Equatable {
    public var target = Vec3(repeating: 0)
    public var distance: Float = 3
    public var orientation = simd_quatf(angle: 0, axis: Vec3(0, 1, 0))
    public var projection = ProjectionMode.perspective
    public var fovY: Float = 40 * .pi / 180
    public var viewSize = Vec2(1024, 768)
    /// Scene radius, which sets the clip range so depth precision follows the model.
    public var sceneRadius: Float = 1

    public init() {}

    public var aspect: Float { viewSize.x / max(viewSize.y, 1) }
    public var eye: Vec3 { target + orientation.act(Vec3(0, 0, distance)) }
    public var right: Vec3 { orientation.act(Vec3(1, 0, 0)) }
    public var up: Vec3 { orientation.act(Vec3(0, 1, 0)) }
    public var forward: Vec3 { orientation.act(Vec3(0, 0, -1)) }

    /// Half the visible height at the target's depth: the shared scale between both projections.
    public var halfHeightAtTarget: Float { tan(fovY * 0.5) * distance }

    public var nearPlane: Float {
        let r = max(sceneRadius, 1e-4)
        return max(distance - r * 4, max(distance, r) * 0.002)
    }

    public var farPlane: Float { distance + max(sceneRadius, 1e-4) * 6 }

    public var viewMatrix: Mat4 {
        let r = simd_float3x3(orientation.inverse)
        let t = -(r * eye)
        return Mat4(columns: (
            Vec4(r.columns.0, 0),
            Vec4(r.columns.1, 0),
            Vec4(r.columns.2, 0),
            Vec4(t, 1)
        ))
    }

    public var projectionMatrix: Mat4 {
        switch projection {
        case .perspective:
            return .perspective(fovY: fovY, aspect: aspect, near: nearPlane, far: farPlane)
        case .orthographic:
            return .orthographic(halfHeight: halfHeightAtTarget, aspect: aspect, near: nearPlane, far: farPlane)
        }
    }

    public var viewProjection: Mat4 { projectionMatrix * viewMatrix }

    /// Ray through a screen point.
    public func ray(through screen: Vec2) -> Ray {
        let ndcX = (screen.x / viewSize.x) * 2 - 1
        let ndcY = 1 - (screen.y / viewSize.y) * 2
        let halfH = halfHeightAtTarget
        let halfW = halfH * aspect
        switch projection {
        case .perspective:
            let d = forward * distance + right * (ndcX * halfW) + up * (ndcY * halfH)
            return Ray(origin: eye, direction: simd_normalize(d))
        case .orthographic:
            // Start well behind the scene so nothing in it lies behind the ray.
            let base = target + right * (ndcX * halfW) + up * (ndcY * halfH)
            let back = max(distance, sceneRadius * 4)
            return Ray(origin: base - forward * back, direction: forward)
        }
    }

    /// Screen position (points) and depth along the view axis, or nil behind the camera.
    public func project(_ p: Vec3) -> (screen: Vec2, depth: Float)? {
        let viewSpace = viewMatrix.transformPoint(p)
        let depth = -viewSpace.z
        let halfH = halfHeightAtTarget
        let halfW = halfH * aspect
        switch projection {
        case .perspective:
            guard depth > 1e-6 else { return nil }
            let scale = distance / depth
            let nx = viewSpace.x * scale / halfW, ny = viewSpace.y * scale / halfH
            return (Vec2((nx + 1) * 0.5 * viewSize.x, (1 - ny) * 0.5 * viewSize.y), depth)
        case .orthographic:
            let nx = viewSpace.x / halfW, ny = viewSpace.y / halfH
            return (Vec2((nx + 1) * 0.5 * viewSize.x, (1 - ny) * 0.5 * viewSize.y), depth)
        }
    }

    /// World units per screen point at a world position's depth. Lets screen-sized tolerances become
    /// world distances at any zoom.
    public func worldPerPoint(at p: Vec3) -> Float {
        let unitsPerPointAtTarget = 2 * halfHeightAtTarget / max(viewSize.y, 1)
        switch projection {
        case .orthographic:
            return unitsPerPointAtTarget
        case .perspective:
            let depth = simd_dot(p - eye, forward)
            return unitsPerPointAtTarget * max(depth, nearPlane) / distance
        }
    }

    /// World position of the eye for occlusion tests. In orthographic mode this is a point far behind
    /// `p` along the view axis, because rays there are parallel.
    public func occlusionEye(for p: Vec3) -> Vec3 {
        switch projection {
        case .perspective: return eye
        case .orthographic: return p - forward * max(distance, sceneRadius * 4)
        }
    }

    // MARK: Navigation

    /// Rotates about the camera's own axes: drag right turns the model right, drag down tips it toward you.
    /// Turns to look straight at a surface with this normal, keeping the model's up the right way.
    public mutating func look(along normal: Vec3) {
        guard simd_length_squared(normal) > 0 else { return }
        orientation = Camera.orientation(facing: simd_normalize(normal), near: up)
    }

    /// The orientation whose eye sits out along `z`, with its up as close as possible to `up`.
    public static func orientation(facing z: Vec3, near up: Vec3) -> simd_quatf {
        var x = simd_cross(Vec3(0, 1, 0), z)
        // Looking straight up or down, the world's up says nothing, so the current view decides.
        if simd_length_squared(x) < 1e-4 { x = simd_cross(up, z) }
        if simd_length_squared(x) < 1e-8 { x = Vec3(1, 0, 0) }
        x = simd_normalize(x)
        return simd_quatf(simd_float3x3(columns: (x, simd_cross(z, x), z)))
    }

    public mutating func orbit(deltaPoints: Vec2) {
        let speed: Float = 2 * .pi / max(viewSize.y, 1) * 0.6
        let yaw = simd_quatf(angle: -deltaPoints.x * speed, axis: up)
        let pitch = simd_quatf(angle: -deltaPoints.y * speed, axis: right)
        orientation = simd_normalize(yaw * pitch * orientation)
    }

    public mutating func pan(deltaPoints: Vec2) {
        let s = worldPerPoint(at: target)
        target += right * (-deltaPoints.x * s) + up * (deltaPoints.y * s)
    }

    /// Scales distance, keeping the world point under `focus` in place.
    public mutating func zoom(factor: Float, focus: Vec2) {
        let clamped = max(0.01, factor)
        let center = viewSize * 0.5
        let offset = Vec2(focus.x - center.x, focus.y - center.y)
        let before = 2 * halfHeightAtTarget / max(viewSize.y, 1)
        let minimum = max(sceneRadius * 0.01, 1e-4), maximum = max(sceneRadius * 40, 1e-3)
        let next = simd_clamp(distance / clamped, minimum, maximum)
        let after = before * next / distance
        target += right * (offset.x * (before - after)) - up * (offset.y * (before - after))
        distance = next
    }

    /// Fits a sphere around the box. `padding` above 1 leaves a margin.
    public mutating func frame(_ box: AABB, padding: Float = 1.25, updateSceneRadius: Bool = false) {
        guard !box.isEmpty else { return }
        let radius = max(box.diagonal * 0.5, 1e-4)
        target = box.center
        let halfFov = min(fovY, fovY * aspect) * 0.5
        distance = radius * padding / sin(halfFov)
        if updateSceneRadius { sceneRadius = radius }
    }

    public mutating func setPreset(_ preset: ViewPreset) {
        orientation = preset.orientation
    }
}
