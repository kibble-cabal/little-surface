import Foundation
import simd

/// A point of a stroke that landed on the source surface.
public struct StrokePoint: Equatable {
    public var position: Vec3
    public var normal: Vec3
    public var screen: Vec2
    public var pressure: Float
    /// A corner someone means, rather than one the stroke happens to turn sharply at.
    public var isCorner = false

    public init(position: Vec3, normal: Vec3, screen: Vec2 = .zero, pressure: Float = 1) {
        self.position = position
        self.normal = normal
        self.screen = screen
        self.pressure = pressure
    }
}

/// Turns screen samples into paths on the visible surface while the Pencil moves.
///
/// Fast strokes leave wide screen gaps between samples, so gaps are filled by casting extra rays,
/// which keeps the path on the surface across triangle boundaries and small features. A place where
/// the surface really does jump in depth, such as passing over a silhouette, ends the current run
/// rather than bridging it with invented geometry.
public struct StrokeCapture {
    public private(set) var runs: [[StrokePoint]] = []
    public private(set) var screenPath: [Vec2] = []
    public private(set) var missCount = 0
    private var runIsOpen = false

    private let camera: Camera
    private let projector: SurfaceProjector

    /// Extra rays are cast until neighbours are this close on screen.
    private let maxScreenGap: Float = 5
    private let maxRefineDepth = 5

    public init(camera: Camera, projector: SurfaceProjector) {
        self.camera = camera
        self.projector = projector
    }

    public var screenLength: Float {
        guard screenPath.count > 1 else { return 0 }
        var total: Float = 0
        for i in 1..<screenPath.count { total += simd_length(screenPath[i] - screenPath[i - 1]) }
        return total
    }

    public var hitCount: Int { runs.reduce(0) { $0 + $1.count } }
    public var hasGaps: Bool { runs.count > 1 || missCount > 0 }

    public mutating func add(screen: Vec2, pressure: Float = 1) {
        if let last = screenPath.last, simd_length(last - screen) < 0.5 { return }
        let previousScreen = screenPath.last
        screenPath.append(screen)

        let current = sample(screen, pressure: pressure)
        guard let current else {
            // Walk from the last hit to find how far the surface really extends before the miss.
            if runIsOpen, let previous = runs.last?.last, let previousScreen {
                refineTowardMiss(from: previous, fromScreen: previousScreen, toScreen: screen, pressure: pressure, depth: 0)
            }
            missCount += 1
            runIsOpen = false
            return
        }
        if runIsOpen, let previous = runs[runs.count - 1].last {
            fill(from: previous, to: current, depth: 0)
        } else {
            runs.append([current])
            runIsOpen = true
        }
    }

    private func sample(_ screen: Vec2, pressure: Float) -> StrokePoint? {
        guard let hit = projector.raycast(camera.ray(through: screen)) else { return nil }
        return StrokePoint(position: hit.position, normal: hit.normal, screen: screen, pressure: pressure)
    }

    private func isContinuous(_ a: StrokePoint, _ b: StrokePoint) -> Bool {
        let screenDistance = simd_length(a.screen - b.screen)
        let world = simd_length(a.position - b.position)
        let scale = camera.worldPerPoint(at: a.position)
        // A surface inclined 84° from the screen stretches distances about tenfold.
        return world <= max(screenDistance, 1.5) * scale * 10
    }

    private mutating func fill(from a: StrokePoint, to b: StrokePoint, depth: Int) {
        let screenDistance = simd_length(a.screen - b.screen)
        let continuous = isContinuous(a, b)
        if continuous && screenDistance <= maxScreenGap {
            runs[runs.count - 1].append(b)
            return
        }
        if depth >= maxRefineDepth || screenDistance < 0.5 {
            if continuous {
                runs[runs.count - 1].append(b)
            } else {
                runs.append([b])
            }
            return
        }
        let midScreen = (a.screen + b.screen) * 0.5
        guard let mid = sample(midScreen, pressure: (a.pressure + b.pressure) * 0.5) else {
            missCount += 1
            runs.append([b])
            return
        }
        fill(from: a, to: mid, depth: depth + 1)
        let lastOfRun = runs[runs.count - 1].last ?? mid
        fill(from: lastOfRun, to: b, depth: depth + 1)
    }

