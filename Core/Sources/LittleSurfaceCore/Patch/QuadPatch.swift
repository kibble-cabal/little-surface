import Foundation
import simd

public struct QuadPatchParameters: Equatable, Codable {
    /// Rows between chains. 0 picks a count that gives roughly square quads.
    public var rows: Int = 0
    /// Multiplies the column count by splitting boundary edges.
    public var columnDensity: Int = 1
    /// Multiplies the row count of a four-sided patch by splitting its side edges.
    public var rowDensity: Int = 1
    public var relaxIterations: Int = 4
    /// Split boundary edges when two sides have different vertex counts.
    public var matchVertexCounts = true
    /// Swaps which ends of two open chains connect.
    public var flipPairing = false
    public init() {}
}

/// What a patch would do, for preview and for commit.
public struct PatchPlan {
    public var plan: TopologyPlan
    public var rows: Int
    public var columns: Int
    public var boundarySplits: Int
    public var kind: Kind

    public enum Kind: String {
        case twoChains = "Between two chains"
        case ring = "Ring between two loops"
        case fourSided = "Four-sided patch"
        case filledLoop = "Filled loop"
    }
}

/// Generates quads between boundary chains. Throws a plain-language explanation, and changes nothing,
/// for regions it can't fill cleanly.
public enum QuadPatchBuilder {
    public static func plan(
        chains: [BoundaryChain],
        parameters: QuadPatchParameters,
        mesh: Mesh,
        projector: SurfaceProjector?,
        cornerGapTolerance: Float = 0,
        linesYieldToFaces: Bool = false
    ) throws -> PatchPlan {
        for chain in chains {
            guard chain.isAlive(in: mesh) else { throw MeshError.staleElement }
        }
        let closedCount = chains.filter(\.isClosed).count
        switch (chains.count, closedCount) {
        case (0, _):
            throw MeshError.invalid("Pick two edge chains, or a closed loop, to fill between.")
        case (1, 1):
            return try planClosedLoop(chains[0], parameters: parameters, mesh: mesh, projector: projector)
        case (1, _):
            throw MeshError.invalid("One open chain doesn't enclose anything. Pick a second chain to fill between them.")
        case (2, 2):
            return try planRing(chains[0], chains[1], parameters: parameters, mesh: mesh, projector: projector, linesYield: linesYieldToFaces)
        case (2, 0):
            return try planTwoChains(chains[0], chains[1], parameters: parameters, mesh: mesh, projector: projector, linesYield: linesYieldToFaces)
        case (2, _):
            throw MeshError.invalid("A closed loop and an open chain can't be paired, because their ends don't match up. Split the loop into a chain first, or pick two of the same kind.")
        case (3, _):
            throw MeshError.invalid("Quad patches need two or four sides, and three sides can't divide evenly into quads. Add a fourth chain, or split one side with a vertex.")
        case (4, 0):
            return try planFourSided(chains, parameters: parameters, mesh: mesh, projector: projector, gapTolerance: cornerGapTolerance)
        default:
            throw MeshError.invalid("This region has more than four sides. Split it into smaller patches with a new edge or two, then fill each one.")
        }
    }

    // MARK: Two open chains

