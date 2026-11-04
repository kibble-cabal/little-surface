import Foundation
import simd

public typealias VertexID = Int32
public typealias EdgeID = Int32
public typealias FaceID = Int32

public let invalidID: Int32 = -1

/// The editable retopology mesh.
///
/// This is an edge-and-face incidence structure in the style of Blender's BMesh rather than a strict
/// half-edge mesh, because retopology starts from wire edges and open polylines, which a half-edge
/// structure can only represent with awkward boundary-link bookkeeping. Each face loop's corners act
/// as its half-edges: `faceLoops[f][i] -> faceLoops[f][i + 1]` runs along `faceEdgeLoops[f][i]`.
///
/// IDs are stable slots with free lists. Every edge has at most two faces, which is enforced here,
/// so no editing operation can build a non-manifold edge.
///
/// It is a value type: storing a copy is a cheap copy-on-write snapshot, which is what undo and
/// all-or-nothing editing transactions are built on.
public struct Mesh {
    public internal(set) var positions: [Vec3] = []
    public internal(set) var vertexAlive: [Bool] = []
    public internal(set) var vertexEdges: [[EdgeID]] = []
    /// Symmetry partner of each vertex: -1 when unpaired, itself when on the centerline.
    public internal(set) var mirrorPartner: [VertexID] = []

    public internal(set) var edgeEnds: [SIMD2<Int32>] = []
    /// Up to two incident faces, -1 for an empty side. A wire edge has none.
    public internal(set) var edgeFaces: [SIMD2<Int32>] = []
    public internal(set) var edgeAlive: [Bool] = []

    public internal(set) var faceLoops: [[VertexID]] = []
    public internal(set) var faceEdgeLoops: [[EdgeID]] = []
    public internal(set) var faceAlive: [Bool] = []

    var freeVertices: [VertexID] = []
    var freeEdges: [EdgeID] = []
    var freeFaces: [FaceID] = []

    public internal(set) var vertexCount = 0
    public internal(set) var edgeCount = 0
    public internal(set) var faceCount = 0

    /// Bumped on any position change. Renderers compare these rather than re-uploading every frame.
    public internal(set) var positionVersion: UInt64 = 0
    /// Bumped on any connectivity change.
    public internal(set) var topologyVersion: UInt64 = 0

    public init() {}

    // MARK: Iteration

    public var aliveVertices: [VertexID] {
        var out: [VertexID] = []
        out.reserveCapacity(vertexCount)
        for i in 0..<positions.count where vertexAlive[i] { out.append(VertexID(i)) }
        return out
    }

    public var aliveEdges: [EdgeID] {
        var out: [EdgeID] = []
        out.reserveCapacity(edgeCount)
        for i in 0..<edgeEnds.count where edgeAlive[i] { out.append(EdgeID(i)) }
        return out
    }

    public var aliveFaces: [FaceID] {
        var out: [FaceID] = []
        out.reserveCapacity(faceCount)
        for i in 0..<faceLoops.count where faceAlive[i] { out.append(FaceID(i)) }
        return out
    }

    public func isVertexAlive(_ v: VertexID) -> Bool {
        v >= 0 && Int(v) < vertexAlive.count && vertexAlive[Int(v)]
    }

    public func isEdgeAlive(_ e: EdgeID) -> Bool {
        e >= 0 && Int(e) < edgeAlive.count && edgeAlive[Int(e)]
    }

    public func isFaceAlive(_ f: FaceID) -> Bool {
        f >= 0 && Int(f) < faceAlive.count && faceAlive[Int(f)]
    }

    // MARK: Element access

    public func position(_ v: VertexID) -> Vec3 { positions[Int(v)] }

    public mutating func setPosition(_ v: VertexID, _ p: Vec3) {
        positions[Int(v)] = p
        positionVersion &+= 1
    }

    /// Batch form: bumps the version once.
    public mutating func setPositions(_ updates: [(VertexID, Vec3)]) {
        guard !updates.isEmpty else { return }
        positions.withUnsafeMutableBufferPointer { buffer in
            for (v, p) in updates { buffer[Int(v)] = p }
        }
        positionVersion &+= 1
    }

    public func edgesOf(_ v: VertexID) -> [EdgeID] { vertexEdges[Int(v)] }

