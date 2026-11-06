import Foundation
import simd

extension Symmetry {
    /// Joins a real point to whatever is at its mirror place, so that what's drawn from it on one side
    /// meets the same line on the other. A point there pairs up. Otherwise the nearest line takes a
    /// point of its own. Nil if there's nothing within reach.
    @discardableResult
    static func joinOtherSide(of v: VertexID, in mesh: inout Mesh, plane: MirrorPlane, reach: Float, projector: SurfaceProjector?) -> VertexID? {
        guard mesh.isVertexAlive(v), mesh.mirrorPartner[Int(v)] < 0 else { return nil }
        let target = plane.reflect(mesh.position(v))
        let side = plane.signedDistance(mesh.position(v))

        var closestPoint: (VertexID, Float)?
        for w in mesh.aliveVertices where w != v && !mesh.isBendVertex(w) && mesh.mirrorPartner[Int(w)] < 0 {
            let d = simd_length(mesh.position(w) - target)
            if d <= reach, d < (closestPoint?.1 ?? .infinity) { closestPoint = (w, d) }
        }
        if let (w, _) = closestPoint {
            pair(v, w, in: &mesh)
            return w
        }

        var best: (edge: EdgeID, t: Float, distance: Float)?
        for e in mesh.aliveEdges {
            let (a, b) = mesh.ends(e)
            guard a != v, b != v else { continue }
            let pa = mesh.position(a), pb = mesh.position(b)
            guard plane.signedDistance(pa) * side <= 0, plane.signedDistance(pb) * side <= 0 else { continue }
            let span = pb - pa
            let t = simd_clamp(simd_dot(target - pa, span) / max(simd_length_squared(span), 1e-12), 0, 1)
            let d = simd_length(pa + span * t - target)
            if d <= reach, d < (best?.distance ?? .infinity) { best = (e, t, d) }
        }
        guard let best else { return nil }
        let (a, b) = mesh.ends(best.edge)
        // Right beside a bend, that bend becomes the point, rather than leaving a tiny line next to it.
        let beside = reach * 0.25
        for end in [a, b] where mesh.isBendVertex(end) && simd_length(mesh.position(end) - target) <= beside {
            mesh.setMirrorPartner(end, invalidID)
            mesh.setBend(end, false)
            pair(v, end, in: &mesh)
            return end
        }
        guard best.t > 0.001, best.t < 0.999,
              let split = try? mesh.splitEdge(best.edge, at: best.t, position: simd_mix(mesh.position(a), mesh.position(b), Vec3(repeating: best.t))) else { return nil }
        mesh.setBend(split.vertex, false)
        pair(v, split.vertex, in: &mesh)
        return split.vertex
    }

    private static func pair(_ a: VertexID, _ b: VertexID, in mesh: inout Mesh) {
        mesh.setMirrorPartner(a, b)
        mesh.setMirrorPartner(b, a)
    }

    /// Whether both sides already mirror each other, point for point and line for line.
    static func isMatched(_ mesh: Mesh) -> Bool {
        for v in mesh.aliveVertices {
            let partner = mesh.mirrorPartner[Int(v)]
            guard partner >= 0, mesh.isVertexAlive(partner), mesh.mirrorPartner[Int(partner)] == v, mesh.isBendVertex(v) == mesh.isBendVertex(partner) else { return false }
        }
        return mesh.aliveEdges.allSatisfy { mirrorEdge(of: $0, in: mesh) != nil }
    }