    private static func planTwoChains(_ a: BoundaryChain, _ bInput: BoundaryChain, parameters: QuadPatchParameters, mesh: Mesh, projector: SurfaceProjector?, linesYield: Bool) throws -> PatchPlan {
        if a.vertices == bInput.vertices || a.vertices == bInput.vertices.reversed() {
            throw MeshError.invalid("Those are the same chain. Pick a different second chain.")
        }
        // A shared end would pinch a row down to a point.
        let a0 = a.vertices.first!, a1 = a.vertices.last!, b0 = bInput.vertices.first!, b1 = bInput.vertices.last!
        let sharedEnds = Set([a0, a1]).intersection([b0, b1])
        if sharedEnds.count == 2 {
            guard let joined = joinClosed(a, bInput, in: mesh) else {
                throw MeshError.invalid("These chains meet at both ends but don't form a clean loop.")
            }
            return try planClosedLoop(joined, parameters: parameters, mesh: mesh, projector: projector)
        }
        if sharedEnds.count == 1 {
            throw MeshError.invalid("These chains meet at a single vertex, which would collapse the patch to a point. Draw a third side and a fourth to make four sides, or start one chain a little away from the other.")
        }
        if !Set(a.vertices).isDisjoint(with: bInput.vertices) {
            throw MeshError.invalid("These chains touch partway along. Pick chains that stay apart, or split the region at the place they meet.")
        }

        var b = bInput
        let pa0 = mesh.position(a0), pa1 = mesh.position(a1)
        let pb0 = mesh.position(b0), pb1 = mesh.position(b1)
        let straight = simd_length(pa0 - pb0) + simd_length(pa1 - pb1)
        let crossed = simd_length(pa0 - pb1) + simd_length(pa1 - pb0)
        var reverse = crossed < straight
        if parameters.flipPairing { reverse.toggle() }
        if reverse { b = b.reversed() }

        let keptA = linesYield ? thinned(a, against: b, parameters: parameters, mesh: mesh) : nil
        let keptB = linesYield ? thinned(b, against: a, parameters: parameters, mesh: mesh) : nil
        let counts = try keptA != nil ? b.segmentCount : keptB != nil ? a.segmentCount
            : matchedCounts(a.segmentCount, b.segmentCount, density: parameters.columnDensity, match: parameters.matchVertexCounts, nameA: "first chain", nameB: "second chain")
        var splits = 0
        var builder = PlanBuilder(mesh: mesh)
        let sideA = keptA.map { $0.map { builder.nodeForVertex($0) } } ?? builder.distribute(chain: a, segments: counts, splits: &splits, projector: projector)
        let sideB = keptB.map { $0.map { builder.nodeForVertex($0) } } ?? builder.distribute(chain: b, segments: counts, splits: &splits, projector: projector)

        let rows = rowCount(parameters.rows, sideA: sideA, sideB: sideB, builder: builder)

        // A straight wire joining the ends would run along the new side rail: it gets replaced.
        var removals: [EdgeID] = []
        if rows > 1 {
            for (p, q) in [(sideA.first!, sideB.first!), (sideA.last!, sideB.last!)] {
                guard case .existing(let v) = builder.nodes[p], case .existing(let w) = builder.nodes[q], let e = mesh.edge(between: v, w) else { continue }
                guard mesh.isWire(e) else {
                    throw MeshError.invalid("A side edge of this region already belongs to a face, so it can't take new rows. Use one row, or split that edge to match.")
                }
                removals.append(e)
            }
        }

        var grid = Grid(columns: counts + 1, rows: rows + 1, wraps: false)
        for c in 0...counts {
            grid[c, 0] = sideA[c]
            grid[c, rows] = sideB[c]
        }
        builder.fillRuled(&grid)
        relaxAndProject(&grid, builder: &builder, iterations: parameters.relaxIterations, projector: projector)
        var result = try builder.finish(grid: grid, projector: projector)
        result.removeEdges = removals + (keptA != nil ? a.edges : []) + (keptB != nil ? b.edges : [])
        return PatchPlan(plan: result, rows: rows, columns: counts, boundarySplits: splits, kind: .twoChains)
    }

    /// Two chains that share both ends are one loop.
    private static func joinClosed(_ a: BoundaryChain, _ b: BoundaryChain, in mesh: Mesh) -> BoundaryChain? {
        var other = b
        if other.vertices.first != a.vertices.last { other = other.reversed() }
        guard other.vertices.first == a.vertices.last, other.vertices.last == a.vertices.first else { return nil }
        let verts = a.vertices + other.vertices[1..<(other.vertices.count - 1)]
        return BoundaryChain(vertices: Array(verts), edges: a.edges + other.edges, isClosed: true)
    }

    // MARK: Two closed loops

