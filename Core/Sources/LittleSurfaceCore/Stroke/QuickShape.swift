import Foundation
import simd

/// The clean shape a stroke was going for, on screen, for when the Pencil rests at the end of one.
public struct QuickShape: Equatable {
    public enum Kind: Equatable {
        case line, arc, corners, circle, ellipse, triangle, rectangle, polygon
    }

    public var kind: Kind
    /// The outline, closely spaced. A closed shape ends where it starts.
    public var points: [Vec2]
    /// Its sharp corners.
    public var corners: [Vec2] = []
    public var isClosed: Bool
    /// What stays put while the Pencil resizes and turns it: the start of an open shape, or the middle of a closed one.
    public var pivot: Vec2

    /// How finely the outline is spaced, in screen points.
    private static let spacing: Float = 3
    private static let shortestStroke: Float = 30
    /// The most a line can stray from straight, against its length.
    private static let straightLimit: Float = 0.1
    /// How far a stroke's ends can be apart to read as closed, against its length.
    private static let closedLimit: Float = 0.2
    /// How closely the corners of a shape have to follow the stroke, against its size.
    private static let cornerTolerance: Float = 0.06
    /// A turn gentler than this isn't a corner.
    private static let gentlestCorner: Float = 30 * .pi / 180
    /// How far from square a corner can be for four of them to read as a rectangle.
    private static let squareLimit: Float = 18 * .pi / 180
    /// How far from the stroke a circle's or an arc's outline can stray on average, against its radius.
    private static let roundLimit: Float = 0.1
    /// How near equal an ellipse's axes have to be to read as a circle.
    private static let circleLimit: Float = 0.87

    /// The shape, or nil for a stroke that doesn't look like going for anything.
    public static func recognize(_ stroke: [Vec2]) -> QuickShape? {
        let path = withoutRepeats(stroke)
        guard path.count >= 3, length(of: path) >= shortestStroke else { return nil }
        if let loop = closedPart(of: path) { return closedShape(from: loop) }
        return openShape(from: path)
    }

    /// The same shape after the Pencil has moved from one place to another, keeping the pivot where it is.
    public func dragged(from grabbed: Vec2, to here: Vec2) -> QuickShape {
        let was = grabbed - pivot, now = here - pivot
        guard simd_length(was) > 1, simd_length(now) > 1 else { return self }
        let scale = simd_length(now) / simd_length(was)
        let turn = atan2(now.y, now.x) - atan2(was.y, was.x)
        let c = cos(turn) * scale, s = sin(turn) * scale
        func moved(_ p: Vec2) -> Vec2 {
            let d = p - pivot
            return pivot + Vec2(d.x * c - d.y * s, d.x * s + d.y * c)
        }
        var out = self
        out.points = points.map(moved)
        out.corners = corners.map(moved)
        return out
    }

    // MARK: Open strokes

    private static func openShape(from path: [Vec2]) -> QuickShape? {
        let start = path[0], end = path[path.count - 1]
        let chord = simd_length(end - start)
        if chord > 0, path.map({ distance($0, toSegment: start, end) }).max()! <= chord * straightLimit {
            return QuickShape(kind: .line, points: outline(through: [start, end]), isClosed: false, pivot: start)
        }
        let size = boundsDiagonal(of: path)
        let simplified = simplify(path, tolerance: size * cornerTolerance)
        let corners = sharp(simplified, isClosed: false)
        if let arc = arc(from: path), corners.count < 3 || arc.error <= polylineError(path, simplified) {
            return arc.shape
        }
        guard corners.count >= 3, corners.count <= 8 else { return nil }
        return QuickShape(kind: .corners, points: outline(through: corners), corners: Array(corners.dropFirst().dropLast()), isClosed: false, pivot: start)
    }

