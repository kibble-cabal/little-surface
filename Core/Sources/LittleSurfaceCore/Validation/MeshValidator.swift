import Foundation
import simd

/// The numbers shown in the status bar. Cheap enough to recompute after every edit.
public struct MeshStatistics: Equatable {
    public var vertices = 0
    public var edges = 0
    public var faces = 0
    public var triangles = 0
    public var quads = 0
    public var ngons = 0
    public var components = 0
    /// What the mesh comes to once triangulated: a face of n sides makes n - 2.
    public var triangleEquivalent = 0
    public var poles = 0

    public init() {}

    public init(_ mesh: Mesh) {
        vertices = mesh.vertexCount
        edges = mesh.edgeCount
        faces = mesh.faceCount
        for f in mesh.aliveFaces {
            triangleEquivalent += mesh.loop(f).count - 2
            switch mesh.loop(f).count {
            case 3: triangles += 1
            case 4: quads += 1
            default: ngons += 1
            }
        }
        components = MeshValidator.connectedComponents(mesh).count
        poles = MeshValidator.poles(mesh).count
    }
}

public enum MeshIssueKind: String, CaseIterable, Identifiable {
    case nonManifoldEdges
    case nonManifoldVertices
    case duplicateVertices
    case degenerateFaces
    case inconsistentNormals
    case holes
    case looseEdges
    case isolatedComponents
    case triangles
    case ngons
    case poles
    case selfIntersections

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .nonManifoldEdges: return "Non-manifold edges"
        case .nonManifoldVertices: return "Pinched vertices"
        case .duplicateVertices: return "Duplicate vertices"
        case .degenerateFaces: return "Degenerate faces"
        case .inconsistentNormals: return "Inconsistent normals"
        case .holes: return "Open boundaries"
        case .looseEdges: return "Loose edges"
        case .isolatedComponents: return "Separate pieces"
        case .triangles: return "Triangles"
        case .ngons: return "N-gons"
        case .poles: return "Odd poles"
        case .selfIntersections: return "Possible self-intersections"
        }
    }

    /// Plain explanation of why this might matter. Triangles and n-gons are often fine where they're
    /// placed deliberately, so this informs rather than judges.
    public var explanation: String {
        switch self {
        case .nonManifoldEdges: return "An edge with more than two faces. Many tools can't handle these."
        case .nonManifoldVertices: return "Separate fans of faces meet at a single vertex."
        case .duplicateVertices: return "Separate vertices at the same position, which may need welding."
        case .degenerateFaces: return "Faces with almost no area."
        case .inconsistentNormals: return "Neighbouring faces wind in opposite directions."
        case .holes: return "Closed loops of boundary edges. Some may be intentional, like a neck or a mouth."
        case .looseEdges: return "Edges with no face. They'll export to OBJ as lines and be left out of GLB."
        case .isolatedComponents: return "Parts not connected to the largest piece."
        case .triangles: return "Three-sided faces. Fine in many places, but they can interrupt edge loops."
        case .ngons: return "Faces with more than four sides. They subdivide and deform less predictably."
        case .poles: return "Vertices where other than four edges meet, away from any boundary. A few are needed to turn edge flow, so check they're where you want them."
        case .selfIntersections: return "Faces that may pass through each other. This check is approximate."
        }
    }

    /// False for things that are a matter of artistic judgement, not errors.
    public var isError: Bool {
        switch self {
        case .nonManifoldEdges, .nonManifoldVertices, .duplicateVertices, .degenerateFaces, .inconsistentNormals, .selfIntersections:
            return true
        case .holes, .looseEdges, .isolatedComponents, .triangles, .ngons, .poles:
            return false
        }
    }
}

public struct MeshIssue: Identifiable, Equatable {
    public var kind: MeshIssueKind
    public var vertices: Set<VertexID> = []
    public var edges: Set<EdgeID> = []
    public var faces: Set<FaceID> = []
    public var count: Int

    public var id: String { kind.rawValue }
}

public struct ValidationReport: Equatable {
    public var statistics = MeshStatistics()
    public var issues: [MeshIssue] = []
    public var selfIntersectionCheckWasPartial = false

    public init() {}

    public func issue(_ kind: MeshIssueKind) -> MeshIssue? {
        issues.first { $0.kind == kind }
    }

    /// No structural errors. This doesn't mean a mesh will deform well, which depends on edge flow
    /// that only the artist can judge.
    public var hasNoStructuralErrors: Bool { !issues.contains { $0.kind.isError } }
}