    private static func planRing(_ a: BoundaryChain, _ bInput: BoundaryChain, parameters: QuadPatchParameters, mesh: Mesh, projector: SurfaceProjector?, linesYield: Bool) throws -> PatchPlan {
        guard Set(a.vertices).isDisjoint(with: bInput.vertices) else {
            throw MeshError.invalid("These loops share vertices, so there's no ring between them. Pick two separate loops.")
        }
        let keptA = linesYield ? thinned(a, against: bInput, parameters: parameters, mesh: mesh) : nil
        let keptB = linesYield ? thinned(bInput, against: a, parameters: parameters, mesh: mesh) : nil
        let counts = try keptA != nil ? bInput.segmentCount : keptB != nil ? a.segmentCount
            : matchedCounts(a.segmentCount, bInput.segmentCount, density: parameters.columnDensity, match: parameters.matchVertexCounts, nameA: "first loop", nameB: "second loop")
        var splits = 0
        var builder = PlanBuilder(mesh: mesh)
        let sideA = keptA.map { $0.map { builder.nodeForVertex($0) } } ?? builder.distribute(chain: a, segments: counts, splits: &splits, projector: projector)
        var sideB = keptB.map { $0.map { builder.nodeForVertex($0) } } ?? builder.distribute(chain: bInput, segments: counts, splits: &splits, projector: projector)

        // Choose the direction and starting vertex with the least total stretch, so rows don't twist.
        let positionsA = sideA.map(builder.position), positionsB = sideB.map(builder.position)
        var bestCost = Float.infinity
        var bestShift = 0
        var bestReversed = false
        for reversed in [false, true] {
            for shift in 0..<counts {
                var cost: Float = 0
                for c in 0..<counts {
                    let index = reversed ? (shift + counts - c) % counts : (shift + c) % counts
                    cost += simd_length_squared(positionsA[c] - positionsB[index])
                    if cost >= bestCost { break }
                }
                if cost < bestCost {
                    bestCost = cost
                    bestShift = shift
                    bestReversed = reversed
                }
            }
        }
        sideB = (0..<counts).map { c in
            sideB[bestReversed ? (bestShift + counts - c) % counts : (bestShift + c) % counts]
        }

        let rows = rowCount(parameters.rows, sideA: sideA, sideB: sideB, builder: builder)
        var grid = Grid(columns: counts, rows: rows + 1, wraps: true)
        for c in 0..<counts {
            grid[c, 0] = sideA[c]
            grid[c, rows] = sideB[c]
        }
        builder.fillRuled(&grid)
        relaxAndProject(&grid, builder: &builder, iterations: parameters.relaxIterations, projector: projector)
        var result = try builder.finish(grid: grid, projector: projector)
        result.removeEdges = (keptA != nil ? a.edges : []) + (keptB != nil ? bInput.edges : [])
        return PatchPlan(plan: result, rows: rows, columns: counts, boundarySplits: splits, kind: .ring)
    }

    // MARK: Four sides

    private static func planFourSided(_ chains: [BoundaryChain], parameters: QuadPatchParameters, mesh: Mesh, projector: SurfaceProjector?, gapTolerance: Float) throws -> PatchPlan {
        let ordered = try orderIntoLoop(chains, mesh: mesh)
        return try buildCoons(sides: ordered, parameters: parameters, mesh: mesh, projector: projector, kind: .fourSided)
    }

    /// Lines four chains up end to end, each one starting where the last one stopped.
    private static func orderIntoLoop(_ chains: [BoundaryChain], mesh: Mesh) throws -> [BoundaryChain] {
        var remaining = Array(chains.dropFirst())
        var ordered = [chains[0]]
        while !remaining.isEmpty {
            let tail = ordered.last!.vertices.last!
            guard let i = remaining.firstIndex(where: { $0.vertices.first == tail || $0.vertices.last == tail }) else {
                throw MeshError.invalid("These four chains don't join end to end. Draw the sides so that their ends meet; they snap together when they're close.")
            }
            var next = remaining.remove(at: i)
            if next.vertices.first != tail { next = next.reversed() }
            ordered.append(next)
        }
        guard ordered.last!.vertices.last == ordered[0].vertices.first else {
            throw MeshError.invalid("These four chains don't close into a loop. There's a gap between the last chain and the first.")
        }
        return ordered
    }