    public func ends(_ e: EdgeID) -> (VertexID, VertexID) {
        let pair = edgeEnds[Int(e)]
        return (pair.x, pair.y)
    }

    public func otherEnd(_ e: EdgeID, from v: VertexID) -> VertexID {
        let pair = edgeEnds[Int(e)]
        return pair.x == v ? pair.y : pair.x
    }

    public func edge(between a: VertexID, _ b: VertexID) -> EdgeID? {
        guard isVertexAlive(a), isVertexAlive(b) else { return nil }
        // Scan the smaller list: retopology valence is small, but a junction can be busy.
        let lhs = vertexEdges[Int(a)], rhs = vertexEdges[Int(b)]
        let list = lhs.count <= rhs.count ? lhs : rhs
        for e in list {
            let pair = edgeEnds[Int(e)]
            if (pair.x == a && pair.y == b) || (pair.x == b && pair.y == a) { return e }
        }
        return nil
    }

    public func facesOf(edge e: EdgeID) -> [FaceID] {
        let pair = edgeFaces[Int(e)]
        var out: [FaceID] = []
        if pair.x >= 0 { out.append(pair.x) }
        if pair.y >= 0 { out.append(pair.y) }
        return out
    }

    public func faceCountOf(edge e: EdgeID) -> Int {
        let pair = edgeFaces[Int(e)]
        return (pair.x >= 0 ? 1 : 0) + (pair.y >= 0 ? 1 : 0)
    }

    public func isWire(_ e: EdgeID) -> Bool { faceCountOf(edge: e) == 0 }
    public func isBoundary(_ e: EdgeID) -> Bool { faceCountOf(edge: e) == 1 }

    /// Each face at most once, in first-seen order.
    public func facesOf(vertex v: VertexID) -> [FaceID] {
        var out: [FaceID] = []
        for e in vertexEdges[Int(v)] {
            let pair = edgeFaces[Int(e)]
            if pair.x >= 0 && !out.contains(pair.x) { out.append(pair.x) }
            if pair.y >= 0 && !out.contains(pair.y) { out.append(pair.y) }
        }
        return out
    }

    public func neighbors(of v: VertexID) -> [VertexID] {
        vertexEdges[Int(v)].map { otherEnd($0, from: v) }
    }

    public func isBoundaryVertex(_ v: VertexID) -> Bool {
        vertexEdges[Int(v)].contains { faceCountOf(edge: $0) < 2 }
    }

    public func loop(_ f: FaceID) -> [VertexID] { faceLoops[Int(f)] }
    public func edgeLoop(_ f: FaceID) -> [EdgeID] { faceEdgeLoops[Int(f)] }

    public func facePositions(_ f: FaceID) -> [Vec3] {
        faceLoops[Int(f)].map { positions[Int($0)] }
    }

    public func faceNormal(_ f: FaceID) -> Vec3 {
        GeometryMath.safeNormalize(GeometryMath.newellNormal(facePositions(f)))
    }

    public func faceCenter(_ f: FaceID) -> Vec3 {
        let loop = faceLoops[Int(f)]
        var sum = Vec3(repeating: 0)
        for v in loop { sum += positions[Int(v)] }
        return sum / Float(loop.count)
    }

    public func faceArea(_ f: FaceID) -> Float {
        simd_length(GeometryMath.newellNormal(facePositions(f))) * 0.5
    }

    /// Area-weighted average of the adjacent face normals. Zero for a vertex with only wire edges.
    public func vertexNormal(_ v: VertexID) -> Vec3 {
        var sum = Vec3(repeating: 0)
        for f in facesOf(vertex: v) { sum += GeometryMath.newellNormal(facePositions(f)) }
        return simd_length(sum) > 1e-12 ? simd_normalize(sum) : Vec3(repeating: 0)
    }

    public func edgeLength(_ e: EdgeID) -> Float {
        let (a, b) = ends(e)
        return simd_length(positions[Int(a)] - positions[Int(b)])
    }

    public func edgeMidpoint(_ e: EdgeID) -> Vec3 {
        let (a, b) = ends(e)
        return (positions[Int(a)] + positions[Int(b)]) * 0.5
    }

    public func corner(of v: VertexID, in f: FaceID) -> Int? {
        faceLoops[Int(f)].firstIndex(of: v)
    }