    private static func arc(from path: [Vec2]) -> (shape: QuickShape, error: Float)? {
        guard let fit = circle(through: path) else { return nil }
        let error = path.reduce(0) { $0 + abs(simd_length($1 - fit.center) - fit.radius) } / Float(path.count)
        guard error <= fit.radius * roundLimit else { return nil }
        // The way round it, added up along the stroke so it can go past a half turn.
        var sweep: Float = 0
        for (a, b) in zip(path, path.dropFirst()) {
            let from = a - fit.center, to = b - fit.center
            sweep += atan2(from.x * to.y - from.y * to.x, simd_dot(from, to))
        }
        let begin = path[0] - fit.center, startAngle = atan2(begin.y, begin.x)
        let steps = max(Int(abs(sweep) * fit.radius / spacing), 8)
        let points = (0...steps).map { i -> Vec2 in
            let angle = startAngle + sweep * Float(i) / Float(steps)
            return fit.center + Vec2(cos(angle), sin(angle)) * fit.radius
        }
        return (QuickShape(kind: .arc, points: points, isClosed: false, pivot: points[0]), error)
    }

    private static func polylineError(_ path: [Vec2], _ corners: [Vec2]) -> Float {
        path.reduce(0) { total, p in
            total + zip(corners, corners.dropFirst()).map { distance(p, toSegment: $0, $1) }.min()!
        } / Float(path.count)
    }

    /// The circle closest to these points, by least squares on the circle's equation.
    private static func circle(through path: [Vec2]) -> (center: Vec2, radius: Float)? {
        let mean = path.reduce(.zero, +) / Float(path.count)
        var xx: Float = 0, xy: Float = 0, yy: Float = 0, xr: Float = 0, yr: Float = 0
        for p in path {
            let d = p - mean, r = simd_length_squared(d)
            xx += d.x * d.x
            xy += d.x * d.y
            yy += d.y * d.y
            xr += d.x * r
            yr += d.y * r
        }
        let det = 2 * (xx * yy - xy * xy)
        guard abs(det) > 1e-3 else { return nil }
        let center = Vec2((xr * yy - yr * xy) / det, (yr * xx - xr * xy) / det)
        let radius = path.reduce(0) { $0 + simd_length($1 - mean - center) } / Float(path.count)
        guard radius.isFinite, radius > 1, radius < boundsDiagonal(of: path) * 10 else { return nil }
        return (mean + center, radius)
    }

    // MARK: Closed strokes

    /// The part of a stroke that goes round, leaving off any overshoot past its start.
    private static func closedPart(of path: [Vec2]) -> [Vec2]? {
        let total = length(of: path)
        var walked: Float = 0
        var along = [Float](repeating: 0, count: path.count)
        for i in 1..<path.count {
            walked += simd_length(path[i] - path[i - 1])
            along[i] = walked
        }
        var best: (from: Int, to: Int, gap: Float)?
        for i in path.indices where along[i] <= total * 0.15 {
            for j in path.indices.reversed() where along[j] >= total * 0.7 {
                let gap = simd_length(path[i] - path[j])
                if gap < (best?.gap ?? .infinity) { best = (i, j, gap) }
            }
        }
        guard let best, best.gap <= total * closedLimit, best.to - best.from >= 3 else { return nil }
        return Array(path[best.from...best.to])
    }

    private static func closedShape(from loop: [Vec2]) -> QuickShape? {
        let size = boundsDiagonal(of: loop)
        let ellipse = ellipse(from: loop)
        let corners = closedCorners(of: loop, size: size)
        let isPolygon = (3...6).contains(corners.count) && (ellipse == nil || polygonError(loop, corners) < ellipse!.error)
        if isPolygon {
            let start = loop[0]
            let first = corners.indices.min { simd_length(corners[$0] - start) < simd_length(corners[$1] - start) }!
            var ordered = Array(corners[first...] + corners[..<first])
            var kind: Kind = corners.count == 3 ? .triangle : .polygon
            if corners.count == 4, let square = rectangle(from: ordered) {
                ordered = square
                kind = .rectangle
            }
            let middle = ordered.reduce(.zero, +) / Float(ordered.count)
            return QuickShape(kind: kind, points: outline(through: ordered + [ordered[0]]), corners: ordered, isClosed: true, pivot: middle)
        }
        return ellipse?.shape(startingNear: loop[0])
    }

    private static func closedCorners(of loop: [Vec2], size: Float) -> [Vec2] {
        // Split at the point farthest from the start, so neither half is a loop.
        let farthest = loop.indices.max { simd_length(loop[$0] - loop[0]) < simd_length(loop[$1] - loop[0]) }!
        let tolerance = size * cornerTolerance
        let one = simplify(Array(loop[...farthest]), tolerance: tolerance)
        let other = simplify(Array(loop[farthest...]) + [loop[0]], tolerance: tolerance)
        return sharp(one + other.dropFirst().dropLast(), isClosed: true)
    }