    private static func buildCoons(sides: [BoundaryChain], parameters: QuadPatchParameters, mesh: Mesh, projector: SurfaceProjector?, kind: PatchPlan.Kind) throws -> PatchPlan {
        let columns = try matchedCounts(sides[0].segmentCount, sides[2].segmentCount, density: parameters.columnDensity, match: parameters.matchVertexCounts, nameA: "first side", nameB: "opposite side")
        let requestedRows = parameters.rows > 0 ? parameters.rows : 0
        var rows = try matchedCounts(sides[1].segmentCount, sides[3].segmentCount, density: parameters.rowDensity, match: parameters.matchVertexCounts, nameA: "second side", nameB: "opposite side")
        if requestedRows > rows { rows = requestedRows }

        var splits = 0
        var builder = PlanBuilder(mesh: mesh)
        let bottom = builder.distribute(chain: sides[0], segments: columns, splits: &splits, projector: projector)
        let right = builder.distribute(chain: sides[1], segments: rows, splits: &splits, projector: projector)
        let top = builder.distribute(chain: sides[2], segments: columns, splits: &splits, projector: projector)
        let left = builder.distribute(chain: sides[3], segments: rows, splits: &splits, projector: projector)

        // bottom runs left to right, right runs up, top runs right to left, left runs down.
        var grid = Grid(columns: columns + 1, rows: rows + 1, wraps: false)
        for c in 0...columns {
            grid[c, 0] = bottom[c]
            grid[c, rows] = top[columns - c]
        }
        for r in 0...rows {
            grid[columns, r] = right[r]
            grid[0, r] = left[rows - r]
        }
        builder.fillCoons(&grid)
        relaxAndProject(&grid, builder: &builder, iterations: parameters.relaxIterations, projector: projector)
        return PatchPlan(plan: try builder.finish(grid: grid, projector: projector), rows: rows, columns: columns, boundarySplits: splits, kind: kind)
    }

    // MARK: One closed loop

    /// Fills a closed loop as a four-sided patch, with its corners placed where the loop turns most.
    /// Corners are constrained so that opposite sides have equal counts, which is what quads need.
    private static func planClosedLoop(_ input: BoundaryChain, parameters: QuadPatchParameters, mesh: Mesh, projector: SurfaceProjector?) throws -> PatchPlan {
        var chain = input
        var plannedOddSplit = false
        if chain.segmentCount % 2 != 0 {
            guard parameters.matchVertexCounts else {
                throw MeshError.invalid("This loop has an odd number of edges (\(chain.segmentCount)), and quads can only fill a loop with an even number. Turn on vertex matching, or split one edge.")
            }
            plannedOddSplit = true
        }
        guard chain.segmentCount >= 3 else {
            throw MeshError.invalid("This loop is too small to fill.")
        }

        // An odd loop gets one extra vertex on its longest edge, placed like any other boundary split.
        var builder = PlanBuilder(mesh: mesh)
        var splits = 0
        let target = plannedOddSplit ? chain.segmentCount + 1 : chain.segmentCount
        let loopNodes = builder.distribute(chain: chain, segments: target, splits: &splits, projector: projector)
        chain = input
        let total = loopNodes.count
        guard total >= 4 else { throw MeshError.invalid("This loop is too small to fill with quads.") }
        let positions = loopNodes.map(builder.position)

        // Turning angle at each loop vertex.
        var turn = [Float](repeating: 0, count: total)
        for i in 0..<total {
            let a = GeometryMath.safeNormalize(positions[i] - positions[(i + total - 1) % total])
            let b = GeometryMath.safeNormalize(positions[(i + 1) % total] - positions[i])
            turn[i] = acos(simd_clamp(simd_dot(a, b), -1, 1))
        }

        // Corners at i, i+u, i+half, i+half+u, for sides of u, v, u, v. Real corners win. A smooth
        // shape has none, and hand wobble mustn't pick them, so there the corners that take in the
        // most of the shape, nearest to square-cornered, give the straightest rows.
        func cornerStrength(_ i: Int) -> Float { max(0, turn[i % total] - 0.5) }
        var perimeter: Float = 0
        for i in 0..<total { perimeter += simd_length(positions[(i + 1) % total] - positions[i]) }
        let fullArea = max(perimeter * perimeter / 16, 1e-12)
        let half = total / 2
        var bestScore = -Float.infinity
        var bestStart = 0, bestU = 1
        for start in 0..<half {
            for u in 1..<max(half, 2) {
                let corners = [start, start + u, start + half, start + half + u]
                let p = corners.map { positions[$0 % total] }
                let area = simd_length(simd_cross(p[2] - p[0], p[3] - p[1])) * 0.5 / fullArea
                var square: Float = 0
                for k in 0..<4 {
                    let toNext = GeometryMath.safeNormalize(p[(k + 1) % 4] - p[k])
                    let toPrevious = GeometryMath.safeNormalize(p[(k + 3) % 4] - p[k])
                    square += 1 - abs(simd_dot(toNext, toPrevious))
                }
                let score = corners.reduce(Float(0)) { $0 + cornerStrength($1) } * 1.5 + area + square * 0.125
                if score > bestScore {
                    bestScore = score
                    bestStart = start
                    bestU = u
                }
            }
        }
        let u = bestU, v = half - bestU
        func at(_ k: Int) -> Int { loopNodes[(bestStart + k) % total] }

        var grid = Grid(columns: u + 1, rows: v + 1, wraps: false)
        for c in 0...u {
            grid[c, 0] = at(c)
            grid[c, v] = at(u + v + u - c)
        }
        for r in 0...v {
            grid[u, r] = at(u + r)
            grid[0, r] = at(u + v + u + v - r)
        }
        builder.fillCoons(&grid)
        relaxAndProject(&grid, builder: &builder, iterations: parameters.relaxIterations, projector: projector)
        return PatchPlan(plan: try builder.finish(grid: grid, projector: projector), rows: v, columns: u, boundarySplits: splits, kind: .filledLoop)
    }

