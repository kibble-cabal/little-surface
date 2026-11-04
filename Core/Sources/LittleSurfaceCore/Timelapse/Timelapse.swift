import Foundation
import simd

/// One step of the work: how the mesh and sketch looked after it, where it happened, and how the
/// artist was looking at the model when they did it.
public struct TimelapseFrame: Equatable {
    /// Compressed mesh and sketch. Frames are packed as they're recorded, so saving never has to.
    public var geometry: Data
    public var focus: Vec3?
    public var orientation: simd_quatf

    public func decoded() throws -> (mesh: Mesh, sketches: [SketchStroke]) {
        try ProjectCodec.decodeTimelapseGeometry(geometry)
    }
}

/// Keeps a frame for every edit, off the main thread so that drawing never waits on it.
public final class TimelapseRecorder {
    /// A project can't grow without limit, so past this the frames thin out evenly across the session.
    public static let defaultByteBudget = 24 * 1024 * 1024
    /// As many as a timelapse of the longest length can show one video frame each.
    public static let frameLimit = TimelapseDirector.longestBodyFrames

    private let queue = DispatchQueue(label: "com.audreyserene.littlesurface.timelapse", qos: .utility)
    private let byteBudget: Int
    private var stored: [TimelapseFrame] = []
    private var storedBytes = 0
    private var lastMesh = Mesh()
    private var lastSketches: [SketchStroke] = []

    public init(byteBudget: Int = TimelapseRecorder.defaultByteBudget) {
        self.byteBudget = byteBudget
    }

    /// Waits for anything still being packed.
    public var frames: [TimelapseFrame] { queue.sync { stored } }

    public func record(mesh: Mesh, sketches: [SketchStroke], orientation: simd_quatf) {
        queue.async { [self] in
            append(mesh: mesh, sketches: sketches, focus: Self.focus(of: mesh, sketches, after: lastMesh, lastSketches), orientation: orientation)
        }
    }

    /// Picks up a saved project. One saved before its work was being recorded starts from how it is now.
    func load(_ frames: [TimelapseFrame], mesh: Mesh, sketches: [SketchStroke], orientation: simd_quatf) {
        queue.sync {
            stored = frames
            storedBytes = frames.reduce(0) { $0 + $1.geometry.count }
            lastMesh = mesh
            lastSketches = sketches
            if frames.isEmpty, mesh.vertexCount > 0 || !sketches.isEmpty {
                append(mesh: mesh, sketches: sketches, focus: nil, orientation: orientation)
            }
        }
    }

    private func append(mesh: Mesh, sketches: [SketchStroke], focus: Vec3?, orientation: simd_quatf) {
        let geometry = ProjectCodec.encodeTimelapseGeometry(mesh: mesh, sketches: sketches)
        stored.append(TimelapseFrame(geometry: geometry, focus: focus, orientation: orientation))
        storedBytes += geometry.count
        lastMesh = mesh
        lastSketches = sketches
        while stored.count > 2, storedBytes > byteBudget || stored.count > Self.frameLimit {
            let last = stored.count - 1
            stored = stored.enumerated().filter { $0.offset % 2 == 0 || $0.offset == last }.map(\.element)
            storedBytes = stored.reduce(0) { $0 + $1.geometry.count }
        }
    }

    /// The middle of whatever changed.
    private static func focus(of mesh: Mesh, _ sketches: [SketchStroke], after old: Mesh, _ oldSketches: [SketchStroke]) -> Vec3? {
        var sum = Vec3(repeating: 0)
        var count: Float = 0
        func add(_ p: Vec3) {
            sum += p
            count += 1
        }
        for v in 0..<max(mesh.positions.count, old.positions.count) {
            let alive = v < mesh.positions.count && mesh.vertexAlive[v]
            let wasAlive = v < old.positions.count && old.vertexAlive[v]
            if alive, !wasAlive || old.positions[v] != mesh.positions[v] {
                add(mesh.positions[v])
            } else if wasAlive, !alive {
                add(old.positions[v])
            }
        }
        // Faces and edges can come and go without any vertex moving.
        for f in 0..<max(mesh.faceLoops.count, old.faceLoops.count) {
            let alive = f < mesh.faceLoops.count && mesh.faceAlive[f]
            let wasAlive = f < old.faceLoops.count && old.faceAlive[f]
            if alive, !wasAlive {
                mesh.faceLoops[f].forEach { add(mesh.positions[Int($0)]) }
            } else if wasAlive, !alive {
                old.faceLoops[f].forEach { add(old.positions[Int($0)]) }
            }
        }
        for e in 0..<max(mesh.edgeEnds.count, old.edgeEnds.count) {
            let alive = e < mesh.edgeEnds.count && mesh.edgeAlive[e]
            let wasAlive = e < old.edgeEnds.count && old.edgeAlive[e]
            if alive, !wasAlive {
                let (a, b) = mesh.ends(EdgeID(e))
                add(mesh.position(a))
                add(mesh.position(b))
            } else if wasAlive, !alive {
                let (a, b) = old.ends(EdgeID(e))
                add(old.position(a))
                add(old.position(b))
            }
        }
        if sketches != oldSketches {
            for stroke in sketches where !oldSketches.contains(stroke) { stroke.points.forEach(add) }
            for stroke in oldSketches where !sketches.contains(stroke) { stroke.points.forEach(add) }
        }
        return count > 0 ? sum / count : nil
    }
}

