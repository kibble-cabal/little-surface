import Foundation
import simd

/// Component-level editing operations. Each one either completes or throws. Callers run them on a copy
/// (see `RetopoEngine.perform`), so a throw leaves the document's mesh exactly as it was.
public extension Mesh {
    // MARK: Delete

    /// Removes faces. With `keepEdges` false, edges and vertices that nothing else uses go with them.
    mutating func deleteFaces(_ faces: Set<FaceID>, keepEdges: Bool = false) {
        var touchedEdges = Set<EdgeID>()
        for f in faces where isFaceAlive(f) {
            touchedEdges.formUnion(edgeLoop(f))
            removeFace(f)
        }
        guard !keepEdges else { return }
        var touchedVerts = Set<VertexID>()
        for e in touchedEdges where isEdgeAlive(e) && isWire(e) {
            let (a, b) = ends(e)
            touchedVerts.insert(a)
            touchedVerts.insert(b)
            removeEdge(e)
        }
        removeIsolatedVertices(in: Array(touchedVerts))
    }

    /// Removes edges and the faces using them, plus vertices left with nothing.
    mutating func deleteEdges(_ edges: Set<EdgeID>) {
        var touchedVerts = Set<VertexID>()
        for e in edges where isEdgeAlive(e) {
            let (a, b) = ends(e)
            touchedVerts.insert(a)
            touchedVerts.insert(b)
            removeEdge(e)
        }
        removeIsolatedVertices(in: Array(touchedVerts))
    }

    /// Removes vertices with everything attached, plus neighbours left with nothing.
    mutating func deleteVertices(_ vertices: Set<VertexID>) {
        var neighbours = Set<VertexID>()
        for v in vertices where isVertexAlive(v) {
            neighbours.formUnion(self.neighbors(of: v))
            removeVertex(v)
        }
        removeIsolatedVertices(in: Array(neighbours))
    }

    // MARK: Dissolve

    /// The outline of a connected group of faces as one directed loop, or nil if they don't make one.
    func mergedLoop(of faces: [FaceID]) -> [VertexID]? {
        var next = [VertexID: VertexID]()
        var directed = Set<UInt64>()
        func key(_ a: VertexID, _ b: VertexID) -> UInt64 { (UInt64(UInt32(a)) << 32) | UInt64(UInt32(b)) }
        for f in faces {
            let l = loop(f)
            for i in 0..<l.count { directed.insert(key(l[i], l[(i + 1) % l.count])) }
        }
        for f in faces {
            let l = loop(f)
            for i in 0..<l.count {
                let a = l[i], b = l[(i + 1) % l.count]
                if directed.contains(key(b, a)) { continue }
                if next[a] != nil { return nil }
                next[a] = b
            }
        }
        guard let start = next.keys.min() else { return nil }
        var out = [start]
        var current = next[start]!
        while current != start {
            guard out.count <= next.count else { return nil }
            out.append(current)
            guard let n = next[current] else { return nil }
            current = n
        }
        return out.count == next.count && out.count >= 3 ? out : nil
    }

    /// Removes an edge and merges the two faces it separated. A wire edge just goes.
    mutating func dissolveEdge(_ e: EdgeID) throws {
        guard isEdgeAlive(e) else { throw MeshError.staleElement }
        let faces = facesOf(edge: e)
        if faces.isEmpty {
            let (a, b) = ends(e)
            removeEdge(e)
            removeIsolatedVertices(in: [a, b])
            return
        }
        guard faces.count == 2 else {
            throw MeshError.invalid("A boundary edge has a face on one side only, so there's nothing to merge it with. Delete the edge if you want the face gone.")
        }
        guard let merged = mergedLoop(of: faces) else {
            throw MeshError.invalid("These two faces meet along more than one stretch, so merging them wouldn't make a single face.")
        }
        for f in faces { removeFace(f) }
        let (a, b) = ends(e)
        removeEdge(e)
        removeIsolatedVertices(in: [a, b])
        try addFace(merged, autoOrient: false)
    }