    /// The face on the other side of `e`, if there is one.
    public func oppositeFace(across e: EdgeID, from f: FaceID) -> FaceID? {
        let pair = edgeFaces[Int(e)]
        if pair.x == f { return pair.y >= 0 ? pair.y : nil }
        if pair.y == f { return pair.x >= 0 ? pair.x : nil }
        return nil
    }

    /// The two edges of face `f` that touch `v`.
    public func edgesOfFace(_ f: FaceID, at v: VertexID) -> (EdgeID, EdgeID)? {
        let loop = faceLoops[Int(f)]
        guard let i = loop.firstIndex(of: v) else { return nil }
        let edges = faceEdgeLoops[Int(f)]
        return (edges[i], edges[(i + loop.count - 1) % loop.count])
    }

    public var bounds: AABB {
        var box = AABB.empty
        for i in 0..<positions.count where vertexAlive[i] { box.grow(positions[i]) }
        return box
    }

    public var isEmpty: Bool { vertexCount == 0 }

    public var averageEdgeLength: Float {
        var sum: Float = 0
        var n = 0
        for i in 0..<edgeEnds.count where edgeAlive[i] {
            sum += edgeLength(EdgeID(i))
            n += 1
        }
        return n > 0 ? sum / Float(n) : 0
    }

    // MARK: Construction

    @discardableResult
    public mutating func addVertex(_ p: Vec3) -> VertexID {
        let id: VertexID
        if let slot = freeVertices.popLast() {
            id = slot
            positions[Int(id)] = p
            vertexAlive[Int(id)] = true
            vertexEdges[Int(id)] = []
            mirrorPartner[Int(id)] = invalidID
        } else {
            id = VertexID(positions.count)
            positions.append(p)
            vertexAlive.append(true)
            vertexEdges.append([])
            mirrorPartner.append(invalidID)
        }
        vertexCount += 1
        positionVersion &+= 1
        topologyVersion &+= 1
        return id
    }

    /// Returns the existing edge between the two vertices when there is one.
    @discardableResult
    public mutating func ensureEdge(_ a: VertexID, _ b: VertexID) throws -> EdgeID {
        guard a != b else { throw MeshError.degenerateEdge }
        guard isVertexAlive(a), isVertexAlive(b) else { throw MeshError.staleElement }
        if let e = edge(between: a, b) { return e }
        let id: EdgeID
        let pair = SIMD2<Int32>(a, b)
        let none = SIMD2<Int32>(invalidID, invalidID)
        if let slot = freeEdges.popLast() {
            id = slot
            edgeEnds[Int(id)] = pair
            edgeFaces[Int(id)] = none
            edgeAlive[Int(id)] = true
        } else {
            id = EdgeID(edgeEnds.count)
            edgeEnds.append(pair)
            edgeFaces.append(none)
            edgeAlive.append(true)
        }
        vertexEdges[Int(a)].append(id)
        vertexEdges[Int(b)].append(id)
        edgeCount += 1
        topologyVersion &+= 1
        return id
    }

    /// True when a face using this loop's edges can be added without giving any edge a third face.
    public func canAddFace(_ loop: [VertexID]) -> Bool {
        let n = loop.count
        guard n >= 3, Set(loop).count == n, loop.allSatisfy(isVertexAlive) else { return false }
        for i in 0..<n {
            if let e = edge(between: loop[i], loop[(i + 1) % n]), faceCountOf(edge: e) >= 2 { return false }
        }
        return true
    }