    private static func polygonError(_ loop: [Vec2], _ corners: [Vec2]) -> Float {
        loop.reduce(0) { total, p in
            total + corners.indices.map { distance(p, toSegment: corners[$0], corners[($0 + 1) % corners.count]) }.min()!
        } / Float(loop.count)
    }

    /// Four corners that are all near enough square, squared up.
    private static func rectangle(from corners: [Vec2]) -> [Vec2]? {
        var pull = Vec2.zero
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4], c = corners[(i + 2) % 4]
            let in1 = simd_normalize(a - b), in2 = simd_normalize(c - b)
            guard abs(acos(simd_clamp(simd_dot(in1, in2), -1, 1)) - .pi / 2) <= squareLimit else { return nil }
            // Directions a quarter turn apart count as the same, by going four times as far round.
            let angle = atan2(c.y - b.y, c.x - b.x) * 4
            pull += Vec2(cos(angle), sin(angle))
        }
        let angle = atan2(pull.y, pull.x) / 4
        var along = Vec2(cos(angle), sin(angle))
        // Whichever of the two axes the first side runs nearest to.
        if abs(simd_dot(along, simd_normalize(corners[1] - corners[0]))) < 0.7 { along = Vec2(-along.y, along.x) }
        if simd_dot(along, corners[1] - corners[0]) < 0 { along = -along }
        var across = Vec2(-along.y, along.x)
        if simd_dot(across, corners[3] - corners[0]) < 0 { across = -across }
        let middle = corners.reduce(.zero, +) / 4
        let width = (simd_dot(corners[1] - corners[0], along) + simd_dot(corners[2] - corners[3], along)) / 2
        let height = (simd_dot(corners[3] - corners[0], across) + simd_dot(corners[2] - corners[1], across)) / 2
        let w = along * width / 2, h = across * height / 2
        return [middle - w - h, middle + w - h, middle + w + h, middle - w + h]
    }

    private struct Ellipse {
        var center: Vec2
        var axis: Vec2
        var a: Float, b: Float
        var error: Float

        func shape(startingNear start: Vec2) -> QuickShape {
            let isCircle = b / a >= QuickShape.circleLimit
            let major = isCircle ? (a + b) / 2 : a, minor = isCircle ? major : b
            let across = Vec2(-axis.y, axis.x)
            let d = start - center
            let startAngle = atan2(simd_dot(d, across) / minor, simd_dot(d, axis) / major)
            let steps = max(Int(2 * .pi * major / QuickShape.spacing), 24)
            var points = (0..<steps).map { i -> Vec2 in
                let t = startAngle + 2 * .pi * Float(i) / Float(steps)
                return center + axis * (cos(t) * major) + across * (sin(t) * minor)
            }
            points.append(points[0])
            return QuickShape(kind: isCircle ? .circle : .ellipse, points: points, isClosed: true, pivot: center)
        }
    }

    /// The ellipse with the same spread as the stroke, or nil if it's nothing like the stroke.
    private static func ellipse(from loop: [Vec2]) -> Ellipse? {
        let even = evenlySpaced(loop, count: 96)
        let center = even.reduce(.zero, +) / Float(even.count)
        var xx: Float = 0, xy: Float = 0, yy: Float = 0
        for p in even {
            let d = p - center
            xx += d.x * d.x
            xy += d.x * d.y
            yy += d.y * d.y
        }
        let n = Float(even.count)
        xx /= n
        xy /= n
        yy /= n
        let middle = (xx + yy) / 2, spread = sqrt(max((xx - yy) * (xx - yy) / 4 + xy * xy, 0))
        let large = middle + spread, small = max(middle - spread, 0)
        let angle = 0.5 * atan2(2 * xy, xx - yy)
        let axis = Vec2(cos(angle), sin(angle)), across = Vec2(-axis.y, axis.x)
        // Round an ellipse, the average of the squared distance along an axis is half its squared radius.
        let a = sqrt(2 * large), b = sqrt(2 * small)
        guard b > 1 else { return nil }
        var total: Float = 0
        for p in even {
            let d = p - center
            let r = sqrt(pow(simd_dot(d, axis) / a, 2) + pow(simd_dot(d, across) / b, 2))
            // Off by that share of the radius, roughly, at this point.
            total += abs(r - 1) * simd_length(d) / max(r, 1e-3)
        }
        let error = total / n
        guard error <= (a + b) / 2 * roundLimit else { return nil }
        return Ellipse(center: center, axis: axis, a: a, b: b, error: error)
    }

    // MARK: Paths

    private static func withoutRepeats(_ stroke: [Vec2]) -> [Vec2] {
        var out: [Vec2] = []
        for p in stroke where out.last.map({ simd_length($0 - p) >= 0.5 }) ?? true { out.append(p) }
        return out
    }

    private static func length(of path: [Vec2]) -> Float {
        zip(path, path.dropFirst()).reduce(0) { $0 + simd_length($1.1 - $1.0) }
    }

    private static func boundsDiagonal(of path: [Vec2]) -> Float {
        var low = path[0], high = path[0]
        for p in path {
            low = simd_min(low, p)
            high = simd_max(high, p)
        }
        return simd_length(high - low)
    }

    private static func distance(_ p: Vec2, toSegment a: Vec2, _ b: Vec2) -> Float {
        let span = b - a
        let t = simd_clamp(simd_dot(p - a, span) / max(simd_length_squared(span), 1e-6), 0, 1)
        return simd_length(a + span * t - p)
    }

    /// Fewest points that stay within the tolerance of the path, by Douglas-Peucker.
    private static func simplify(_ path: [Vec2], tolerance: Float) -> [Vec2] {
        guard path.count > 2 else { return path }
        var farthest = 0
        var most: Float = 0
        for i in 1..<(path.count - 1) {
            let d = distance(path[i], toSegment: path[0], path[path.count - 1])
            if d > most {
                most = d
                farthest = i
            }
        }
        guard most > tolerance else { return [path[0], path[path.count - 1]] }
        return simplify(Array(path[...farthest]), tolerance: tolerance).dropLast() + simplify(Array(path[farthest...]), tolerance: tolerance)
    }

    /// Takes out points the outline barely turns at, gentlest first.
    private static func sharp(_ points: [Vec2], isClosed: Bool) -> [Vec2] {
        var out = points
        func turn(at i: Int) -> Float {
            let n = out.count
            let a = out[(i + n - 1) % n], b = out[i], c = out[(i + 1) % n]
            guard simd_length(b - a) > 1e-3, simd_length(c - b) > 1e-3 else { return 0 }
            return acos(simd_clamp(simd_dot(simd_normalize(b - a), simd_normalize(c - b)), -1, 1))
        }
        while out.count > (isClosed ? 3 : 2) {
            let inner = isClosed ? Array(out.indices) : Array(out.indices.dropFirst().dropLast())
            guard let gentlest = inner.min(by: { turn(at: $0) < turn(at: $1) }), turn(at: gentlest) < gentlestCorner else { break }
            out.remove(at: gentlest)
        }
        return out
    }

    private static func outline(through corners: [Vec2]) -> [Vec2] {
        var out = [corners[0]]
        for (a, b) in zip(corners, corners.dropFirst()) {
            let steps = max(Int(simd_length(b - a) / spacing), 1)
            for i in 1...steps { out.append(simd_mix(a, b, Vec2(repeating: Float(i) / Float(steps)))) }
        }
        return out
    }

    private static func evenlySpaced(_ path: [Vec2], count: Int) -> [Vec2] {
        let total = length(of: path)
        guard total > 0 else { return path }
        var out: [Vec2] = []
        var i = 0
        var walked: Float = 0
        for k in 0..<count {
            let target = total * Float(k) / Float(count)
            while i < path.count - 2, walked + simd_length(path[i + 1] - path[i]) < target {
                walked += simd_length(path[i + 1] - path[i])
                i += 1
            }
            let segment = simd_length(path[i + 1] - path[i])
            let t = segment > 0 ? simd_clamp((target - walked) / segment, 0, 1) : 0
            out.append(simd_mix(path[i], path[i + 1], Vec2(repeating: t)))
        }
        return out
    }
}