    // MARK: Shared helpers

    /// When a drawn line has more segments than the finished edge it's joining, the line's vertices
    /// that keep it evenly spaced with one per segment of that edge. Splitting the edge instead would
    /// turn the finished quads beside it into n-gons. Nil when the line doesn't need to give way.
    private static func thinned(_ line: BoundaryChain, against other: BoundaryChain, parameters: QuadPatchParameters, mesh: Mesh) -> [VertexID]? {
        guard parameters.columnDensity <= 1, line.segmentCount > other.segmentCount, line.edges.allSatisfy(mesh.isWire),
              other.edges.contains(where: { !mesh.isWire($0) }) else { return nil }
        var along: [Float] = [0]
        let count = line.vertices.count
        for i in 0..<line.segmentCount {
            along.append(along[i] + simd_length(mesh.position(line.vertices[(i + 1) % count]) - mesh.position(line.vertices[i])))
        }
        let total = along[line.segmentCount]
        let wanted = other.segmentCount
        var kept = [line.vertices[0]]
        var index = 0
        for k in 1..<wanted {
            let target = total * Float(k) / Float(wanted)
            // Leave enough vertices for the segments still to come.
            let last = line.segmentCount - (wanted - k)
            var pick = index + 1
            while pick < last, abs(along[pick + 1] - target) <= abs(along[pick] - target) { pick += 1 }
            kept.append(line.vertices[pick])
            index = pick
        }
        if !line.isClosed { kept.append(line.vertices[count - 1]) }
        return kept
    }

    private static func matchedCounts(_ a: Int, _ b: Int, density: Int, match: Bool, nameA: String, nameB: String) throws -> Int {
        if a != b && !match {
            throw MeshError.invalid("The \(nameA) has \(a) segments and the \(nameB) has \(b). Turn on vertex matching to split edges until they agree, or edit them to match.")
        }
        return max(a, b) * max(1, density)
    }

    private static func rowCount(_ requested: Int, sideA: [Int], sideB: [Int], builder: PlanBuilder) -> Int {
        if requested > 0 { return requested }
        var gap: Float = 0
        for (p, q) in zip(sideA, sideB) { gap += simd_length(builder.position(p) - builder.position(q)) }
        gap /= Float(max(sideA.count, 1))
        var spacing: Float = 0
        for side in [sideA, sideB] where side.count > 1 {
            for i in 1..<side.count { spacing += simd_length(builder.position(side[i]) - builder.position(side[i - 1])) }
        }
        spacing /= Float(max(sideA.count + sideB.count - 2, 1))
        return max(1, Int((gap / max(spacing, 1e-6)).rounded()))
    }