    /// Adds a face. By default the loop is flipped when that is what it takes for the new face to
    /// wind consistently with its neighbours; with `autoOrient` off the winding is used as given.
    @discardableResult
    public mutating func addFace(_ inputLoop: [VertexID], autoOrient: Bool = true) throws -> FaceID {
        var loop = inputLoop
        let n = loop.count
        guard n >= 3 else { throw MeshError.tooFewVertices }
        guard Set(loop).count == n else { throw MeshError.repeatedVertex }
        guard loop.allSatisfy(isVertexAlive) else { throw MeshError.staleElement }
        if findFace(withVertices: loop) != nil { throw MeshError.duplicateFace }

        var sameDirection = 0, oppositeDirection = 0
        for i in 0..<n {
            let a = loop[i], b = loop[(i + 1) % n]
            guard let e = edge(between: a, b) else { continue }
            let pair = edgeFaces[Int(e)]
            if pair.x >= 0 && pair.y >= 0 { throw MeshError.nonManifoldEdge }
            let neighbor = pair.x >= 0 ? pair.x : pair.y
            guard neighbor >= 0 else { continue }
            if faceTraverses(neighbor, from: a, to: b) { sameDirection += 1 } else { oppositeDirection += 1 }
        }
        if autoOrient && sameDirection > 0 {
            guard oppositeDirection == 0 else { throw MeshError.inconsistentWinding }
            loop.reverse()
        }

        var edges = [EdgeID]()
        edges.reserveCapacity(n)
        for i in 0..<n { edges.append(try ensureEdge(loop[i], loop[(i + 1) % n])) }

        let id: FaceID
        if let slot = freeFaces.popLast() {
            id = slot
            faceLoops[Int(id)] = loop
            faceEdgeLoops[Int(id)] = edges
            faceAlive[Int(id)] = true
        } else {
            id = FaceID(faceLoops.count)
            faceLoops.append(loop)
            faceEdgeLoops.append(edges)
            faceAlive.append(true)
        }
        for e in edges {
            if edgeFaces[Int(e)].x < 0 { edgeFaces[Int(e)].x = id } else { edgeFaces[Int(e)].y = id }
        }
        faceCount += 1
        topologyVersion &+= 1
        return id
    }

    /// True when `f` runs from a straight to b.
    public func faceTraverses(_ f: FaceID, from a: VertexID, to b: VertexID) -> Bool {
        let loop = faceLoops[Int(f)]
        guard let i = loop.firstIndex(of: a) else { return false }
        return loop[(i + 1) % loop.count] == b
    }

    public func findFace(withVertices loop: [VertexID]) -> FaceID? {
        guard let first = loop.first, isVertexAlive(first) else { return nil }
        let target = Set(loop)
        for f in facesOf(vertex: first) where faceLoops[Int(f)].count == loop.count {
            if Set(faceLoops[Int(f)]) == target { return f }
        }
        return nil
    }

    // MARK: Removal

    /// Removes the face and leaves its edges and vertices in place.
    public mutating func removeFace(_ f: FaceID) {
        guard isFaceAlive(f) else { return }
        for e in faceEdgeLoops[Int(f)] {
            if edgeFaces[Int(e)].x == f {
                edgeFaces[Int(e)].x = edgeFaces[Int(e)].y
                edgeFaces[Int(e)].y = invalidID
            } else if edgeFaces[Int(e)].y == f {
                edgeFaces[Int(e)].y = invalidID
            }
        }
        faceAlive[Int(f)] = false
        faceLoops[Int(f)] = []
        faceEdgeLoops[Int(f)] = []
        freeFaces.append(f)
        faceCount -= 1
        topologyVersion &+= 1
    }

    /// Removes the edge and the faces that use it. The end vertices stay.
    public mutating func removeEdge(_ e: EdgeID) {
        guard isEdgeAlive(e) else { return }
        for f in facesOf(edge: e) { removeFace(f) }
        let (a, b) = ends(e)
        vertexEdges[Int(a)].removeAll { $0 == e }
        vertexEdges[Int(b)].removeAll { $0 == e }
        edgeAlive[Int(e)] = false
        freeEdges.append(e)
        edgeCount -= 1
        topologyVersion &+= 1
    }

    /// Removes the vertex with everything attached to it.
    public mutating func removeVertex(_ v: VertexID) {
        guard isVertexAlive(v) else { return }
        for e in vertexEdges[Int(v)] { removeEdge(e) }
        let partner = mirrorPartner[Int(v)]
        if partner >= 0 && partner != v && isVertexAlive(partner) {
            mirrorPartner[Int(partner)] = invalidID
        }
        mirrorPartner[Int(v)] = invalidID
        vertexAlive[Int(v)] = false
        vertexEdges[Int(v)] = []
        freeVertices.append(v)
        vertexCount -= 1
        positionVersion &+= 1
        topologyVersion &+= 1
    }

    public mutating func removeIsolatedVertices(in candidates: [VertexID]) {
        for v in candidates where isVertexAlive(v) && vertexEdges[Int(v)].isEmpty {
            removeVertex(v)
        }
    }

