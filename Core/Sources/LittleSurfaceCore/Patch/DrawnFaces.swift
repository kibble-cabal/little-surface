import Foundation
import simd

/// Keeps the faces in step with the lines: every area that lines fence in is one face, however many
/// corners it has, until more lines divide it.
public enum DrawnFaces {
    /// After a stroke: `result` is what it added, and `met` holds the points it used that were already
    /// there. `around` is the edges of any faces already taken out. `sliverWidth` is how far apart two
    /// lines can be and still read as one line drawn twice. Returns the sides that went straight.
    @discardableResult
    static func update(after result: PlanResult, met: [VertexID], around: [EdgeID] = [], sliverWidth: Float = 0, in mesh: inout Mesh, projector: SurfaceProjector?, symmetry: SymmetrySettings) throws -> [StraightenedSide] {
        mesh.settleBends()
        absorbRetracedLines(along: result.edges, in: &mesh, symmetry: symmetry)

        // A line reaches as far as the lines it joins, so two strokes can cut a face between them.
        var reached = Set(met.filter(mesh.isVertexAlive) + result.edges.flatMap { edge -> [VertexID] in
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
        // Before anything else is judged by them, since a sliver isn't really a shape of its own.
        mergeRetracedLines(in: &mesh, stroke: Set(result.edges), width: sliverWidth, symmetry: symmetry)
        added.removeAll { !mesh.isFaceAlive($0) }
        // A shape drawn entirely inside another leaves a hole that one face can't have, so the outer
        // one waits for lines that join them.
        for f in mesh.aliveFaces where !added.contains(f) && added.contains(where: { encloses(mesh.loop(f), $0, in: mesh) }) {
            mesh.removeFace(f)
        }
        // Whatever no outline remade, and nothing new has taken the place of, stays as it was.
        for loop in taken where mesh.findFace(withVertices: loop) == nil && mesh.canAddFace(loop) && !added.contains(where: { encloses(loop, $0, in: mesh) }) {
            try mesh.addFace(loop, autoOrient: false)
        }
        let straightened = mesh.straightenQuads(mirrored: symmetry.isEnabled)
        try layLinesOnModel(in: &mesh, projector: projector, symmetry: symmetry)
        return straightened
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

    /// A loose line that a stroke has gone over from end to end is that stroke now. Left in, it would
    /// run past whatever the stroke joined along the way, and the shapes there couldn't close.
    private static func absorbRetracedLines(along stroke: [EdgeID], in mesh: inout Mesh, symmetry: SymmetrySettings) {
        guard !stroke.isEmpty else { return }
        let drawn = Set(stroke)
        let segments = stroke.map { edge -> (Vec3, Vec3) in
            let (a, b) = mesh.ends(edge)
            return (mesh.position(a), mesh.position(b))
        }
        func distanceToStroke(_ p: Vec3) -> Float {
            segments.reduce(Float.infinity) { closest, segment in
                let span = segment.1 - segment.0
                let t = simd_clamp(simd_dot(p - segment.0, span) / max(simd_length_squared(span), 1e-12), 0, 1)
                return min(closest, simd_length(segment.0 + span * t - p))
            }
        }
        var seen = Set<EdgeID>()
        var gone = Set<EdgeID>()
        for edge in mesh.aliveEdges where mesh.isWire(edge) && !drawn.contains(edge) && !seen.contains(edge) {
            let (chain, points) = wholeLine(through: edge, in: mesh)
            seen.formUnion(chain)
            guard chain.allSatisfy({ mesh.isWire($0) && !drawn.contains($0) }), let start = points.first, let end = points.last else { continue }
            let limit = simd_length(mesh.position(start) - mesh.position(end)) * retracedLineLimit
            if points.allSatisfy({ distanceToStroke(mesh.position($0)) <= limit }) { gone.formUnion(chain) }
        }
        let mirrored = symmetry.activePlane != nil
        if mirrored { gone = Symmetry.expanded(edges: gone, in: mesh) }
        let ends = Set(gone.flatMap { edge -> [VertexID] in
            let (a, b) = mesh.ends(edge)
            return [a, b]
        })
        let strokes = mirrored ? Symmetry.expanded(edges: drawn, in: mesh) : drawn
        mesh.deleteEdges(gone)
        // Where it stopped was only ever the end of that line, so the stroke just carries on through.
        for v in ends where mesh.isVertexAlive(v) && mesh.edgesOf(v).count == 2 && mesh.edgesOf(v).allSatisfy(strokes.contains) {
            mesh.setBend(v, true)
        }
    }

    /// The edges of a line between its real points, and the vertices along it in order.
    private static func wholeLine(through edge: EdgeID, in mesh: Mesh) -> (edges: [EdgeID], points: [VertexID]) {
        func walk(from start: VertexID, leaving: EdgeID) -> (edges: [EdgeID], points: [VertexID]) {
            var edges: [EdgeID] = [], points = [start], at = start, through = leaving
            while mesh.isBendVertex(at), let next = mesh.edgesOf(at).first(where: { $0 != through }), next != edge {
                edges.append(next)
                at = mesh.otherEnd(next, from: at)
                points.append(at)
                through = next
            }
            return (edges, points)
        }
        let (a, b) = mesh.ends(edge)
        let back = walk(from: a, leaving: edge), on = walk(from: b, leaving: edge)
        return (back.edges + [edge] + on.edges, back.points.reversed() + on.points)
    }

    /// Going back over a line is how a line gets drawn on paper. It would otherwise leave a sliver of a
    /// shape between the two, so one of them stands for both: the new stroke if only one of them is, or
    /// else the longer. A stroke out and back along itself closes on a single point, and is one line too.
    static func mergeRetracedLines(in mesh: inout Mesh, stroke: Set<EdgeID> = [], width: Float = 0, symmetry: SymmetrySettings = SymmetrySettings()) {
        let drawn = symmetry.activePlane != nil ? Symmetry.expanded(edges: stroke.filter(mesh.isEdgeAlive), in: mesh) : stroke
        func merged(_ f: FaceID, in work: inout Mesh) -> Bool {
            func isNew(_ side: [VertexID]) -> Bool {
                zip(side, side.dropFirst()).contains { work.edge(between: $0, $1).map(drawn.contains) ?? false }
            }
            var loop = work.loop(f)
            guard (1...2).contains(work.cornerCount(of: f)), let first = loop.firstIndex(where: { !work.isBendVertex($0) }) else { return false }
            loop = Array(loop[first...] + loop[..<first])
            guard let second = loop.dropFirst().firstIndex(where: { !work.isBendVertex($0) }) ?? farthestAround(loop, in: work) else { return false }
            let sideA = Array(loop[...second])
            let sideB = Array(loop[second...]) + [loop[0]]
            guard isThin(sideA, sideB, width: width, in: work) else { return false }
            let newA = isNew(sideA), newB = isNew(sideB)
            let keepsA = newA != newB ? newA : length(of: sideA, in: work) >= length(of: sideB, in: work)
            let (kept, gone) = keepsA ? (sideA, sideB) : (sideB, sideA)
            return merge(gone, into: kept, removing: f, in: &work)
        }
        // Merging one sliver into the shape beside it can leave that shape a sliver too.
        var changed = true
        while changed {
            changed = false
            for f in mesh.aliveFaces where mesh.isFaceAlive(f) {
                var work = mesh
                guard (1...2).contains(mesh.cornerCount(of: f)) else { continue }
                // The two sides go together or not at all, so they can't drift apart.
                let image = symmetry.activePlane == nil ? nil : mirrorImage(of: f, in: mesh)
                guard merged(f, in: &work) else { continue }
                if let image, image != f, !work.isFaceAlive(image) || !merged(image, in: &work) { continue }
                mesh = work
                changed = true
            }
        }
        mesh.settleBends()
    }

    private static func mirrorImage(of f: FaceID, in mesh: Mesh) -> FaceID? {
        let image = mesh.loop(f).map { mesh.mirrorPartner[Int($0)] }
        guard image.allSatisfy({ $0 >= 0 }) else { return nil }
        return mesh.findFace(withVertices: image.map { VertexID($0) })
    }

    /// The point farthest from a loop's only real point, to divide it at. It's the same point whichever
    /// way the loop runs, so a mirrored loop divides the same way.
    private static func farthestAround(_ loop: [VertexID], in mesh: Mesh) -> Int? {
        guard loop.count >= 3 else { return nil }
        let start = mesh.position(loop[0])
        return (1..<loop.count).max { simd_length(mesh.position(loop[$0]) - start) < simd_length(mesh.position(loop[$1]) - start) }
    }

    private static func length(of side: [VertexID], in mesh: Mesh) -> Float {
        zip(side, side.dropFirst()).reduce(0) { $0 + simd_length(mesh.position($1.1) - mesh.position($1.0)) }
    }

    private static func isThin(_ a: [VertexID], _ b: [VertexID], width: Float, in mesh: Mesh) -> Bool {
        let limit = max(simd_length(mesh.position(a[0]) - mesh.position(a[a.count - 1])) * retracedLineLimit, width)
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