    private static func relaxAndProject(_ grid: inout Grid, builder: inout PlanBuilder, iterations: Int, projector: SurfaceProjector?) {
        builder.projectInterior(grid, projector: projector)
        for _ in 0..<max(iterations, 0) {
            builder.relaxInterior(grid, projector: projector)
        }
    }

    // MARK: Grid

    struct Grid {
        let columns: Int
        let rows: Int
        let wraps: Bool
        private var cells: [Int]

        init(columns: Int, rows: Int, wraps: Bool) {
            self.columns = columns
            self.rows = rows
            self.wraps = wraps
            cells = [Int](repeating: -1, count: columns * rows)
        }

        subscript(c: Int, r: Int) -> Int {
            get { cells[r * columns + (wraps ? (c + columns) % columns : c)] }
            set { cells[r * columns + (wraps ? (c + columns) % columns : c)] = newValue }
        }
    }

    // MARK: PlanBuilder

    /// Collects nodes during generation. Interior nodes carry mutable positions until `finish`.
    struct PlanBuilder {
        let mesh: Mesh
        private(set) var nodes: [PlanNode] = []
        private var vertexNodes = [VertexID: Int]()

        init(mesh: Mesh) { self.mesh = mesh }

        func position(_ index: Int) -> Vec3 {
            switch nodes[index] {
            case .existing(let v): return mesh.position(v)
            case .split(_, _, let p): return p
            case .new(let p, _): return p
            }
        }

        func normal(_ index: Int) -> Vec3? {
            switch nodes[index] {
            case .new(_, let n): return simd_length_squared(n) > 0 ? n : nil
            case .existing(let v):
                let n = mesh.vertexNormal(v)
                return simd_length_squared(n) > 0 ? n : nil
            case .split(let e, _, _):
                let (a, _) = mesh.ends(e)
                let n = mesh.vertexNormal(a)
                return simd_length_squared(n) > 0 ? n : nil
            }
        }

        mutating func nodeForVertex(_ v: VertexID) -> Int {
            if let n = vertexNodes[v] { return n }
            nodes.append(.existing(v))
            vertexNodes[v] = nodes.count - 1
            return nodes.count - 1
        }

        mutating func add(_ node: PlanNode) -> Int {
            nodes.append(node)
            return nodes.count - 1
        }

        /// The chain's nodes in order at the requested segment count, adding edge splits as needed.
        /// Extra vertices go on the longest edges, one at a time, so spacing evens out. A closed chain
        /// comes back without its repeated first vertex.
        mutating func distribute(chain: BoundaryChain, segments: Int, splits: inout Int, projector: SurfaceProjector?) -> [Int] {
            var cuts = [Int](repeating: 0, count: chain.segmentCount)
            let lengths = chain.edges.map { mesh.edgeLength($0) }
            var extra = segments - chain.segmentCount
            while extra > 0 {
                var best = 0
                var bestPiece: Float = -1
                for i in 0..<cuts.count {
                    let piece = lengths[i] / Float(cuts[i] + 1)
                    if piece > bestPiece {
                        bestPiece = piece
                        best = i
                    }
                }
                cuts[best] += 1
                extra -= 1
            }

            var out: [Int] = []
            let vertexCount = chain.vertices.count
            for i in 0..<chain.segmentCount {
                let from = chain.vertices[i]
                let to = chain.vertices[(i + 1) % vertexCount]
                out.append(nodeForVertex(from))
                let e = chain.edges[i]
                let (first, _) = mesh.ends(e)
                let pFrom = mesh.position(from), pTo = mesh.position(to)
                for k in 0..<cuts[i] {
                    let along = Float(k + 1) / Float(cuts[i] + 1)
                    var p = simd_mix(pFrom, pTo, Vec3(repeating: along))
                    if let projector, let projected = projector.project(p, maxDistance: lengths[i]) {
                        p = projected.position
                    }
                    // Plans measure t from the edge's own first end, whichever way the chain runs.
                    let t = first == from ? along : 1 - along
                    out.append(add(.split(edge: e, t: t, position: p)))
                    splits += 1
                }
            }
            if !chain.isClosed { out.append(nodeForVertex(chain.vertices[vertexCount - 1])) }
            return out
        }