    public mutating func setMirrorPartner(_ v: VertexID, _ partner: VertexID) {
        // Partners are mutual, so whoever this vertex was paired with is left free.
        let old = mirrorPartner[Int(v)]
        if old >= 0, old != v, old != partner, mirrorPartner[Int(old)] == v {
            mirrorPartner[Int(old)] = invalidID
        }
        mirrorPartner[Int(v)] = partner
    }

    /// Lets go of pairs that aren't mutual or lead nowhere. They can always be worked out again from positions.
    mutating func dropBrokenMirrorPartners() {
        for i in mirrorPartner.indices {
            let partner = mirrorPartner[i]
            guard partner >= 0 else { continue }
            let isMutual = Int(partner) < mirrorPartner.count && vertexAlive[Int(partner)] && mirrorPartner[Int(partner)] == Int32(i)
            if !vertexAlive[i] || !isMutual { mirrorPartner[i] = invalidID }
        }
    }

    // MARK: Edge splitting

    /// Inserts a new vertex along `e`. `e` keeps its first end, a new edge takes the rest, and the
    /// loops of adjacent faces gain the vertex in place, so face IDs stay valid.
    @discardableResult
    public mutating func splitEdge(_ e: EdgeID, at t: Float, position: Vec3? = nil) throws -> (vertex: VertexID, newEdge: EdgeID) {
        guard isEdgeAlive(e) else { throw MeshError.staleElement }
        let (a, b) = ends(e)
        let p = position ?? simd_mix(positions[Int(a)], positions[Int(b)], Vec3(repeating: t))
        let v = addVertex(p)

        // Re-point e to a-v without disturbing its face slots.
        edgeEnds[Int(e)] = SIMD2<Int32>(a, v)
        vertexEdges[Int(b)].removeAll { $0 == e }
        vertexEdges[Int(v)].append(e)

        let tail = try ensureEdge(v, b)
        edgeFaces[Int(tail)] = edgeFaces[Int(e)]

        for f in facesOf(edge: e) {
            let loop = faceLoops[Int(f)]
            let count = loop.count
            guard let i = faceEdgeLoops[Int(f)].firstIndex(of: e) else { continue }
            let insertAt = i + 1
            faceLoops[Int(f)].insert(v, at: insertAt)
            if loop[i] == a && loop[(i + 1) % count] == b {
                // a -> v -> b
                faceEdgeLoops[Int(f)].insert(tail, at: insertAt)
            } else {
                // b -> v -> a
                faceEdgeLoops[Int(f)][i] = tail
                faceEdgeLoops[Int(f)].insert(e, at: insertAt)
            }
        }
        topologyVersion &+= 1
        return (v, tail)
    }

    // MARK: Compaction

    /// A copy with no dead slots, plus the old-to-new vertex map (-1 for dropped slots).
    public func compacted() -> (mesh: Mesh, vertexMap: [VertexID], faceMap: [FaceID]) {
        var out = Mesh()
        var vertexMap = [VertexID](repeating: invalidID, count: positions.count)
        for i in 0..<positions.count where vertexAlive[i] {
            vertexMap[i] = out.addVertex(positions[i])
        }
        for i in 0..<positions.count where vertexAlive[i] {
            let partner = mirrorPartner[i]
            if partner >= 0 && Int(partner) < vertexMap.count {
                out.mirrorPartner[Int(vertexMap[i])] = vertexMap[Int(partner)]
            }
        }
        for i in 0..<edgeEnds.count where edgeAlive[i] {
            let pair = edgeEnds[i]
            _ = try? out.ensureEdge(vertexMap[Int(pair.x)], vertexMap[Int(pair.y)])
        }
        var faceMap = [FaceID](repeating: invalidID, count: faceLoops.count)
        for i in 0..<faceLoops.count where faceAlive[i] {
            if let f = try? out.addFace(faceLoops[i].map { vertexMap[Int($0)] }, autoOrient: false) {
                faceMap[i] = f
            }
        }
        return (out, vertexMap, faceMap)
    }