    /// Lines drawn before mirror was on, some of them by hand on both sides. Afterwards each one that
    /// has a near match across the middle mirrors it exactly, point for point, in order. What's left
    /// is returned as a plan, which under mirror copies those lines across.
    static func matchExistingLines(in mesh: inout Mesh, plane: MirrorPlane, centerTolerance: Float, reach: Float, projector: SurfaceProjector?, searchRadius: Float) -> TopologyPlan {
        func mirrored(_ v: VertexID) -> Vec3 {
            let n = mesh.vertexNormal(v)
            return mirroredPosition(of: mesh.position(v), normal: simd_length_squared(n) > 1e-8 ? n : nil, plane: plane, projector: projector, searchRadius: searchRadius)
        }

        // Pairs that can't be right.
        for v in mesh.aliveVertices {
            let partner = mesh.mirrorPartner[Int(v)]
            guard partner >= 0, partner != v else { continue }
            if !mesh.isVertexAlive(partner) || mesh.mirrorPartner[Int(partner)] != v || mesh.isBendVertex(v) != mesh.isBendVertex(partner) {
                mesh.setMirrorPartner(v, invalidID)
            }
        }
        // On the middle. A real point near it is on it. Bends near it have to go by what their line is
        // doing, since a line going over the middle only has one point there, however close the next ones.
        func isNearMiddle(_ v: VertexID) -> Bool { abs(plane.signedDistance(mesh.position(v))) <= centerTolerance }
        for v in mesh.aliveVertices where !mesh.isBendVertex(v) && isNearMiddle(v) {
            mesh.setPosition(v, plane.snap(mesh.position(v)))
            mesh.setMirrorPartner(v, v)
        }
        var settled = Set<VertexID>()
        for v in mesh.aliveVertices where mesh.isBendVertex(v) && isNearMiddle(v) && !settled.contains(v) {
            var run = [v]
            var outer: [VertexID] = []
            for first in mesh.edgesOf(v) {
                var previous = v, through = first
                while true {
                    let next = mesh.otherEnd(through, from: previous)
                    guard next != v, mesh.isBendVertex(next), isNearMiddle(next), let on = mesh.edgesOf(next).first(where: { $0 != through }) else {
                        if next != v { outer.append(next) }
                        break
                    }
                    run.append(next)
                    previous = next
                    through = on
                }
            }
            settled.formUnion(run)
            let sides = outer.map { plane.signedDistance(mesh.position($0)) }
            let alongMiddle = outer.allSatisfy(isNearMiddle)
            let goesOver = sides.count == 2 && sides[0] * sides[1] < 0 && !outer.contains(where: isNearMiddle)
            let onIt = goesOver ? run.min { abs(plane.signedDistance(mesh.position($0))) < abs(plane.signedDistance(mesh.position($1))) } : nil
            for u in run {
                if alongMiddle || u == onIt {
                    mesh.setPosition(u, plane.snap(mesh.position(u)))
                    mesh.setMirrorPartner(u, u)
                } else if mesh.mirrorPartner[Int(u)] == u {
                    mesh.setMirrorPartner(u, invalidID)
                }
            }
        }
        // A line going over the middle is two lines, one each side, meeting there.
        for e in mesh.aliveEdges {
            let (a, b) = mesh.ends(e)
            let da = plane.signedDistance(mesh.position(a)), db = plane.signedDistance(mesh.position(b))
            guard da * db < 0, mesh.mirrorPartner[Int(a)] != a, mesh.mirrorPartner[Int(b)] != b, mesh.mirrorPartner[Int(a)] != b else { continue }
            let t = da / (da - db)
            let p = plane.snap(simd_mix(mesh.position(a), mesh.position(b), Vec3(repeating: t)))
            guard let split = try? mesh.splitEdge(e, at: t, position: p) else { continue }
            mesh.setBend(split.vertex, true)
            mesh.setMirrorPartner(split.vertex, split.vertex)
        }

        // Points opposite each other, nearest first.
        var loose = mesh.aliveVertices.filter { !mesh.isBendVertex($0) && mesh.mirrorPartner[Int($0)] < 0 }
        var options: [(Float, VertexID, VertexID)] = []
        for (i, a) in loose.enumerated() {
            let target = plane.reflect(mesh.position(a))
            for b in loose[(i + 1)...] {
                let d = simd_length(mesh.position(b) - target)
                if d <= reach { options.append((d, a, b)) }
            }
        }
        for (_, a, b) in options.sorted(by: { $0.0 < $1.0 }) where mesh.mirrorPartner[Int(a)] < 0 && mesh.mirrorPartner[Int(b)] < 0 {
            pair(a, b, in: &mesh)
        }
        // A point with only a line opposite it puts a point on that line.
        loose = mesh.aliveVertices.filter { !mesh.isBendVertex($0) && mesh.mirrorPartner[Int($0)] < 0 }
        for v in loose { joinOtherSide(of: v, in: &mesh, plane: plane, reach: reach, projector: projector) }
        // The earlier of each pair stays where it is.
        for v in mesh.aliveVertices.sorted() where !mesh.isBendVertex(v) {
            let partner = mesh.mirrorPartner[Int(v)]
            guard partner > v, simd_length(plane.reflect(mesh.position(v)) - mesh.position(partner)) > 1e-5 else { continue }
            mesh.setPosition(partner, mirrored(v))
        }

        // Line by line, each bend paired in order along it.
        func isEnd(_ v: VertexID) -> Bool { !mesh.isBendVertex(v) || mesh.mirrorPartner[Int(v)] == v }
        func walk(from start: VertexID, along edge: EdgeID) -> [VertexID] {
            var line = [start, mesh.otherEnd(edge, from: start)]
            var through = edge
            while !isEnd(line[line.count - 1]), line.count <= mesh.vertexCount {
                guard let next = mesh.edgesOf(line[line.count - 1]).first(where: { $0 != through }) else { break }
                through = next
                line.append(mesh.otherEnd(next, from: line[line.count - 1]))
            }
            return line
        }
        func points(_ line: [VertexID], count: Int) -> [Vec3] {
            var along: [Float] = [0]
            for (a, b) in zip(line, line.dropFirst()) { along.append(along[along.count - 1] + simd_length(mesh.position(b) - mesh.position(a))) }
            let length = along[along.count - 1]
            return (0..<count).map { i in
                let distance = length * Float(i) / Float(max(count - 1, 1))
                let next = max(along.firstIndex { $0 >= distance } ?? line.count - 1, 1)
                let t = (distance - along[next - 1]) / max(along[next] - along[next - 1], 1e-9)
                return simd_mix(mesh.position(line[next - 1]), mesh.position(line[next]), Vec3(repeating: t))
            }
        }
        func deviation(_ line: [VertexID], _ other: [VertexID]) -> Float {
            let here = points(line, count: 16), there = points(other, count: 16)
            return zip(here, there).reduce(0) { max($0, simd_length(plane.reflect($1.0) - $1.1)) }
        }

        var done = Set<EdgeID>()
        for start in mesh.aliveVertices.sorted() where isEnd(start) {
            for edge in mesh.edgesOf(start) where !done.contains(edge) {
                guard mesh.isEdgeAlive(edge) else { continue }
                let line = walk(from: start, along: edge)
                let lineEdges = Set(zip(line, line.dropFirst()).compactMap { mesh.edge(between: $0, $1) })
                done.formUnion(lineEdges)
                let last = line[line.count - 1]
                let pa = mesh.mirrorPartner[Int(start)], pb = mesh.mirrorPartner[Int(last)]
                // Along the middle, a line is its own mirror image.
                if pa == start, pb == last, line.allSatisfy({ abs(plane.signedDistance(mesh.position($0))) <= centerTolerance }) { continue }
                var match: [VertexID]?
                if pa >= 0, pb >= 0 {
                    var smallest = reach
                    for candidate in mesh.edgesOf(pa) where !lineEdges.contains(candidate) {
                        let other = walk(from: pa, along: candidate)
                        guard other[other.count - 1] == pb, Set(other).isDisjoint(with: line.dropFirst().dropLast()) else { continue }
                        let d = deviation(line, other)
                        if d <= smallest {
                            smallest = d
                            match = other
                        }
                    }
                }
                for v in line.dropFirst().dropLast() where match == nil || mesh.mirrorPartner[Int(v)] >= 0 {
                    // Kept only if they turn out to be right.
                    if let match, match.contains(mesh.mirrorPartner[Int(v)]) { continue }
                    mesh.setMirrorPartner(v, invalidID)
                }
                guard var other = match else { continue }
                done.formUnion(zip(other, other.dropFirst()).compactMap { mesh.edge(between: $0, $1) })
                let inOrder = other.count == line.count && zip(line, other).allSatisfy { mesh.mirrorPartner[Int($0)] == $1 }
                if !inOrder {
                    for v in line.dropFirst().dropLast() { mesh.setMirrorPartner(v, invalidID) }
                    for v in other.dropFirst().dropLast() { mesh.setMirrorPartner(v, invalidID) }
                    while other.count < line.count {
                        var longest = 0
                        for i in 0..<(other.count - 1) where simd_length(mesh.position(other[i + 1]) - mesh.position(other[i])) > simd_length(mesh.position(other[longest + 1]) - mesh.position(other[longest])) { longest = i }
                        guard let e = mesh.edge(between: other[longest], other[longest + 1]),
                              let split = try? mesh.splitEdge(e, at: mesh.ends(e).0 == other[longest] ? 0.5 : 0.5) else { break }
                        mesh.setBend(split.vertex, true)
                        other.insert(split.vertex, at: longest + 1)
                    }
                    while other.count > line.count {
                        var shortest = 1
                        func span(_ i: Int) -> Float { simd_length(mesh.position(other[i + 1]) - mesh.position(other[i - 1])) }
                        for i in 1..<(other.count - 1) where span(i) < span(shortest) { shortest = i }
                        guard (try? mesh.dissolveVertex(other[shortest])) != nil else { break }
                        other.remove(at: shortest)
                    }
                    guard other.count == line.count else { continue }
                    for (a, b) in zip(line, other).dropFirst().dropLast() { pair(a, b, in: &mesh) }
                }
                // The straighter of the two is the one to keep: a wobble only adds length.
                func length(_ l: [VertexID]) -> Float { zip(l, l.dropFirst()).reduce(0) { $0 + simd_length(mesh.position($1.0) - mesh.position($1.1)) } }
                let otherLeads = length(other) < length(line)
                for (a, b) in zip(line, other).dropFirst().dropLast() {
                    let (from, to) = otherLeads ? (b, a) : (a, b)
                    mesh.setPosition(to, mirrored(from))
                    mesh.lineWeights[Int(to)] = mesh.lineWeights[Int(from)]
                }
            }
        }

        // Everything else has nothing opposite it, so goes across as it is.
        var plan = TopologyPlan()
        var nodes: [VertexID: Int32] = [:]
        func node(_ v: VertexID) -> Int32 {
            if let i = nodes[v] { return i }
            let i = Int32(plan.nodes.count)
            plan.nodes.append(.existing(v))
            if mesh.isBendVertex(v) { plan.bends.insert(i) }
            nodes[v] = i
            return i
        }
        for e in mesh.aliveEdges where mirrorEdge(of: e, in: mesh) == nil {
            let (a, b) = mesh.ends(e)
            plan.edges.append(SIMD2<Int32>(node(a), node(b)))
        }
        return plan
    }
}