        mutating func fillRuled(_ grid: inout Grid) {
            let last = grid.rows - 1
            guard last > 1 else { return }
            for c in 0..<grid.columns {
                let a = position(grid[c, 0]), b = position(grid[c, last])
                let n = normal(grid[c, 0]) ?? normal(grid[c, last]) ?? Vec3(repeating: 0)
                for r in 1..<last {
                    let t = Float(r) / Float(last)
                    grid[c, r] = add(.new(position: simd_mix(a, b, Vec3(repeating: t)), normal: n))
                }
            }
        }

        /// Fills cells still at -1 with a Coons patch of the four sides.
        mutating func fillCoons(_ grid: inout Grid) {
            let cMax = grid.columns - 1, rMax = grid.rows - 1
            guard cMax > 1, rMax > 1 else { return }
            let c00 = position(grid[0, 0]), c10 = position(grid[cMax, 0]), c01 = position(grid[0, rMax]), c11 = position(grid[cMax, rMax])
            for r in 1..<rMax {
                let v = Float(r) / Float(rMax)
                for c in 1..<cMax {
                    let u = Float(c) / Float(cMax)
                    let along: Vec3 = simd_mix(position(grid[c, 0]), position(grid[c, rMax]), Vec3(repeating: v))
                    let across: Vec3 = simd_mix(position(grid[0, r]), position(grid[cMax, r]), Vec3(repeating: u))
                    let lower: Vec3 = simd_mix(c00, c10, Vec3(repeating: u))
                    let upper: Vec3 = simd_mix(c01, c11, Vec3(repeating: u))
                    let bilinear: Vec3 = simd_mix(lower, upper, Vec3(repeating: v))
                    let n = normal(grid[c, 0]) ?? normal(grid[0, r]) ?? Vec3(repeating: 0)
                    grid[c, r] = add(.new(position: along + across - bilinear, normal: n))
                }
            }
        }

        private mutating func setNew(_ index: Int, position p: Vec3, normal n: Vec3) {
            nodes[index] = .new(position: p, normal: n)
        }

        /// Every node this patch itself creates in its grid (its interior, or a ruled patch's rails).
        private func movableNodes(_ grid: Grid) -> [(index: Int, c: Int, r: Int)] {
            var out: [(index: Int, c: Int, r: Int)] = []
            for r in 0..<grid.rows {
                for c in 0..<grid.columns {
                    let index = grid[c, r]
                    if case .new = nodes[index] { out.append((index, c, r)) }
                }
            }
            return out
        }

        mutating func projectInterior(_ grid: Grid, projector: SurfaceProjector?) {
            guard let projector, !projector.isEmpty else { return }
            let reach = max(gridSpan(grid), 1e-4)
            for item in movableNodes(grid) {
                let p = position(item.index)
                let hint = normal(item.index)
                if let hit = projector.project(p, normalHint: hint, maxDistance: reach) {
                    setNew(item.index, position: hit.position, normal: hit.normal)
                }
            }
        }

        private func gridSpan(_ grid: Grid) -> Float {
            var box = AABB.empty
            for r in 0..<grid.rows {
                for c in 0..<grid.columns { box.grow(position(grid[c, r])) }
            }
            return box.diagonal
        }

        /// Laplacian smoothing that leaves boundaries alone, then pulls back onto the surface.
        mutating func relaxInterior(_ grid: Grid, projector: SurfaceProjector?) {
            var updates: [(Int, Vec3)] = []
            for item in movableNodes(grid) {
                var sum = Vec3(repeating: 0)
                var count: Float = 0
                let isRail = !grid.wraps && (item.c == 0 || item.c == grid.columns - 1)
                let isEdgeRow = item.r == 0 || item.r == grid.rows - 1
                if isEdgeRow { continue }
                // Free side rails only slide along their rail, so the patch outline stays put sideways.
                if !isRail, grid.wraps || (item.c > 0 && item.c < grid.columns - 1) {
                    sum += position(grid[item.c - 1, item.r]) + position(grid[item.c + 1, item.r])
                    count += 2
                }
                sum += position(grid[item.c, item.r - 1]) + position(grid[item.c, item.r + 1])
                count += 2
                updates.append((item.index, position(item.index) * 0.5 + (sum / count) * 0.5))
            }
            let reach = max(gridSpan(grid), 1e-4)
            for (index, p) in updates {
                let hint = normal(index)
                if let projector, !projector.isEmpty, let hit = projector.project(p, normalHint: hint, maxDistance: reach) {
                    setNew(index, position: hit.position, normal: hit.normal)
                } else {
                    setNew(index, position: p, normal: hint ?? Vec3(repeating: 0))
                }
            }
        }