    /// Debug-grade structural check used by tests after every operation. Returns a description of
    /// the first broken invariant.
    public func firstInvariantViolation() -> String? {
        var aliveV = 0
        for i in 0..<positions.count {
            if vertexAlive[i] {
                aliveV += 1
                for e in vertexEdges[i] {
                    guard isEdgeAlive(e) else { return "vertex \(i) lists dead edge \(e)" }
                    let pair = edgeEnds[Int(e)]
                    guard pair.x == Int32(i) || pair.y == Int32(i) else { return "vertex \(i) lists edge \(e) it is not on" }
                }
                guard Set(vertexEdges[i]).count == vertexEdges[i].count else { return "vertex \(i) repeats an edge" }
                let partner = mirrorPartner[i]
                if partner >= 0 {
                    guard isVertexAlive(partner) else { return "vertex \(i) has dead mirror partner \(partner)" }
                    guard mirrorPartner[Int(partner)] == Int32(i) else { return "mirror partners of \(i) are not reciprocal" }
                }
            } else if !vertexEdges[i].isEmpty {
                return "dead vertex \(i) still has edges"
            }
        }
        guard aliveV == vertexCount else { return "vertex count \(vertexCount), actually \(aliveV)" }

        var aliveE = 0
        var seen = Set<UInt64>()
        for i in 0..<edgeEnds.count where edgeAlive[i] {
            aliveE += 1
            let pair = edgeEnds[i]
            guard pair.x != pair.y else { return "edge \(i) is a self-loop" }
            guard isVertexAlive(pair.x), isVertexAlive(pair.y) else { return "edge \(i) has a dead end" }
            guard vertexEdges[Int(pair.x)].contains(Int32(i)), vertexEdges[Int(pair.y)].contains(Int32(i)) else {
                return "edge \(i) is missing from a vertex's list"
            }
            let key = (UInt64(UInt32(min(pair.x, pair.y))) << 32) | UInt64(UInt32(max(pair.x, pair.y)))
            guard seen.insert(key).inserted else { return "edge \(i) duplicates another edge" }
            let slots = edgeFaces[i]
            if slots.x < 0 && slots.y >= 0 { return "edge \(i) has its faces in the wrong slot" }
            if slots.x >= 0 && slots.x == slots.y { return "edge \(i) lists one face twice" }
            for f in facesOf(edge: Int32(i)) {
                guard isFaceAlive(f) else { return "edge \(i) lists dead face \(f)" }
                guard faceEdgeLoops[Int(f)].contains(Int32(i)) else { return "edge \(i) lists face \(f) that does not use it" }
            }
        }
        guard aliveE == edgeCount else { return "edge count \(edgeCount), actually \(aliveE)" }

        var aliveF = 0
        for i in 0..<faceLoops.count where faceAlive[i] {
            aliveF += 1
            let loop = faceLoops[i], edges = faceEdgeLoops[i]
            guard loop.count >= 3 else { return "face \(i) has \(loop.count) corners" }
            guard loop.count == edges.count else { return "face \(i) loop and edge lists differ in length" }
            guard Set(loop).count == loop.count else { return "face \(i) repeats a vertex" }
            for c in 0..<loop.count {
                let a = loop[c], b = loop[(c + 1) % loop.count], e = edges[c]
                guard isEdgeAlive(e) else { return "face \(i) uses dead edge \(e)" }
                let pair = edgeEnds[Int(e)]
                guard (pair.x == a && pair.y == b) || (pair.x == b && pair.y == a) else {
                    return "face \(i) corner \(c): edge \(e) does not join \(a) and \(b)"
                }
                guard edgeFaces[Int(e)].x == Int32(i) || edgeFaces[Int(e)].y == Int32(i) else {
                    return "face \(i) is not registered on edge \(e)"
                }
            }
        }
        guard aliveF == faceCount else { return "face count \(faceCount), actually \(aliveF)" }
        return nil
    }
}

/// Every message here is shown to the artist, so each says what happened in their terms.
public enum MeshError: LocalizedError, Equatable {
    case degenerateEdge
    case staleElement
    case tooFewVertices
    case repeatedVertex
    case duplicateFace
    case nonManifoldEdge
    case inconsistentWinding
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .degenerateEdge: return "An edge can't start and end at the same vertex."
        case .staleElement: return "That part of the mesh no longer exists."
        case .tooFewVertices: return "A face needs at least three vertices."
        case .repeatedVertex: return "A face can't use the same vertex twice."
        case .duplicateFace: return "A face already exists on those vertices."
        case .nonManifoldEdge: return "An edge here already has two faces, and a third would make the mesh non-manifold."
        case .inconsistentWinding: return "The neighbouring faces wind in opposite directions. Use Recalculate Normals first."
        case .invalid(let message): return message
        }
    }
}