    /// Removes a vertex and keeps the shape around it: a valence-2 vertex is replaced by one edge, and
    /// an interior vertex's surrounding faces merge into one.
    mutating func dissolveVertex(_ v: VertexID) throws {
        guard isVertexAlive(v) else { throw MeshError.staleElement }
        let edges = edgesOf(v)
        if edges.isEmpty {
            removeVertex(v)
            return
        }
        if edges.count == 1 {
            let other = otherEnd(edges[0], from: v)
            guard isWire(edges[0]) else { throw MeshError.invalid("This vertex is part of a face and can't be dissolved.") }
            removeVertex(v)
            removeIsolatedVertices(in: [other])
            return
        }
        if edges.count == 2 {
            let a = otherEnd(edges[0], from: v), b = otherEnd(edges[1], from: v)
            let faces = facesOf(vertex: v)
            for f in faces where loop(f).count <= 3 {
                throw MeshError.invalid("Dissolving this vertex would flatten a triangle to a line. Delete the triangle first.")
            }
            let newLoops = faces.map { f in loop(f).filter { $0 != v } }
            if edge(between: a, b) != nil && !faces.isEmpty {
                throw MeshError.invalid("The two neighbouring vertices are already connected, so dissolving this one would overlap that edge.")
            }
            for f in faces { removeFace(f) }
            removeVertex(v)
            try ensureEdge(a, b)
            for l in newLoops { try addFace(l, autoOrient: false) }
            return
        }
        let faces = facesOf(vertex: v)
        guard faces.count >= 2, edges.allSatisfy({ !isWire($0) }) else {
            throw MeshError.invalid("This vertex has loose edges attached, so there's no single face to merge into. Delete those edges first.")
        }
        guard let merged = mergedLoop(of: faces), !merged.contains(v) else {
            throw MeshError.invalid("The faces around this vertex don't merge into a single face.")
        }
        for f in faces { removeFace(f) }
        removeVertex(v)
        try addFace(merged, autoOrient: false)
    }

    // MARK: Connect

    /// Adds an edge between two vertices. If a face contains both, it's cut in two.
    @discardableResult
    mutating func connectVertices(_ a: VertexID, _ b: VertexID) throws -> EdgeID {
        guard isVertexAlive(a), isVertexAlive(b) else { throw MeshError.staleElement }
        guard a != b else { throw MeshError.degenerateEdge }
        if edge(between: a, b) != nil { throw MeshError.invalid("Those vertices are already connected.") }

        let shared = facesOf(vertex: a).filter { facesOf(vertex: b).contains($0) }
        if let f = shared.first {
            let l = loop(f)
            guard let i = l.firstIndex(of: a), let j = l.firstIndex(of: b) else { throw MeshError.staleElement }
            let lo = min(i, j), hi = max(i, j)
            let first = Array(l[lo...hi])
            let second = Array(l[hi...]) + Array(l[...lo])
            removeFace(f)
            try addFace(first, autoOrient: false)
            try addFace(second, autoOrient: false)
            guard let e = edge(between: a, b) else { throw MeshError.staleElement }
            return e
        }
        return try ensureEdge(a, b)
    }

    // MARK: Weld

    /// Merges `from` into `into`. Faces that collapse are dropped. Throws, leaving the caller's copy to
    /// be discarded, if the merge would give an edge a third face or pinch a face.
    mutating func mergeVertex(_ from: VertexID, into: VertexID) throws {
        guard isVertexAlive(from), isVertexAlive(into) else { throw MeshError.staleElement }
        guard from != into else { return }

        var rebuilt: [[VertexID]] = []
        for f in facesOf(vertex: from) {
            var l = loop(f).map { $0 == from ? into : $0 }
            // The two vertices may be neighbours in this face, in which case one corner just vanishes.
            var i = 0
            while i < l.count {
                if l[i] == l[(i + 1) % l.count] { l.remove(at: i) } else { i += 1 }
            }
            removeFace(f)
            guard l.count >= 3 else { continue }
            guard Set(l).count == l.count else {
                throw MeshError.invalid("Welding here would pinch a face into two parts, so nothing was merged.")
            }
            rebuilt.append(l)
        }
        var wires: [VertexID] = []
        for e in edgesOf(from) {
            let other = otherEnd(e, from: from)
            if other != into { wires.append(other) }
        }
        let partner = mirrorPartner[Int(from)]
        removeVertex(from)
        for w in wires { try ensureEdge(into, w) }
        for l in rebuilt {
            if findFace(withVertices: l) != nil { continue }
            do {
                try addFace(l)
            } catch MeshError.nonManifoldEdge {
                throw MeshError.invalid("Welding these would give an edge three faces, which isn't valid for export, so nothing was merged.")
            }
        }
        if partner == into || partner == from { setMirrorPartner(into, into) }
    }