/// One video frame: which step of the work to show, and from where.
public struct TimelapseShot: Equatable {
    /// -1 is the bare model, before the first edit.
    public var frameIndex: Int
    public var camera: Camera
}

/// Decides what the video shows and when. The camera turns to each part as the work reaches it, the
/// way the artist was looking at it, then finishes with one eased turn around the finished mesh.
public enum TimelapseDirector {
    public static let framesPerSecond = 30
    public static let secondsPerStep: Float = 0.4
    public static let shortestBody: Float = 3
    public static let longestBody: Float = 40
    public static let longestBodyFrames = Int(longestBody) * framesPerSecond

    static let intro: Float = 0.6
    static let outro: Float = 5
    static let hold: Float = 0.5
    /// The camera stays on one part at least this long, so a busy stretch doesn't make it twitch.
    static let shortestBeat: Float = 2.4
    /// Except that when the artist turned to another side of the model, the camera follows sooner.
    static let shortestBeatBeforeNewSide: Float = 1.4
    static let newSideAngle: Float = 25 * .pi / 180
    static let turnTime: Float = 1.4

    private struct Beat {
        var start: Float
        var orientation: simd_quatf
        var focusSum = Vec3(repeating: 0)
        var focusCount: Float = 0
    }

    public static func shots(for frames: [TimelapseFrame], bounds: AABB, camera base: Camera, viewSize: Vec2) -> [TimelapseShot] {
        guard !frames.isEmpty else { return [] }
        let fps = Float(framesPerSecond)
        let body = min(max(Float(frames.count) * secondsPerStep, shortestBody), longestBody)
        let bodyFrames = max(Int(body * fps), frames.count)
        let stepTime = Float(bodyFrames) / fps / Float(frames.count)
        let duration = Float(bodyFrames) / fps

        var beats: [Beat] = []
        for (i, frame) in frames.enumerated() {
            let time = Float(i) * stepTime
            var startsBeat = beats.isEmpty
            if let beat = beats.last, frame.focus != nil {
                let elapsed = time - beat.start
                let turned = 2 * acos(min(abs(simd_dot(simd_normalize(frame.orientation), simd_normalize(beat.orientation))), 1))
                startsBeat = elapsed >= shortestBeat || (elapsed >= shortestBeatBeforeNewSide && turned >= newSideAngle)
            }
            if startsBeat { beats.append(Beat(start: time, orientation: frame.orientation)) }
            if let focus = frame.focus {
                beats[beats.count - 1].focusSum += focus
                beats[beats.count - 1].focusCount += 1
            }
        }

        var framed = base
        framed.viewSize = viewSize
        framed.frame(bounds, padding: 1.2, updateSceneRadius: true)
        let center = framed.target
        let wide = framed.distance
        func target(_ beat: Beat) -> Vec3 {
            guard beat.focusCount > 0 else { return center }
            return simd_mix(center, beat.focusSum / beat.focusCount, Vec3(repeating: 0.35))
        }

        var shots: [TimelapseShot] = []
        func shot(_ index: Int, _ orientation: simd_quatf, _ aim: Vec3, _ distance: Float) {
            var camera = framed
            camera.orientation = simd_normalize(orientation)
            camera.target = aim
            camera.distance = distance
            shots.append(TimelapseShot(frameIndex: index, camera: camera))
        }

        func pose(at time: Float) -> (orientation: simd_quatf, aim: Vec3) {
            var k = 0
            while k + 1 < beats.count, beats[k + 1].start <= time { k += 1 }
            var orientation = beats[k].orientation
            var aim = target(beats[k])
            if k + 1 < beats.count {
                let next = beats[k + 1]
                let turn = min(turnTime, (next.start - beats[k].start) * 0.7)
                let s = smootherstep((time - (next.start - turn)) / turn)
                orientation = simd_slerp(orientation, next.orientation, s)
                aim = simd_mix(aim, target(next), Vec3(repeating: s))
            }
            // A slight sway, so a long stretch on one part still feels alive. It fades out at each end.
            let sway = sin(time * 0.6) * (3 * .pi / 180) * min(1, time, duration - time)
            return (simd_quatf(angle: sway, axis: Vec3(0, 1, 0)) * orientation, aim)
        }

        let start = pose(at: 0)
        let opensOnBareModel = frames[0].focus != nil
        for _ in 0..<Int(intro * fps) { shot(opensOnBareModel ? -1 : 0, start.orientation, start.aim, wide * 0.85) }
        for j in 0..<bodyFrames {
            let p = pose(at: Float(j) / fps)
            shot(j * frames.count / bodyFrames, p.orientation, p.aim, wide * 0.85)
        }
        let end = pose(at: duration)
        let outroFrames = Int(outro * fps)
        for j in 0..<outroFrames {
            let time = Float(j) / fps
            let spin = smootherstep(Float(j) / Float(outroFrames - 1)) * 2 * .pi
            let settle = smootherstep(time / turnTime)
            shot(frames.count - 1, simd_quatf(angle: spin, axis: Vec3(0, 1, 0)) * end.orientation,
                 simd_mix(end.aim, center, Vec3(repeating: settle)), simd_mix(wide * 0.85, wide, settle))
        }
        let finalOrientation = shots[shots.count - 1].camera.orientation
        for _ in 0..<Int(hold * fps) { shot(frames.count - 1, finalOrientation, center, wide) }
        return shots
    }

    private static func smootherstep(_ x: Float) -> Float {
        let t = simd_clamp(x, 0, 1)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
}
