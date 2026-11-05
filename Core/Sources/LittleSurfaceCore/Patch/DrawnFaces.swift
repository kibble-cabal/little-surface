import Foundation
import simd

/// Keeps the faces in step with the lines: every area that lines fence in is one face, however many
/// corners it has, until more lines divide it.
public enum DrawnFaces {
    /// After a stroke: `result` is what it added, and `met` holds the points it used that were already
    /// there. `around` is the edges of any faces already taken out.
    static func update(after result: PlanResult, met: [VertexID], around: [EdgeID] = [], in mesh: inout Mesh, projector: SurfaceProjector?, symmetry: SymmetrySettings) throws {
        mesh.settleBends()

        // A line reaches as far as the lines it joins, so two strokes can cut a face between them.
        var reached = Set(met + result.edges.flatMap { edge -> [VertexID] in
            let (a, b) = mesh.ends(edge)
            return [a, b]
        })
        for v in reached where mesh.mirrorPartner[Int(v)] >= 0 { reached.insert(mesh.mirrorPartner[Int(v)]) }
        var frontier = Array(reached)
        var border = result.edges + around
        while let v = frontier.popLast() {
            for e in mesh.edgesOf(v) where mesh.isWire(e) {
                border.append(e)
                let other = mesh.otherEnd(e, from: v)
                if reached.insert(other).inserted { frontier.append(other) }
            }
        }

        // Any face with two of those on it may now be divided. If it isn't, the same outline remakes it.
        var taken: [[VertexID]] = []
        for f in mesh.aliveFaces where mesh.loop(f).filter(reached.contains).count >= 2 {
            taken.append(mesh.loop(f))
            border += mesh.edgeLoop(f)
            mesh.removeFace(f)
        }

        var added: [FaceID] = []
        for outline in EnclosedRegions.regions(bordering: border, in: mesh, projector: projector) where mesh.canAddFace(outline.vertices) {
            added.append(try mesh.addFace(outline.vertices, autoOrient: false))
        }
        // A shape drawn entirely inside another leaves a hole that one face can't have, so the outer
        // one waits for lines that join them.
        for f in mesh.aliveFaces where !added.contains(f) && added.contains(where: { encloses(mesh.loop(f), $0, in: mesh) }) {
            mesh.removeFace(f)
        }
        // Whatever no outline remade, and nothing new has taken the place of, stays as it was.
        for loop in taken where mesh.findFace(withVertices: loop) == nil && mesh.canAddFace(loop) && !added.contains(where: { encloses(loop, $0, in: mesh) }) {
            try mesh.addFace(loop, autoOrient: false)
        }
        mergeRetracedLines(in: &mesh)
        mesh.straightenQuads(mirrored: symmetry.isEnabled)
        try layLinesOnModel(in: &mesh, projector: projector, symmetry: symmetry)
    }

    /// How far a straight line can stand off the model, against its length, before it's put back on.
    private static let liftedLineLimit: Float = 0.05
    private static let liftedLinePieces = 8

    /// Only a quad's sides are straight. A straight line left over from a quad that's since gained a
    /// corner goes back to lying on the model as a pencil line does, rather than spanning any dips.
    private static func layLinesOnModel(in mesh: inout Mesh, projector: SurfaceProjector?, symmetry: SymmetrySettings) throws {
        guard let projector else { return }
        var plan = TopologyPlan()
        var covered = Set<EdgeID>()
        for e in mesh.aliveEdges where !covered.contains(e) && !mesh.facesOf(edge: e).contains(where: mesh.isQuad) {
            let (a, b) = mesh.ends(e)
            guard !mesh.isBendVertex(a), !mesh.isBendVertex(b) else { continue }
            let pa = mesh.position(a), pb = mesh.position(b)
            func onModel(_ t: Float) -> SurfaceHit? {
                projector.closest(to: simd_mix(pa, pb, Vec3(repeating: t)), maxDistance: .greatestFiniteMagnitude)
            }
            let limit = simd_length(pb - pa) * liftedLineLimit
            let lifted = [0.25, 0.5, 0.75].contains { (t: Float) in
                guard let hit = onModel(t) else { return false }
                return simd_length(hit.position - simd_mix(pa, pb, Vec3(repeating: t))) > limit
            }
            guard lifted else { continue }
            if symmetry.activePlane != nil, let mirror = Symmetry.mirrorEdge(of: e, in: mesh) {
                // A line along the middle is its own mirror image, and the other side of one follows it.
                if mirror == e { continue }
                covered.insert(mirror)
            }
            for piece in 1..<liftedLinePieces {
                let t = Float(piece) / Float(liftedLinePieces)
                guard let hit = onModel(t) else { continue }
                plan.bends.insert(Int32(plan.nodes.count))
                plan.nodes.append(.split(edge: e, t: t, position: hit.position + hit.normal * projector.surfaceOffset))
            }
        }
        guard !plan.nodes.isEmpty else { return }
        _ = try PlanApplier.apply(plan, to: &mesh, symmetry: symmetry, projector: projector)
    }