    /// Welds a set into one vertex at their average position, or at `position` if given.
    @discardableResult
    mutating func weld(_ vertices: Set<VertexID>, position: Vec3? = nil) throws -> VertexID {
        let ordered = vertices.sorted().filter(isVertexAlive)
        guard ordered.count >= 2, let keep = ordered.first else {
            throw MeshError.invalid("Select at least two vertices to weld.")
        }
        var center = Vec3(repeating: 0)
        for v in ordered { center += self.position(v) }
        center /= Float(ordered.count)
        for v in ordered.dropFirst() { try mergeVertex(v, into: keep) }
        setPosition(keep, position ?? center)
        return keep
    }

    /// Merges all vertices closer than `threshold`. Returns how many were merged away.
    @discardableResult
    mutating func weldByDistance(_ threshold: Float, among candidates: Set<VertexID>? = nil) throws -> Int {
        let list = (candidates.map { Array($0) } ?? aliveVertices).filter(isVertexAlive).sorted()
        guard threshold > 0, list.count > 1 else { return 0 }
        func key(_ p: Vec3) -> SIMD3<Int32> {
            let q = p / threshold
            return SIMD3<Int32>(Int32(q.x.rounded(.down)), Int32(q.y.rounded(.down)), Int32(q.z.rounded(.down)))
        }
        var grid = [SIMD3<Int32>: [VertexID]]()
        var merged = 0
        for v in list {
            guard isVertexAlive(v) else { continue }
            let p = position(v)
            let k = key(p)
            var target = invalidID
            var best = threshold
            for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        for c in grid[k &+ SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))] ?? [] where isVertexAlive(c) {
                            let d = simd_length(position(c) - p)
                            if d <= best {
                                best = d
                                target = c
                            }
                        }
                    }
                }
            }
            if target >= 0 {
                try mergeVertex(v, into: target)
                merged += 1
            } else {
                grid[k, default: []].append(v)
            }
        }
        return merged
    }

    // MARK: Flip

    /// Rotates an edge shared by two faces to the next diagonal of their combined outline. Works on two
    /// triangles (the classic flip) and two quads.
    mutating func flipEdge(_ e: EdgeID) throws {
        guard isEdgeAlive(e) else { throw MeshError.staleElement }
        let faces = facesOf(edge: e)
        guard faces.count == 2 else { throw MeshError.invalid("Only an edge between two faces can be flipped.") }
        let (a, b) = ends(e)
        guard let outline = mergedLoop(of: faces) else {
            throw MeshError.invalid("These two faces share more than one edge, so this edge can't be flipped.")
        }
        guard let i = outline.firstIndex(of: a), let j = outline.firstIndex(of: b) else {
            throw MeshError.invalid("This edge can't be flipped here.")
        }
        let n = outline.count
        let p = (i + 1) % n, q = (j + 1) % n
        if edge(between: outline[p], outline[q]) != nil {
            throw MeshError.invalid("The flipped edge would duplicate an edge that already exists.")
        }
        let lo = min(p, q), hi = max(p, q)
        let first = Array(outline[lo...hi])
        let second = Array(outline[hi...]) + Array(outline[...lo])
        guard first.count >= 3, second.count >= 3 else {
            throw MeshError.invalid("This edge can't be flipped here.")
        }
        for f in faces { removeFace(f) }
        removeEdge(e)
        try addFace(first, autoOrient: false)
        try addFace(second, autoOrient: false)
    }

    // MARK: Extrude

    /// Extrudes wire or boundary edges sideways. New vertices sit `distance` away, along the surface
    /// direction facing away from the existing face, and each original edge gets one new quad.
    /// Returns the new outer edges, ready to select and drag.
    @discardableResult
    mutating func extrudeEdges(_ edges: Set<EdgeID>, distance: Float, projector: SurfaceProjector?) throws -> Set<EdgeID> {
        let live = edges.filter { isEdgeAlive($0) }.sorted()
        guard !live.isEmpty else { throw MeshError.invalid("Select some edges to extrude.") }
        for e in live where faceCountOf(edge: e) >= 2 {
            throw MeshError.invalid("Only boundary or loose edges can be extruded. An interior edge already has a face on both sides.")
        }

        // Wire edges have no inside to tell them apart and store their ends in arbitrary order,
        // so walk each connected run to give every edge the same direction of travel.
        let liveSet = Set(live)
        var travel = [EdgeID: (VertexID, VertexID)]()
        for start in live where travel[start] == nil && isWire(start) {
            travel[start] = ends(start)
            var stack = [start]
            while let e = stack.popLast() {
                let (a, b) = travel[e]!
                for n in edgesOf(a) where liveSet.contains(n) && travel[n] == nil && isWire(n) {
                    travel[n] = (otherEnd(n, from: a), a)
                    stack.append(n)
                }
                for n in edgesOf(b) where liveSet.contains(n) && travel[n] == nil && isWire(n) {
                    travel[n] = (b, otherEnd(n, from: b))
                    stack.append(n)
                }
            }
        }

        // Average outward direction per vertex across the edges using it.
        var directions = [VertexID: Vec3]()
        var normals = [VertexID: Vec3]()
        for e in live {
            let (a, b) = travel[e] ?? ends(e)
            let pa = position(a), pb = position(b)
            let tangent = GeometryMath.safeNormalize(pb - pa)
            var normal = Vec3(repeating: 0)
            if let f = facesOf(edge: e).first {
                normal = faceNormal(f)
            } else if let projector, let hit = projector.closest(to: edgeMidpoint(e)) {
                normal = hit.normal
            } else {
                normal = GeometryMath.perpendicular(to: tangent)
            }
            var side = GeometryMath.safeNormalize(simd_cross(tangent, normal), fallback: GeometryMath.perpendicular(to: tangent))
            if let f = facesOf(edge: e).first, simd_dot(side, faceCenter(f) - edgeMidpoint(e)) > 0 {
                side = -side
            }
            directions[a, default: Vec3(repeating: 0)] += side
            directions[b, default: Vec3(repeating: 0)] += side
            normals[a] = normal
            normals[b] = normal
        }
        var copies = [VertexID: VertexID]()
        for (v, direction) in directions.sorted(by: { $0.key < $1.key }) {
            let raw = position(v) + GeometryMath.safeNormalize(direction, fallback: Vec3(0, 1, 0)) * distance
            var p = raw
            if let projector, let projected = projector.project(raw, normalHint: normals[v], maxDistance: max(distance * 3, 1e-4)) {
                p = projected.position
            }
            copies[v] = addVertex(p)
        }
        var out = Set<EdgeID>()
        for e in live {
            let (a, b) = ends(e)
            guard let ca = copies[a], let cb = copies[b] else { continue }
            var quad = [a, b, cb, ca]
            if let f = facesOf(edge: e).first {
                // The new quad runs the shared edge opposite to the existing face.
                if faceTraverses(f, from: a, to: b) { quad = [b, a, ca, cb] }
                try addFace(quad, autoOrient: false)
            } else {
                try addFace(quad)
                if let projector, let hit = projector.closest(to: edgeMidpoint(e)), let f = edge(between: a, b).flatMap({ facesOf(edge: $0).first }), simd_dot(faceNormal(f), hit.normal) < 0 {
                    reverseFaces([f])
                }
            }
            if let top = edge(between: ca, cb) { out.insert(top) }
        }
        return out
    }

    // MARK: Fill

    /// Fills a closed boundary or wire loop with one face, wound to match its neighbours.
    @discardableResult
    mutating func fill(loop chain: BoundaryChain, surfaceNormal: Vec3? = nil) throws -> FaceID {
        guard chain.isClosed else { throw MeshError.invalid("Only a closed loop of edges can be filled. This one has a gap.") }
        guard chain.vertices.count >= 3 else { throw MeshError.tooFewVertices }
        var loop = chain.vertices
        // A neighbour settles the winding; otherwise follow the surface normal.
        var hasNeighbour = false
        for (i, e) in chain.edges.enumerated() {
            guard let f = facesOf(edge: e).first else { continue }
            hasNeighbour = true
            let a = chain.vertices[i], b = chain.vertices[(i + 1) % chain.vertices.count]
            if faceTraverses(f, from: a, to: b) { loop.reverse() }
            break
        }
        if !hasNeighbour, let surfaceNormal {
            let n = GeometryMath.newellNormal(loop.map { position($0) })
            if simd_dot(n, surfaceNormal) < 0 { loop.reverse() }
        }
        return try addFace(loop)
    }

    // MARK: Subdivide

    /// Splits each edge into `cuts + 1` equal parts. Returns the new vertices, which the caller may
    /// project. Adjacent faces keep their IDs and gain corners.
    @discardableResult
    mutating func subdivideEdges(_ edges: Set<EdgeID>, cuts: Int = 1) throws -> [VertexID] {
        var created: [VertexID] = []
        for e in edges.sorted() where isEdgeAlive(e) {
            guard cuts >= 1 else { continue }
            for k in stride(from: cuts, to: 0, by: -1) {
                created.append(try splitEdge(e, at: Float(k) / Float(k + 1)).vertex)
            }
        }
        return created
    }

    /// Cuts each face into quads meeting at its center: a quad becomes four, a triangle three.
    /// Faces next to the selection gain midpoints on the shared edges. Returns the new vertices and
    /// the IDs of the new faces.
    @discardableResult
    mutating func subdivideFaces(_ faces: Set<FaceID>) throws -> (vertices: [VertexID], faces: [FaceID]) {
        let targets = faces.filter { isFaceAlive($0) }.sorted()
        guard !targets.isEmpty else { throw MeshError.invalid("Select some faces to subdivide.") }

        var midpoint = [EdgeID: VertexID]()
        var created: [VertexID] = []
        var outlines = [(loop: [VertexID], midpoints: [VertexID])]()
        for f in targets {
            let edges = edgeLoop(f)
            for e in edges where midpoint[e] == nil {
                midpoint[e] = invalidID
            }
            outlines.append((loop(f), []))
        }
        // Remember each edge by its ends, since splitting changes edge IDs along the way.
        var midpointByEnds = [UInt64: VertexID]()
        func key(_ a: VertexID, _ b: VertexID) -> UInt64 {
            (UInt64(UInt32(min(a, b))) << 32) | UInt64(UInt32(max(a, b)))
        }
        for e in midpoint.keys.sorted() {
            let (a, b) = ends(e)
            let v = try splitEdge(e, at: 0.5).vertex
            midpointByEnds[key(a, b)] = v
            created.append(v)
        }
        var newFaces: [FaceID] = []
        for (index, f) in targets.enumerated() {
            let outline = outlines[index].loop
            var center = Vec3(repeating: 0)
            for v in outline { center += position(v) }
            center /= Float(outline.count)
            removeFace(f)
            let c = addVertex(center)
            created.append(c)
            let n = outline.count
            for i in 0..<n {
                let prev = outline[(i + n - 1) % n], here = outline[i], next = outline[(i + 1) % n]
                guard let m0 = midpointByEnds[key(prev, here)], let m1 = midpointByEnds[key(here, next)] else {
                    throw MeshError.staleElement
                }
                newFaces.append(try addFace([c, m0, here, m1], autoOrient: false))
            }
        }
        return (created, newFaces)
    }

    // MARK: Normals

    mutating func reverseFaces(_ faces: Set<FaceID>) {
        for f in faces where isFaceAlive(f) {
            // Keep corner i's edge pointing from corner i to corner i+1 after the flip.
            var loop = faceLoops[Int(f)]
            var edges = faceEdgeLoops[Int(f)]
            loop.reverse()
            edges.reverse()
            let last = edges.removeFirst()
            edges.append(last)
            faceLoops[Int(f)] = loop
            faceEdgeLoops[Int(f)] = edges
        }
        topologyVersion &+= 1
    }

    /// Makes winding consistent within each connected component, then points each component outward:
    /// using signed volume when it's closed, otherwise by agreeing with the source surface normal.
    /// Returns the number of faces flipped.
    @discardableResult
    mutating func recalculateNormals(projector: SurfaceProjector? = nil) -> Int {
        var visited = Set<FaceID>()
        var flipped = 0
        for seed in aliveFaces where !visited.contains(seed) {
            var component: [FaceID] = []
            var flips = Set<FaceID>()
            var stack = [seed]
            visited.insert(seed)
            var isFlipped = [seed: false]
            while let f = stack.popLast() {
                component.append(f)
                let l = loop(f)
                let thisFlipped = isFlipped[f]!
                for (i, e) in edgeLoop(f).enumerated() {
                    guard let g = oppositeFace(across: e, from: f), !visited.contains(g) else { continue }
                    let a = l[i], b = l[(i + 1) % l.count]
                    let sameDirection = faceTraverses(g, from: a, to: b)
                    // Consistent neighbours run a shared edge in opposite directions.
                    let needs = sameDirection != thisFlipped
                    isFlipped[g] = needs
                    if needs { flips.insert(g) }
                    visited.insert(g)
                    stack.append(g)
                }
            }
            if thisFlippedHasOuterMajority(component, flips: flips, projector: projector) {
                flips = Set(component).subtracting(flips)
            }
            reverseFaces(flips)
            flipped += flips.count
        }
        return flipped
    }

    /// True when, after applying `flips`, the component would point inward.
    private func thisFlippedHasOuterMajority(_ component: [FaceID], flips: Set<FaceID>, projector: SurfaceProjector?) -> Bool {
        let isClosed = component.allSatisfy { f in edgeLoop(f).allSatisfy { faceCountOf(edge: $0) == 2 } }
        if isClosed {
            var volume: Float = 0
            for f in component {
                var l = loop(f)
                if flips.contains(f) { l.reverse() }
                let p0 = position(l[0])
                for i in 1..<(l.count - 1) {
                    volume += simd_dot(p0, simd_cross(position(l[i]), position(l[i + 1])))
                }
            }
            return volume < 0
        }
        guard let projector, !projector.isEmpty else { return false }
        var vote: Float = 0
        for f in component {
            guard let hit = projector.closest(to: faceCenter(f)) else { continue }
            var n = GeometryMath.newellNormal(facePositions(f))
            if flips.contains(f) { n = -n }
            vote += simd_dot(n, hit.normal)
        }
        return vote < 0
    }

    // MARK: Relax

    /// Evens out spacing: each vertex moves toward the average of its neighbours, then returns to the
    /// surface. Boundary vertices slide only along their boundary, unless `pinBoundary` holds them still.
    mutating func relax(vertices: Set<VertexID>, iterations: Int = 1, strength: Float = 0.5, pinBoundary: Bool = true, projector: SurfaceProjector?, snap: Bool = true) {
        let targets = vertices.filter(isVertexAlive).sorted()
        guard !targets.isEmpty else { return }
        for _ in 0..<max(iterations, 1) {
            var updates: [(VertexID, Vec3)] = []
            updates.reserveCapacity(targets.count)
            for v in targets {
                let boundary = isBoundaryVertex(v)
                if boundary && pinBoundary { continue }
                var sum = Vec3(repeating: 0)
                var count: Float = 0
                for e in edgesOf(v) {
                    if boundary && faceCountOf(edge: e) == 2 { continue }
                    sum += position(otherEnd(e, from: v))
                    count += 1
                }
                guard count > 0 else { continue }
                let p = position(v)
                let moved = p + (sum / count - p) * strength
                updates.append((v, reprojected(moved, near: v, projector: snap ? projector : nil)))
            }
            setPositions(updates)
        }
    }

    /// `p` moved back to the surface, on the side `v` is on.
    func reprojected(_ p: Vec3, near v: VertexID, projector: SurfaceProjector?) -> Vec3 {
        guard let projector, !projector.isEmpty else { return p }
        var hint = vertexNormal(v)
        if simd_length_squared(hint) == 0, let hit = projector.closest(to: position(v)) { hint = hit.normal }
        return projector.project(p, normalHint: simd_length_squared(hint) > 0 ? hint : nil)?.position ?? p
    }
}