    private mutating func refineTowardMiss(from a: StrokePoint, fromScreen: Vec2, toScreen: Vec2, pressure: Float, depth: Int) {
        guard depth < 4, simd_length(fromScreen - toScreen) > 2 else { return }
        let midScreen = (fromScreen + toScreen) * 0.5
        if let mid = sample(midScreen, pressure: pressure), isContinuous(a, mid) {
            runs[runs.count - 1].append(mid)
            refineTowardMiss(from: mid, fromScreen: midScreen, toScreen: toScreen, pressure: pressure, depth: depth + 1)
        } else {
            refineTowardMiss(from: a, fromScreen: fromScreen, toScreen: midScreen, pressure: pressure, depth: depth + 1)
        }
    }

    /// Surface-side polylines long enough to act on.
    public var usableRuns: [[StrokePoint]] { runs.filter { $0.count >= 2 } }
}

/// Controls how a captured stroke becomes vertices.
public struct StrokeSettings: Equatable, Codable {
    /// Target world-space distance between vertices.
    public var edgeLength: Float = 0.05
    /// 0 keeps every wobble, 1 smooths firmly.
    public var smoothing: Float = 0.4
    /// How close to existing topology endpoints snap, in screen points.
    public var snapRadiusPoints: Float = 22
    /// How close stroke ends must be to close the loop, in screen points. Long strokes get more leeway.
    public var closeRadiusPoints: Float = 44

    public init() {}
}

/// A stroke converted to evenly spaced surface points, not yet topology.
public struct ProcessedPath: Equatable {
    public var points: [StrokePoint]
    public var length: Float
    /// World distance between the two ends.
    public var endGap: Float
    /// The ends come close enough for this to read as a loop.
    public var canClose: Bool
    public var isClosed: Bool = false
    /// Where a loop closes: the pair of points, near the two ends, that come closest. A stroke that
    /// runs past its own start loses the overshoot.
    public var closeFrom: Int = 0
    public var closeTo: Int? = nil
}

public enum StrokeProcessor {
    /// Smooths and resamples one run onto the surface.
    /// `closeRadius` is the world distance within which the path reads as a loop.
    public static func process(run: [StrokePoint], settings: StrokeSettings, projector: SurfaceProjector, closeRadius: Float) -> ProcessedPath? {
        guard run.count >= 2 else { return nil }
        let spacing = max(settings.edgeLength, 1e-5)

        // Uniform dense spacing first, so smoothing behaves the same at any Pencil speed.
        var dense = resample(run, spacing: spacing * 0.25)
        guard dense.count >= 2 else { return nil }

        let iterations = Int((settings.smoothing * 16).rounded())
        if iterations > 0 && dense.count > 2 {
            for _ in 0..<iterations {
                var next = dense
                for i in 1..<(dense.count - 1) {
                    next[i].position = dense[i].position * 0.5 + (dense[i - 1].position + dense[i + 1].position) * 0.25
                }
                dense = next
            }
        }

        let length = polylineLength(dense)
        guard length > spacing * 0.1 else { return nil }
        let segments = max(1, Int((length / spacing).rounded()))
        var out = resample(dense, count: segments + 1)
        for i in 0..<out.count {
            if let hit = projector.closest(to: out[i].position, normalHint: out[i].normal, maxDistance: spacing * 3) {
                out[i].position = hit.position
                out[i].normal = hit.normal
            }
        }
        let gap = simd_length(out[0].position - out[out.count - 1].position)
        let total = polylineLength(out)
        var closeFrom = 0, closeTo = out.count - 1, closeGap = gap
        let reach = min(out.count / 4, 60)
        if reach > 0 {
            for i in 0..<reach {
                for j in (out.count - reach)..<out.count where j - i >= 3 {
                    let d = simd_length(out[i].position - out[j].position)
                    if d < closeGap {
                        closeGap = d
                        closeFrom = i
                        closeTo = j
                    }
                }
            }
        }
        let radius = closeRadius > 0 ? max(closeRadius, min(total * 0.12, closeRadius * 2)) : 0
        let canClose = out.count >= 4 && closeTo - closeFrom >= 3 && closeGap <= radius && total > closeGap * 2.5
        return ProcessedPath(points: out, length: total, endGap: gap, canClose: canClose, closeFrom: closeFrom, closeTo: closeTo)
    }

