import Foundation
import simd

/// A plain indexed polygon mesh, used for subdivision results and file output.
public struct PolygonMesh {
    public var positions: [Vec3] = []
    /// Faces as offsets into `faceIndices`: face i is `faceIndices[faceStarts[i]..<faceStarts[i + 1]]`.
    public var faceStarts: [Int32] = [0]
    public var faceIndices: [UInt32] = []

    public init() {}

    public var faceCount: Int { faceStarts.count - 1 }

    public func face(_ i: Int) -> ArraySlice<UInt32> {
        faceIndices[Int(faceStarts[i])..<Int(faceStarts[i + 1])]
    }

    public mutating func addFace<S: Sequence>(_ loop: S) where S.Element == UInt32 {
        faceIndices.append(contentsOf: loop)
        faceStarts.append(Int32(faceIndices.count))
    }
}

public extension Mesh {
    /// The mesh with dead slots removed, faces only. Wire edges have no place in a polygon list.
    func polygonMesh() -> (mesh: PolygonMesh, vertexMap: [Int32]) {
        var out = PolygonMesh()
        var map = [Int32](repeating: -1, count: positions.count)
        for i in 0..<positions.count where vertexAlive[i] && !vertexEdges[i].isEmpty {
            // Vertices used only by wires stay out of the polygon list.
            if vertexEdges[i].contains(where: { faceCountOf(edge: $0) > 0 }) {
                map[i] = Int32(out.positions.count)
                out.positions.append(positions[i])
            }
        }
        for f in aliveFaces {
            out.addFace(loop(f).map { UInt32(map[Int($0)]) })
        }
        return (out, map)
    }
}

public enum CatmullClark {
    /// Hard limit on preview density. This keeps a 3 GB iPad comfortably within memory.
    public static let maxPreviewFaces = 400_000

    public struct CancelledError: Error {}