public enum MeshValidator {
    /// Vertices fully surrounded by faces where other than four edges meet. Along a boundary, or on a
    /// loose edge, a count other than four is normal and says nothing about edge flow.
    public static func poles(_ mesh: Mesh) -> [VertexID] {
        mesh.aliveVertices.filter { v in
            let edges = mesh.edgesOf(v)
            return edges.count != 4 && !edges.isEmpty && edges.allSatisfy { mesh.faceCountOf(edge: $0) == 2 }
        }
    }

    /// Connected components by edge connectivity, largest first.
    public static func connectedComponents(_ mesh: Mesh) -> [[VertexID]] {
        var visited = [Bool](repeating: false, count: mesh.positions.count)
        var components: [[VertexID]] = []
        for v in mesh.aliveVertices where !visited[Int(v)] {
            var component: [VertexID] = []
            var stack = [v]
            visited[Int(v)] = true
            while let u = stack.popLast() {
                component.append(u)
                for e in mesh.edgesOf(u) {
                    let n = mesh.otherEnd(e, from: u)
                    if !visited[Int(n)] {
                        visited[Int(n)] = true
                        stack.append(n)
                    }
                }
            }
            components.append(component)
        }
        return components.sorted { $0.count > $1.count }
    }

    public static func analyze(_ mesh: Mesh, duplicateTolerance: Float? = nil, checkSelfIntersections: Bool = true, isCancelled: () -> Bool = { false }) -> ValidationReport {
        var report = ValidationReport()
        report.statistics = MeshStatistics(mesh)
        let diagonal = mesh.bounds.diagonal

        // Faces can't exceed two per edge in this structure, but files and future code shouldn't be
        // trusted, so this still recounts from the face loops.
        var edgeUses = [EdgeID: Int]()
        for f in mesh.aliveFaces {
            for e in mesh.edgeLoop(f) { edgeUses[e, default: 0] += 1 }
        }
        let overused = Set(edgeUses.filter { $0.value > 2 }.keys)
        if !overused.isEmpty {
            report.issues.append(MeshIssue(kind: .nonManifoldEdges, edges: overused, count: overused.count))
        }

        var pinched = Set<VertexID>()
        for v in mesh.aliveVertices {
            let faces = mesh.facesOf(vertex: v)
            guard faces.count > 1 else { continue }
            var seen: Set<FaceID> = [faces[0]]
            var stack = [faces[0]]
            while let f = stack.popLast() {
                guard let pair = mesh.edgesOfFace(f, at: v) else { continue }
                for e in [pair.0, pair.1] {
                    if let g = mesh.oppositeFace(across: e, from: f), seen.insert(g).inserted { stack.append(g) }
                }
            }
            if seen.count != faces.count { pinched.insert(v) }
        }
        if !pinched.isEmpty {
            report.issues.append(MeshIssue(kind: .nonManifoldVertices, vertices: pinched, count: pinched.count))
        }

        let poles = Self.poles(mesh)
        if !poles.isEmpty {
            report.issues.append(MeshIssue(kind: .poles, vertices: Set(poles), count: poles.count))
        }

        let tolerance = duplicateTolerance ?? max(diagonal * 1e-5, 1e-7)
        var buckets = [SIMD3<Int32>: [VertexID]]()
        var duplicates = Set<VertexID>()
        for v in mesh.aliveVertices {
            let p = mesh.position(v)
            let q = p / tolerance
            let k = SIMD3<Int32>(Int32(q.x.rounded(.down)), Int32(q.y.rounded(.down)), Int32(q.z.rounded(.down)))
            for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        for c in buckets[k &+ SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))] ?? [] where simd_length(mesh.position(c) - p) <= tolerance {
                            duplicates.insert(v)
                            duplicates.insert(c)
                        }
                    }
                }
            }
            buckets[k, default: []].append(v)
        }
        if !duplicates.isEmpty {
            report.issues.append(MeshIssue(kind: .duplicateVertices, vertices: duplicates, count: duplicates.count))
        }

        let areaLimit = max(mesh.averageEdgeLength * mesh.averageEdgeLength * 1e-4, 1e-14)
        var degenerate = Set<FaceID>()
        var triangles = Set<FaceID>()
        var ngons = Set<FaceID>()
        for f in mesh.aliveFaces {
            if mesh.faceArea(f) < areaLimit { degenerate.insert(f) }
            let n = mesh.loop(f).count
            if n == 3 { triangles.insert(f) }
            if n > 4 { ngons.insert(f) }
        }
        if !degenerate.isEmpty {
            report.issues.append(MeshIssue(kind: .degenerateFaces, faces: degenerate, count: degenerate.count))
        }

        var inconsistent = Set<EdgeID>()
        for e in mesh.aliveEdges where mesh.faceCountOf(edge: e) == 2 {
            let faces = mesh.facesOf(edge: e)
            let (a, b) = mesh.ends(e)
            if mesh.faceTraverses(faces[0], from: a, to: b) == mesh.faceTraverses(faces[1], from: a, to: b) {
                inconsistent.insert(e)
            }
        }
        if !inconsistent.isEmpty {
            report.issues.append(MeshIssue(kind: .inconsistentNormals, edges: inconsistent, count: inconsistent.count))
        }

        let boundaryLoops = ChainFinder.boundaryLoops(in: mesh)
        if !boundaryLoops.isEmpty {
            var edges = Set<EdgeID>()
            for loop in boundaryLoops { edges.formUnion(loop.edges) }
            report.issues.append(MeshIssue(kind: .holes, edges: edges, count: boundaryLoops.count))
        }

        let wires = Set(mesh.aliveEdges.filter { mesh.isWire($0) })
        if !wires.isEmpty {
            report.issues.append(MeshIssue(kind: .looseEdges, edges: wires, count: wires.count))
        }

        let components = connectedComponents(mesh)
        if components.count > 1 {
            var vertices = Set<VertexID>()
            for component in components.dropFirst() { vertices.formUnion(component) }
            report.issues.append(MeshIssue(kind: .isolatedComponents, vertices: vertices, count: components.count - 1))
        }

        if !triangles.isEmpty {
            report.issues.append(MeshIssue(kind: .triangles, faces: triangles, count: triangles.count))
        }
        if !ngons.isEmpty {
            report.issues.append(MeshIssue(kind: .ngons, faces: ngons, count: ngons.count))
        }

        if checkSelfIntersections {
            let result = selfIntersections(mesh, isCancelled: isCancelled)
            report.selfIntersectionCheckWasPartial = result.partial
            if !result.faces.isEmpty {
                report.issues.append(MeshIssue(kind: .selfIntersections, faces: result.faces, count: result.faces.count))
            }
        }
        return report
    }

    /// Uniform-grid broad phase, face triangles as the narrow phase. Faces sharing a vertex are skipped,
    /// since they always touch. Capped on tests so that a dense mesh returns in reasonable time.
    public static func selfIntersections(_ mesh: Mesh, maxPairTests: Int = 3_000_000, isCancelled: () -> Bool = { false }) -> (faces: Set<FaceID>, partial: Bool) {
        let faces = mesh.aliveFaces
        guard faces.count > 1 else { return ([], false) }
        let box = mesh.bounds
        let cell = max(mesh.averageEdgeLength * 1.5, box.diagonal * 0.01, 1e-6)

        struct Record {
            var box: AABB
            var triangles: [(Vec3, Vec3, Vec3)]
            var vertices: [VertexID]
        }
        var records = [FaceID: Record]()
        records.reserveCapacity(faces.count)
        var grid = [SIMD3<Int32>: [FaceID]]()
        for f in faces {
            let points = mesh.facePositions(f)
            let b = AABB(points: points)
            var tris: [(Vec3, Vec3, Vec3)] = []
            for i in 1..<(points.count - 1) { tris.append((points[0], points[i], points[i + 1])) }
            records[f] = Record(box: b, triangles: tris, vertices: mesh.loop(f))
            let lo = b.minCorner / cell, hi = b.maxCorner / cell
            for x in Int32(lo.x.rounded(.down))...Int32(hi.x.rounded(.down)) {
                for y in Int32(lo.y.rounded(.down))...Int32(hi.y.rounded(.down)) {
                    for z in Int32(lo.z.rounded(.down))...Int32(hi.z.rounded(.down)) {
                        grid[SIMD3<Int32>(x, y, z), default: []].append(f)
                    }
                }
            }
        }

        var out = Set<FaceID>()
        var tests = 0
        var tested = Set<UInt64>()
        for bucket in grid.values {
            guard bucket.count > 1 else { continue }
            for i in 0..<bucket.count {
                for j in (i + 1)..<bucket.count {
                    let a = bucket[i], b = bucket[j]
                    let key = (UInt64(UInt32(min(a, b))) << 32) | UInt64(UInt32(max(a, b)))
                    guard tested.insert(key).inserted else { continue }
                    guard let ra = records[a], let rb = records[b], ra.box.intersects(rb.box) else { continue }
                    if !Set(ra.vertices).isDisjoint(with: rb.vertices) { continue }
                    tests += 1
                    if tests > maxPairTests || (tests & 0xFFFF == 0 && isCancelled()) { return (out, true) }
                    outer: for ta in ra.triangles {
                        for tb in rb.triangles where GeometryMath.trianglesIntersect(ta, tb) {
                            out.insert(a)
                            out.insert(b)
                            break outer
                        }
                    }
                }
            }
        }
        return (out, false)
    }
}