    /// Closes a path where its ends come nearest. The last point is dropped when it nearly coincides
    /// with the first, so the two ends don't create a tiny edge, and a wider gap gets vertices of its
    /// own, so the closing edge doesn't stand out.
    public static func closed(_ path: ProcessedPath, spacing: Float, projector: SurfaceProjector? = nil) -> ProcessedPath {
        var out = path
        out.isClosed = true
        var points = Array(path.points[path.closeFrom...(path.closeTo ?? path.points.count - 1)])
        guard let first = points.first, let last = points.last else { return out }
        let gap = simd_length(first.position - last.position)
        if gap < spacing * 0.5 && points.count > 3 {
            points.removeLast()
        } else {
            let extra = Int((gap / max(spacing, 1e-5)).rounded()) - 1
            if extra > 0 {
                for k in 1...extra {
                    var p = last
                    let t = Float(k) / Float(extra + 1)
                    p.position = simd_mix(last.position, first.position, Vec3(repeating: t))
                    p.normal = GeometryMath.safeNormalize(simd_mix(last.normal, first.normal, Vec3(repeating: t)), fallback: last.normal)
                    if let hit = projector?.closest(to: p.position, normalHint: p.normal, maxDistance: max(gap, spacing * 3)) {
                        p.position = hit.position
                        p.normal = hit.normal
                    }
                    points.append(p)
                }
            }
        }
        out.points = points
        out.closeFrom = 0
        out.closeTo = nil
        out.length = polylineLength(points) + simd_length(points[points.count - 1].position - points[0].position)
        out.endGap = 0
        return out
    }

    public static func polylineLength(_ points: [StrokePoint]) -> Float {
        guard points.count > 1 else { return 0 }
        var total: Float = 0
        for i in 1..<points.count { total += simd_length(points[i].position - points[i - 1].position) }
        return total
    }

    static func resample(_ points: [StrokePoint], spacing: Float) -> [StrokePoint] {
        let total = polylineLength(points)
        guard total > 0 else { return [points[0]] }
        let count = max(2, Int((total / spacing).rounded()) + 1)
        return resample(points, count: count)
    }

    /// `count` points evenly spaced by arc length, endpoints included.
    public static func resample(_ points: [StrokePoint], count: Int) -> [StrokePoint] {
        guard points.count >= 2, count >= 2 else { return points }
        let total = polylineLength(points)
        guard total > 0 else { return [points[0]] }
        var out: [StrokePoint] = []
        out.reserveCapacity(count)
        out.append(points[0])
        var i = 0
        var walked: Float = 0
        var segment = simd_length(points[1].position - points[0].position)
        for k in 1..<(count - 1) {
            let target = total * Float(k) / Float(count - 1)
            while walked + segment < target && i < points.count - 2 {
                walked += segment
                i += 1
                segment = simd_length(points[i + 1].position - points[i].position)
            }
            let t = segment > 0 ? simd_clamp((target - walked) / segment, 0, 1) : 0
            let a = points[i], b = points[i + 1]
            out.append(StrokePoint(
                position: simd_mix(a.position, b.position, Vec3(repeating: t)),
                normal: GeometryMath.safeNormalize(simd_mix(a.normal, b.normal, Vec3(repeating: t)), fallback: a.normal),
                screen: simd_mix(a.screen, b.screen, Vec2(repeating: t)),
                pressure: a.pressure + (b.pressure - a.pressure) * t
            ))
        }
        out.append(points[points.count - 1])
        return out
    }
}