        /// Winds and validates the grid, and packs it into a plan.
        func finish(grid: Grid, projector: SurfaceProjector?) throws -> TopologyPlan {
            var plan = TopologyPlan()
            plan.nodes = nodes

            let columnSpan = grid.wraps ? grid.columns : grid.columns - 1
            var loops: [[Int32]] = []
            for r in 0..<(grid.rows - 1) {
                for c in 0..<columnSpan {
                    loops.append([
                        Int32(grid[c, r]),
                        Int32(grid[(c + 1) % grid.columns, r]),
                        Int32(grid[(c + 1) % grid.columns, r + 1]),
                        Int32(grid[c, r + 1]),
                    ])
                }
            }

            var surfaceVote: Float = 0
            var neighborVote = 0
            var collapsed = 0
            var flippedAgainstSurface = 0
            var normals: [Vec3] = []
            for loop in loops {
                let points = loop.map { position(Int($0)) }
                let n = GeometryMath.newellNormal(points)
                normals.append(n)
                if simd_length(n) < 1e-10 { collapsed += 1 }
                if let projector, !projector.isEmpty {
                    let center: Vec3 = points.reduce(Vec3(repeating: 0), +) / Float(4)
                    if let hit = projector.closest(to: center) { surfaceVote += simd_dot(n, hit.normal) }
                }
                // Existing faces fix the winding: a new face must run an edge opposite to its neighbour.
                for i in 0..<4 {
                    guard case .existing(let a) = nodes[Int(loop[i])], case .existing(let b) = nodes[Int(loop[(i + 1) % 4])],
                          let e = mesh.edge(between: a, b), mesh.isBoundary(e) else { continue }
                    let neighbor = mesh.facesOf(edge: e)[0]
                    neighborVote += mesh.faceTraverses(neighbor, from: a, to: b) ? -1 : 1
                }
            }
            if collapsed > 0 {
                throw MeshError.invalid("\(collapsed) of these quads collapse to nothing, so the sides are probably overlapping. Move them apart or use fewer rows.")
            }

            let reverse = neighborVote != 0 ? neighborVote < 0 : surfaceVote < 0
            if reverse { loops = loops.map { Array($0.reversed()) } }
            let sign: Float = reverse ? -1 : 1
            if let projector, !projector.isEmpty {
                for (loop, n) in zip(loops, normals) {
                    let corners: [Vec3] = loop.map { position(Int($0)) }
                    let center: Vec3 = corners.reduce(Vec3(repeating: 0), +) / Float(4)
                    if let hit = projector.closest(to: center), simd_dot(n, hit.normal) * sign < 0 { flippedAgainstSurface += 1 }
                }
            }
            plan.faces = loops

            let splitCount = nodes.reduce(0) { total, node in
                if case .split = node { return total + 1 }
                return total
            }
            if splitCount > 0 {
                plan.notes.append(splitCount == 1 ? "Adds 1 vertex to a boundary so the sides match." : "Adds \(splitCount) vertices to the boundaries so the sides match.")
            }
            // Splitting an edge shared with a face adds a corner to that face.
            let neighbouring = Set(nodes.compactMap { node -> FaceID? in
                if case .split(let e, _, _) = node { return mesh.facesOf(edge: e).first }
                return nil
            }).count
            if neighbouring > 0 {
                plan.notes.append(neighbouring == 1 ? "1 neighbouring face gains a corner and becomes an n-gon." : "\(neighbouring) neighbouring faces gain a corner and become n-gons.")
            }
            if flippedAgainstSurface > 0 {
                plan.notes.append("\(flippedAgainstSurface) quads face away from the surface. The patch may be folding; try fewer rows or more relaxing.")
            }
            return plan
        }
    }
}
