import simd

/// Steadies a hand as it draws. The line is pulled along behind the Pencil on a short string, so a
/// tremble smaller than the string never reaches it. A real change of direction would come through
/// rounded off, so once the Pencil has clearly turned the line catches up by way of the corner it turned at.
public struct StrokeStabilizer {
    public private(set) var position: Vec2
    private var heading = Vec2.zero
    /// Where the Pencil has been that the line hasn't got to yet.
    private var ahead: [Vec2] = []
    private let reach: Float

    /// How long the string gets at full strength, in screen points.
    private static let longestReach: Float = 16
    /// How far off the line's heading the Pencil has to be to have turned: cos 45°.
    private static let turned: Float = 0.707
    /// Beyond this, cos 25°, it may be turning, so the line waits to see rather than drift off and come back.
    private static let turning: Float = 0.906

    /// `strength` runs from 0, which follows the Pencil exactly, to 1.
    public init(start: Vec2, strength: Float) {
        position = start
        reach = simd_clamp(strength, 0, 1) * Self.longestReach
    }

    /// The new points of the line with the Pencil at `screen`.
    public mutating func pull(to screen: Vec2) -> [Vec2] {
        let gap = screen - position
        let distance = simd_length(gap)
        ahead.append(screen)
        guard distance > reach else { return [] }
        var points: [Vec2] = []
        let along = simd_length_squared(heading) > 0 ? simd_dot(gap / distance, heading) : 1
        if along < Self.turned {
            if let corner = ahead.max(by: { distanceFromLine(to: screen, $0) < distanceFromLine(to: screen, $1) }), corner != screen {
                points.append(corner)
            }
            points.append(screen)
            heading = simd_normalize(screen - (points.count > 1 ? points[0] : position))
            position = screen
            ahead = []
            return points
        }
        guard along >= Self.turning else { return [] }
        let step = gap * ((distance - reach) / distance)
        position += step
        // Over a string's length of line, so that the start of a turn doesn't take the heading with it.
        let travelled = simd_length(step)
        heading = simd_normalize(heading + simd_normalize(step) * (simd_length_squared(heading) > 0 ? min(travelled / max(reach, 1), 1) : 1))
        ahead.removeAll { simd_dot($0 - position, heading) < 0 }
        return [position]
    }

    private func distanceFromLine(to end: Vec2, _ p: Vec2) -> Float {
        let line = end - position
        let length = simd_length(line)
        guard length > 0 else { return simd_length(p - position) }
        let offset = p - position
        return abs(offset.x * line.y - offset.y * line.x) / length
    }

    /// Where the line ends with the Pencil lifted at `screen`. It runs on as far as the Pencil went and
    /// in the direction it was heading, so it isn't left short and a flick on the way up can't turn it.
    public func end(at screen: Vec2) -> Vec2 {
        guard reach > 0, simd_length_squared(heading) > 0 else { return screen }
        return position + heading * min(reach, simd_length(screen - position))
    }
}