    /// How far apart two lines between the same two points can be, against how far apart those points
    /// are, and still be one line drawn twice rather than a narrow shape.
    private static let retracedLineLimit: Float = 0.08

    /// Going back over a line is how a line gets drawn on paper. It would otherwise leave a sliver of a
    /// shape between the two, so the longer of them stands for both.
    private static func mergeRetracedLines(in mesh: inout Mesh) {
        for f in mesh.aliveFaces where mesh.isFaceAlive(f) && mesh.cornerCount(of: f) == 2 {
            var loop = mesh.loop(f)
            guard let first = loop.firstIndex(where: { !mesh.isBendVertex($0) }) else { continue }
            loop = Array(loop[first...] + loop[..<first])
            guard let second = loop.dropFirst().firstIndex(where: { !mesh.isBendVertex($0) }) else { continue }
            let sideA = Array(loop[...second])
            let sideB = Array(loop[second...]) + [loop[0]]
            guard isThin(sideA, sideB, in: mesh) else { continue }
            let (kept, gone) = length(of: sideA, in: mesh) >= length(of: sideB, in: mesh) ? (sideA, sideB) : (sideB, sideA)
            var work = mesh
            if merge(gone, into: kept, removing: f, in: &work) { mesh = work }
        }
    }

    private static func length(of side: [VertexID], in mesh: Mesh) -> Float {
        zip(side, side.dropFirst()).reduce(0) { $0 + simd_length(mesh.position($1.1) - mesh.position($1.0)) }
    }

    private static func isThin(_ a: [VertexID], _ b: [VertexID], in mesh: Mesh) -> Bool {
        let limit = simd_length(mesh.position(a[0]) - mesh.position(a[a.count - 1])) * retracedLineLimit
        func reach(from points: [VertexID], to line: [VertexID]) -> Float {
            points.reduce(0) { farthest, v in
                let p = mesh.position(v)
                let nearest = zip(line, line.dropFirst()).reduce(Float.infinity) { closest, segment in
                    let s = mesh.position(segment.0), span = mesh.position(segment.1) - s
                    let t = simd_clamp(simd_dot(p - s, span) / max(simd_length_squared(span), 1e-12), 0, 1)
                    return min(closest, simd_length(s + span * t - p))
                }
                return max(farthest, nearest)
            }
        }
        return reach(from: a, to: b) <= limit && reach(from: b, to: a) <= limit
    }

    /// `kept` runs one way round the sliver and `gone` carries on from its end back to its start, so
    /// whatever was on the far side of `gone` takes `kept` in the direction it already runs.
    private static func merge(_ gone: [VertexID], into kept: [VertexID], removing sliver: FaceID, in mesh: inout Mesh) -> Bool {
        let goneEdges = zip(gone, gone.dropFirst()).compactMap { mesh.edge(between: $0, $1) }
        guard goneEdges.count == gone.count - 1 else { return false }
        let beside = mesh.facesOf(edge: goneEdges[0]).first { $0 != sliver }
        var outline: [VertexID]?
        if let beside {
            var loop = mesh.loop(beside)
            // Running the same way as `kept`, which is the opposite way to the sliver along `gone`.
            guard let start = loop.firstIndex(of: kept[0]) else { return false }
            loop = Array(loop[start...] + loop[..<start])
            guard let end = loop.firstIndex(of: kept[kept.count - 1]), Array(loop[...end]) == Array(gone.reversed()) else { return false }
            outline = kept + Array(loop[(end + 1)...])
        }
        mesh.removeFace(sliver)
        if let beside { mesh.removeFace(beside) }
        mesh.deleteEdges(Set(goneEdges))
        guard let outline else { return true }
        guard mesh.canAddFace(outline) else { return false }
        return (try? mesh.addFace(outline, autoOrient: false)) != nil
    }

    private static func encloses(_ loop: [VertexID], _ face: FaceID, in mesh: Mesh) -> Bool {
        guard mesh.isFaceAlive(face), !mesh.loop(face).allSatisfy(loop.contains) else { return false }
        let points = loop.map { mesh.position($0) }
        let facing = GeometryMath.newellNormal(points)
        guard simd_length_squared(facing) > 0, simd_dot(facing, mesh.faceNormal(face)) > 0 else { return false }
        let center = mesh.faceCenter(face)
        let middle = points.reduce(.zero, +) / Float(points.count)
        guard simd_length(center - middle) <= points.map({ simd_length($0 - middle) }).max() ?? 0 else { return false }
        return EnclosedRegions.contains(center, outline: points, axis: simd_normalize(facing))
    }
}