    /// One subdivision step. Boundaries follow the standard crease rules, so open patches keep their
    /// outline. Throws `CancelledError` when `isCancelled` fires.
    public static func subdivide(_ input: PolygonMesh, isCancelled: () -> Bool = { false }) throws -> PolygonMesh {
        let vertexCount = input.positions.count
        let faceCount = input.faceCount
        guard faceCount > 0 else { return input }

        struct EdgeInfo {
            var a: UInt32
            var b: UInt32
            var faceA: Int32 = -1
            var faceB: Int32 = -1
            var nonManifold = false
        }
        var edgeIndex = [UInt64: Int32]()
        edgeIndex.reserveCapacity(input.faceIndices.count)
        var edges: [EdgeInfo] = []
        edges.reserveCapacity(input.faceIndices.count)
        var cornerEdges = [Int32](repeating: 0, count: input.faceIndices.count)

        var facePoints = [Vec3](repeating: Vec3(repeating: 0), count: faceCount)
        for f in 0..<faceCount {
            if f & 0x3FFF == 0 && isCancelled() { throw CancelledError() }
            let start = Int(input.faceStarts[f]), end = Int(input.faceStarts[f + 1])
            let n = end - start
            var sum = Vec3(repeating: 0)
            for c in start..<end {
                let a = input.faceIndices[c]
                let b = input.faceIndices[c + 1 == end ? start : c + 1]
                sum += input.positions[Int(a)]
                let key = (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
                if let e = edgeIndex[key] {
                    if edges[Int(e)].faceB < 0 { edges[Int(e)].faceB = Int32(f) } else { edges[Int(e)].nonManifold = true }
                    cornerEdges[c] = e
                } else {
                    let e = Int32(edges.count)
                    edges.append(EdgeInfo(a: a, b: b, faceA: Int32(f)))
                    edgeIndex[key] = e
                    cornerEdges[c] = e
                }
            }
            facePoints[f] = sum / Float(n)
        }

        var edgePoints = [Vec3](repeating: Vec3(repeating: 0), count: edges.count)
        var vertexFaceSum = [Vec3](repeating: Vec3(repeating: 0), count: vertexCount)
        var vertexEdgeSum = [Vec3](repeating: Vec3(repeating: 0), count: vertexCount)
        var vertexValence = [Int32](repeating: 0, count: vertexCount)
        var vertexFaceCount = [Int32](repeating: 0, count: vertexCount)
        var boundarySum = [Vec3](repeating: Vec3(repeating: 0), count: vertexCount)
        var boundaryCount = [Int32](repeating: 0, count: vertexCount)

        for (i, e) in edges.enumerated() {
            let pa = input.positions[Int(e.a)], pb = input.positions[Int(e.b)]
            let mid = (pa + pb) * 0.5
            if e.faceB >= 0 && !e.nonManifold {
                edgePoints[i] = (pa + pb + facePoints[Int(e.faceA)] + facePoints[Int(e.faceB)]) * 0.25
            } else {
                edgePoints[i] = mid
                boundarySum[Int(e.a)] += pb
                boundarySum[Int(e.b)] += pa
                boundaryCount[Int(e.a)] += 1
                boundaryCount[Int(e.b)] += 1
            }
            vertexEdgeSum[Int(e.a)] += mid
            vertexEdgeSum[Int(e.b)] += mid
            vertexValence[Int(e.a)] += 1
            vertexValence[Int(e.b)] += 1
        }
        for f in 0..<faceCount {
            for c in Int(input.faceStarts[f])..<Int(input.faceStarts[f + 1]) {
                let v = Int(input.faceIndices[c])
                vertexFaceSum[v] += facePoints[f]
                vertexFaceCount[v] += 1
            }
        }

        var out = PolygonMesh()
        out.positions.reserveCapacity(vertexCount + edges.count + faceCount)
        for v in 0..<vertexCount {
            let p = input.positions[v]
            if boundaryCount[v] == 2 {
                // On a boundary: only boundary neighbours count.
                out.positions.append(p * 0.75 + boundarySum[v] * 0.125)
            } else if boundaryCount[v] > 0 || vertexFaceCount[v] == 0 {
                // Corners and bowties stay pinned.
                out.positions.append(p)
            } else {
                let n = Float(vertexFaceCount[v])
                let f = vertexFaceSum[v] / n
                let r = vertexEdgeSum[v] / Float(vertexValence[v])
                out.positions.append((f + r * 2 + p * (n - 3)) / n)
            }
        }
        let edgeBase = UInt32(out.positions.count)
        out.positions.append(contentsOf: edgePoints)
        let faceBase = UInt32(out.positions.count)
        out.positions.append(contentsOf: facePoints)

        out.faceIndices.reserveCapacity(input.faceIndices.count * 4)
        out.faceStarts.reserveCapacity(input.faceIndices.count + 1)
        for f in 0..<faceCount {
            if f & 0x3FFF == 0 && isCancelled() { throw CancelledError() }
            let start = Int(input.faceStarts[f]), end = Int(input.faceStarts[f + 1])
            for c in start..<end {
                let prev = c == start ? end - 1 : c - 1
                out.addFace([
                    input.faceIndices[c],
                    edgeBase + UInt32(cornerEdges[c]),
                    faceBase + UInt32(f),
                    edgeBase + UInt32(cornerEdges[prev]),
                ])
            }
        }
        return out
    }

    /// Runs `levels` steps, stopping early rather than exceeding the face limit.
    /// Returns the mesh and the number of levels actually applied.
    public static func preview(_ mesh: Mesh, levels: Int, maxFaces: Int = maxPreviewFaces, isCancelled: () -> Bool = { false }) throws -> (mesh: PolygonMesh, levels: Int) {
        var current = mesh.polygonMesh().mesh
        var applied = 0
        for _ in 0..<max(levels, 0) {
            let predicted = current.faceIndices.count
            if predicted > maxFaces { break }
            current = try subdivide(current, isCancelled: isCancelled)
            applied += 1
        }
        return (current, applied)
    }
}

public extension Mesh {
    /// Replaces the mesh's faces with one real Catmull-Clark step: the destructive counterpart of the
    /// preview. Wire edges and their vertices stay as they are.
    mutating func applyCatmullClark(projector: SurfaceProjector?) throws {
        guard faceCount > 0 else { throw MeshError.invalid("There are no faces to subdivide.") }
        let (poly, map) = polygonMesh()
        let result = try CatmullClark.subdivide(poly)

        var work = Mesh()
        var carried = [VertexID](repeating: invalidID, count: positions.count)
        var polyToNew = [VertexID](repeating: invalidID, count: result.positions.count)
        for (i, p) in result.positions.enumerated() {
            var q = p
            if let projector, !projector.isEmpty, let projected = projector.project(p) { q = projected.position }
            polyToNew[i] = work.addVertex(q)
        }
        for i in 0..<positions.count where vertexAlive[i] {
            if map[i] >= 0 {
                carried[i] = polyToNew[Int(map[i])]
            } else {
                carried[i] = work.addVertex(positions[i])
            }
        }
        for e in aliveEdges where isWire(e) {
            let (a, b) = ends(e)
            try work.ensureEdge(carried[Int(a)], carried[Int(b)])
        }
        for f in 0..<result.faceCount {
            try work.addFace(result.face(f).map { polyToNew[Int($0)] }, autoOrient: false)
        }
        let previous = (positionVersion, topologyVersion)
        self = work
        positionVersion = previous.0 &+ 1
        topologyVersion = previous.1 &+ 1
    }
}
