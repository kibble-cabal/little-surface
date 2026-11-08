import Foundation
import simd

/// One moment of a guide example: a mesh, and what to light up on it.
public struct ExampleFrame {
    public var mesh: Mesh
    public var highlight: Selection
    /// A word or two to show over the clip, such as how many sides there are.
    public var caption: String?
}

/// The short looping clips in the guide. Each is a small quad mesh made here, so it shows exactly
/// the pattern its page is about.
public enum GuideExample: String, CaseIterable, Sendable {
    case loops, flow, bend, poles, sprout, opening, reductions, reducingTube, density, silhouette

    /// How long one loop of the clip lasts.
    public var duration: Double {
        switch self {
        case .loops: return 7
        case .flow: return 4.2
        case .bend: return 4
        case .poles: return 4.5
        case .sprout: return 4.2
        case .opening: return 6
        case .reductions, .reducingTube: return 6
        case .density: return 4.2
        case .silhouette: return 6
        }
    }

    /// The moment to show as a still, when motion is turned down.
    public var stillTime: Double {
        switch self {
        case .loops: return 1.5
        case .bend: return 2
        case .silhouette: return 4.5
        case .opening: return 4
        default: return 1.2
        }
    }

    /// Where the camera looks from at time `t`: turned about the vertical by `yaw`, and up by `pitch`.
    public func view(at t: Double) -> (yaw: Float, pitch: Float) {
        let phase = Float(t / duration) * 2 * .pi
        switch self {
        case .loops, .sprout, .reducingTube: return (Float(t / duration) * 2 * .pi * 0.25 + 0.5, 0.35)
        case .flow: return (0.35 * sin(phase), 0.15)
        case .bend: return (0.35, 0.2)
        case .poles, .reductions, .density: return (0.18 * sin(phase), 0.12)
        case .opening: return (0.55 * sin(phase), 0.2)
        case .silhouette: return (0.25 + 0.1 * sin(phase), 0.3)
        }
    }

    public func frame(at time: Double) -> ExampleFrame {
        let t = time.truncatingRemainder(dividingBy: duration)
        switch self {
        case .loops: return Self.loops(t)
        case .flow: return Self.horn(t)
        case .bend: return Self.bend(t)
        case .poles: return Self.poles(t)
        case .sprout: return Self.sprout(t)
        case .opening: return Self.opening(t)
        case .reductions: return Self.reductions(t)
        case .reducingTube: return Self.reducingTube(t)
        case .density: return Self.density(t)
        case .silhouette: return Self.silhouette(t)
        }
    }

    /// A box around every frame, so the camera can hold still while the mesh moves.
    public var bounds: AABB {
        var box = AABB.empty
        for i in 0..<12 {
            box.grow(frame(at: duration * Double(i) / 12).mesh.bounds)
        }
        return box
    }

    // MARK: The examples

    /// A tube with a loop going around it, then one running along it.
    private static func loops(_ t: Double) -> ExampleFrame {
        let sides = 12
        var b = Builder()
        let rings = (0..<9).map { r in
            ring(sides: sides) { Vec3(0.5 * cos($0), -1.2 + 0.3 * Float(r), 0.5 * sin($0)) }
        }
        let ids = rings.map { b.points($0) }
        b.bridge(ids, wraps: true)
        var pick = Selection()
        if t < 3.5 {
            let r = 1 + Int(t / 0.5) % 7
            pick.edges = b.edges(along: ids[r], closed: true)
        } else {
            let c = Int((t - 3.5) / 0.45) % sides
            pick.edges = b.edges(along: ids.map { $0[c] }, closed: false)
        }
        b.orientOut()
        return ExampleFrame(mesh: b.mesh, highlight: pick)
    }

    /// A curved horn, with its loops running around it and following the curve.
    private static func horn(_ t: Double) -> ExampleFrame {
        let count = 14, sides = 12
        var b = Builder()
        let ids = (0..<count).map { r -> [VertexID] in
            let s = Float(r) / Float(count - 1)
            let a = s * 1.7
            let spine = Vec3(1.3 * (1 - cos(a)), 1.3 * sin(a), 0)
            let normal = Vec3(cos(a), -sin(a), 0)
            let radius = 0.45 * (1 - 0.82 * s)
            return b.points(ring(sides: sides) { spine + radius * (cos($0) * normal + sin($0) * Vec3(0, 0, 1)) })
        }
        b.bridge(ids, wraps: true)
        var pick = Selection()
        pick.edges = b.edges(along: ids[Int(t / 0.3) % count], closed: true)
        b.orientOut()
        return ExampleFrame(mesh: b.mesh, highlight: pick)
    }

    /// A tube with three loops at its middle, bending there and straightening again.
    private static func bend(_ t: Double) -> ExampleFrame {
        let along: [Float] = [-1.2, -0.85, -0.5, -0.2, 0, 0.2, 0.5, 0.85, 1.2]
        let angle = Float(1.65 * (0.5 - 0.5 * cos(2 * .pi * t / 4)))
        var b = Builder()
        let ids = along.map { s in
            b.points(ring(sides: 12) { bent(Vec3(0.32 * cos($0), s, 0.32 * sin($0)), angle: angle, halfWidth: 0.3) })
        }
        b.bridge(ids, wraps: true)
        var pick = Selection()
        for r in 3...5 { pick.edges.formUnion(b.edges(along: ids[r], closed: true)) }
        b.orientOut()
        return ExampleFrame(mesh: b.mesh, highlight: pick)
    }

    /// Bends a straight tube along y, over `-halfWidth...halfWidth`, toward +x.
    private static func bent(_ p: Vec3, angle: Float, halfWidth w: Float) -> Vec3 {
        guard angle > 1e-4, p.y > -w else { return p }
        let radius = 2 * w / angle
        let phi = min(p.y + w, 2 * w) / (2 * w) * angle
        let r = radius - p.x
        var out = Vec3(radius - r * cos(phi), -w + r * sin(phi), p.z)
        if p.y > w { out += (p.y - w) * Vec3(sin(angle), cos(angle), 0) }
        return out
    }

    /// Two flat disks, one around an N-pole and one around an E-pole, with loops circling each.
    private static func poles(_ t: Double) -> ExampleFrame {
        var b = Builder()
        let level = 1 + Int(t / 0.5) % 3
        var pick = Selection()
        let n = poleDisk(&b, sectors: 3, center: Vec3(-1.25, 0, 0), level: level)
        let e = poleDisk(&b, sectors: 5, center: Vec3(1.25, 0, 0), level: level)
        pick.edges = n.ring.union(e.ring)
        pick.vertices = [n.center]
        b.orient { _ in Vec3(0, 0, 1) }
        return ExampleFrame(mesh: b.mesh, highlight: pick)
    }

    /// A disk made of `sectors` quad patches meeting at its center, so the center is a pole with
    /// that many edges. Returns the center and the edges of the loop `level` steps out from it.
    private static func poleDisk(_ b: inout Builder, sectors: Int, center: Vec3, level: Int) -> (center: VertexID, ring: Set<EdgeID>) {
        let n = 4, radius: Float = 1
        func onRim(_ angle: Float) -> Vec3 { center + radius * Vec3(cos(angle), sin(angle), 0) }
        var loopEdges = Set<EdgeID>()
        var middle: VertexID = -1
        for i in 0..<sectors {
            let a0 = Float(i) / Float(sectors) * 2 * .pi + .pi / 2
            let a1 = Float(i + 1) / Float(sectors) * 2 * .pi + .pi / 2
            let sA = onRim(a0), sB = onRim(a1), m = onRim((a0 + a1) / 2)
            // Rows from the center out toward A, columns toward B, meeting at the rim's middle.
            var grid: [[VertexID]] = []
            for i in 0...n {
                let u = Float(i) / Float(n)
                var row: [VertexID] = []
                for j in 0...n {
                    let v = Float(j) / Float(n)
                    let toA: Vec3 = simd_mix(center, sA, Vec3(repeating: u))
                    let toM: Vec3 = simd_mix(sB, m, Vec3(repeating: u))
                    row.append(b.point(simd_mix(toA, toM, Vec3(repeating: v))))
                }
                grid.append(row)
            }
            middle = grid[0][0]
            b.bridge(grid, wraps: false)
            loopEdges.formUnion(b.edges(along: (0...level).map { grid[level][$0] }, closed: false))
            loopEdges.formUnion(b.edges(along: (0...level).map { grid[$0][level] }, closed: false))
        }
        return (middle, loopEdges)
    }

    /// A tube coming up out of a flat panel. Four E-poles sit where they join.
    private static func sprout(_ t: Double) -> ExampleFrame {
        let cells = 6, size: Float = 0.4
        var b = Builder()
        func gridPoint(_ i: Int, _ j: Int) -> Vec3 {
            Vec3((Float(i) - Float(cells) / 2) * size, 0, (Float(j) - Float(cells) / 2) * size)
        }
        for i in 0..<cells {
            for j in 0..<cells where !((2...3).contains(i) && (2...3).contains(j)) {
                b.quad(gridPoint(i, j), gridPoint(i + 1, j), gridPoint(i + 1, j + 1), gridPoint(i, j + 1))
            }
        }
        // The edge of the hole, going around.
        let hole = [(2, 2), (3, 2), (4, 2), (4, 3), (4, 4), (3, 4), (2, 4), (2, 3)].map { gridPoint($0.0, $0.1) }
        var ids = [b.points(hole)]
        for k in 1...6 {
            let roundness = min(1, Float(k) / 2.5)
            let ringPoints = hole.map { p -> Vec3 in
                let flat = Vec2(p.x, p.z)
                let round = simd_normalize(flat) * size * 1.05
                let q = simd_mix(flat, round, Vec2(repeating: roundness)) * (1 - 0.04 * Float(k))
                return Vec3(q.x, 0.24 * Float(k), q.y)
            }
            ids.append(b.points(ringPoints))
        }
        b.bridge(ids, wraps: true)
        var pick = Selection()
        pick.edges = b.edges(along: ids[1 + Int(t / 0.35) % 6], closed: true)
        b.orient { _ in Vec3(0, 1, 0) }
        return ExampleFrame(mesh: b.mesh, highlight: pick)
    }

    /// A ball with a round opening, and two loops around it.
    private static func opening(_ t: Double) -> ExampleFrame {
        let n = 8
        var b = Builder()
        // Cube coordinates in steps of 2/n, rounded out into a ball. On the front, the grid near
        // the opening is pulled round too.
        func place(_ c: Vec3) -> Vec3 {
            var c = c
            if c.z > 0.999 {
                let r = max(abs(c.x), abs(c.y))
                let w = min(max((1 - r) / 0.75, 0), 1)
                let flat = Vec2(c.x, c.y)
                if simd_length(flat) > 1e-5 {
                    let round = simd_normalize(flat) * r
                    let q = simd_mix(flat, round, Vec2(repeating: w))
                    c.x = q.x
                    c.y = q.y
                }
            }
            return simd_normalize(c)
        }
        let axes: [(Vec3, Vec3, Vec3)] = [
            (Vec3(0, 0, 1), Vec3(1, 0, 0), Vec3(0, 1, 0)), (Vec3(0, 0, -1), Vec3(-1, 0, 0), Vec3(0, 1, 0)),
            (Vec3(1, 0, 0), Vec3(0, 0, -1), Vec3(0, 1, 0)), (Vec3(-1, 0, 0), Vec3(0, 0, 1), Vec3(0, 1, 0)),
            (Vec3(0, 1, 0), Vec3(1, 0, 0), Vec3(0, 0, -1)), (Vec3(0, -1, 0), Vec3(1, 0, 0), Vec3(0, 0, 1)),
        ]
        func cube(_ face: Int, _ i: Int, _ j: Int) -> Vec3 {
            let (normal, u, v) = axes[face]
            return normal + u * (Float(i) / Float(n) * 2 - 1) + v * (Float(j) / Float(n) * 2 - 1)
        }
        for face in 0..<6 {
            for i in 0..<n {
                for j in 0..<n {
                    if face == 0, (3...4).contains(i), (3...4).contains(j) { continue }
                    b.quad(place(cube(face, i, j)), place(cube(face, i + 1, j)), place(cube(face, i + 1, j + 1)), place(cube(face, i, j + 1)))
                }
            }
        }
        // The loops around the opening, `level` steps out from it.
        func square(_ level: Int) -> [(Int, Int)] {
            let lo = n / 2 - level, hi = n / 2 + level
            var out: [(Int, Int)] = []
            for i in lo..<hi { out.append((i, lo)) }
            for j in lo..<hi { out.append((hi, j)) }
            for i in stride(from: hi, to: lo, by: -1) { out.append((i, hi)) }
            for j in stride(from: hi, to: lo, by: -1) { out.append((lo, j)) }
            return out
        }
        var pick = Selection()
        let shown = t < 2 ? [2] : [2, 3]
        for level in shown {
            pick.edges.formUnion(b.edges(along: b.points(square(level).map { place(cube(0, $0.0, $0.1)) }), closed: true))
        }
        b.orientOut()
        return ExampleFrame(mesh: b.mesh, highlight: pick)
    }

    /// A 3-to-1 reduction and a 2-to-1 reduction, each on a flat strip.
    private static func reductions(_ t: Double) -> ExampleFrame {
        var b = Builder()
        let c: Float = 0.4
        func at(_ x: Float, _ y: Float, _ origin: Float) -> Vec3 { Vec3(origin + x * c, y * c, 0) }
        var band = Set<VertexID>()

        // 3 to 1, on the left.
        let left: Float = -2.1
        for row in 0..<2 {
            for col in 0..<3 {
                let x = Float(col), y = 2 + Float(row)
                b.quad(at(x, y, left), at(x + 1, y, left), at(x + 1, y + 1, left), at(x, y + 1, left))
            }
        }
        let a = at(1, 1, left), d = at(2, 1, left)
        b.quad(at(0, 0, left), at(3, 0, left), d, a)
        b.quad(at(0, 0, left), a, at(1, 2, left), at(0, 2, left))
        b.quad(a, d, at(2, 2, left), at(1, 2, left))
        b.quad(d, at(3, 0, left), at(3, 2, left), at(2, 2, left))
        b.quad(at(0, -3, left), at(3, -3, left), at(3, 0, left), at(0, 0, left))
        band.formUnion([b.point(a), b.point(d)])

        // 2 to 1 (four rows into two), on the right.
        let right: Float = 0.3
        for row in 0..<2 {
            for col in 0..<4 {
                let x = Float(col), y = 2 + Float(row)
                b.quad(at(x, y, right), at(x + 1, y, right), at(x + 1, y + 1, right), at(x, y + 1, right))
            }
        }
        let (p, m, q) = halving(&b) { at($0, $1, right) }
        for col in 0..<2 {
            let x = Float(col * 2)
            b.quad(at(x, -2, right), at(x + 2, -2, right), at(x + 2, 0, right), at(x, 0, right))
        }
        band.formUnion([p, m, q])

        b.orient { _ in Vec3(0, 0, 1) }
        return ExampleFrame(mesh: b.mesh, highlight: spokes(of: band, in: b.mesh, showing: t))
    }

    /// A tube going from 12 sides to 6, with three 2-to-1 reductions around it.
    private static func reducingTube(_ t: Double) -> ExampleFrame {
        var b = Builder()
        let c: Float = 0.31, wide: Float = 0.6, narrow: Float = 0.45
        // Strip coordinates, in steps of `c`: x goes around, 12 steps to the circle.
        func at(_ x: Float, _ y: Float) -> Vec3 {
            let angle = x / 12 * 2 * .pi
            let r = narrow + (wide - narrow) * min(max(y / 2, 0), 1)
            return Vec3(r * cos(angle), y * c, -r * sin(angle))
        }
        var band = Set<VertexID>()
        for k in 0..<3 {
            let o = Float(k * 4)
            for row in 0..<3 {
                for col in 0..<4 {
                    let x = o + Float(col), y = 2 + Float(row)
                    b.quad(at(x, y), at(x + 1, y), at(x + 1, y + 1), at(x, y + 1))
                }
            }
            let (p, m, q) = halving(&b) { at(o + $0, $1) }
            for col in 0..<2 {
                let x = o + Float(col * 2)
                for y in [Float(-1.5), -3] {
                    b.quad(at(x, y), at(x + 2, y), at(x + 2, y + 1.5), at(x, y + 1.5))
                }
            }
            band.formUnion([p, m, q])
        }
        b.orientOut()
        return ExampleFrame(mesh: b.mesh, highlight: spokes(of: band, in: b.mesh, showing: t))
    }

    /// A 2-to-1 reduction: four columns of quads into two, over two rows, in strip steps from
    /// (0, 0) to (4, 2). An N-pole sits in the middle and an E-pole below it, so it repeats side by
    /// side with no other poles. Returns the points inside it.
    private static func halving(_ b: inout Builder, _ at: (Float, Float) -> Vec3) -> (VertexID, VertexID, VertexID) {
        let p = at(1, 1), m = at(2, 1.4), q = at(3, 1)
        let middle = [at(0, 1), p, m, q, at(4, 1)]
        for x in 0..<4 {
            b.quad(at(Float(x), 2), at(Float(x + 1), 2), middle[x + 1], middle[x])
        }
        b.quad(at(0, 1), p, at(2, 0), at(0, 0))
        b.quad(p, m, q, at(2, 0))
        b.quad(q, at(4, 1), at(4, 0), at(2, 0))
        return (b.point(p), b.point(m), b.point(q))
    }

    /// The edges out of the reductions' middle points, lit up for most of the clip.
    private static func spokes(of points: Set<VertexID>, in mesh: Mesh, showing t: Double) -> Selection {
        var pick = Selection()
        guard t.truncatingRemainder(dividingBy: 3) < 2.2 else { return pick }
        pick.vertices = points
        for v in points { pick.edges.formUnion(mesh.edgesOf(v)) }
        return pick
    }

    /// A fan of quads that stay square as they grow, a little at a time.
    private static func density(_ t: Double) -> ExampleFrame {
        let columns = 6, rows = 12
        let span: Float = 70 * .pi / 180
        let step = span / Float(columns)
        var b = Builder()
        let ids = (0...rows).map { k -> [VertexID] in
            let r = 0.22 * pow(1 + step, Float(k))
            return b.points((0...columns).map { i in
                let a = .pi / 2 - span / 2 + Float(i) * step
                return Vec3(r * cos(a), r * sin(a) - 1.2, 0)
            })
        }
        b.bridge(ids, wraps: false)
        var pick = Selection()
        pick.edges = b.edges(along: ids[1 + Int(t / 0.35) % rows], closed: false)
        b.orient { _ in Vec3(0, 0, 1) }
        return ExampleFrame(mesh: b.mesh, highlight: pick)
    }

    /// A capped cylinder with 6, then 8, then 12 sides.
    private static func silhouette(_ t: Double) -> ExampleFrame {
        let sides = t < 2 ? 6 : (t < 4 ? 8 : 12)
        var b = Builder()
        let radius: Float = 0.6, half: Float = 0.45
        let rings = [-half, 0, half].map { z in
            b.points(ring(sides: sides) { Vec3(radius * cos($0), radius * sin($0), z) })
        }
        b.bridge(rings, wraps: true)
        for (end, z) in [(rings[0], -half), (rings[2], half)] {
            cap(&b, rim: end, sides: sides, radius: radius, z: z)
        }
        b.orientOut()
        return ExampleFrame(mesh: b.mesh, highlight: Selection(), caption: "\(sides) sides")
    }

    /// Closes a ring of 6, 8 or 12 with quads.
    private static func cap(_ b: inout Builder, rim: [VertexID], sides: Int, radius: Float, z: Float) {
        if sides == 6 {
            b.face([rim[0], rim[1], rim[2], rim[3]])
            b.face([rim[3], rim[4], rim[5], rim[0]])
            return
        }
        // A 2×2 or 3×3 grid, its edge on the rim and its inside rounded out to fill the circle.
        let n = sides / 4
        let corner: Float = -3 * .pi / 4
        let offsets: [Float] = rim.map { abs(angleOf(b.mesh.positions[Int($0)]) - corner) }
        let first = offsets.indices.min { offsets[$0] < offsets[$1] } ?? 0
        var grid = [[VertexID]](repeating: [VertexID](repeating: -1, count: n + 1), count: n + 1)
        var perimeter: [(Int, Int)] = []
        for i in 0..<n { perimeter.append((i, 0)) }
        for j in 0..<n { perimeter.append((n, j)) }
        for i in stride(from: n, to: 0, by: -1) { perimeter.append((i, n)) }
        for j in stride(from: n, to: 0, by: -1) { perimeter.append((0, j)) }
        for (k, cell) in perimeter.enumerated() {
            grid[cell.0][cell.1] = rim[(first + k) % sides]
        }
        for i in 1..<n {
            for j in 1..<n {
                let u = Float(i) / Float(n) * 2 - 1, v = Float(j) / Float(n) * 2 - 1
                let disc = Vec2(u * sqrt(1 - v * v / 2), v * sqrt(1 - u * u / 2)) * radius
                grid[i][j] = b.point(Vec3(disc.x, disc.y, z))
            }
        }
        b.bridge(grid, wraps: false)
    }

    private static func angleOf(_ p: Vec3) -> Float { atan2(p.y, p.x) }

    private static func ring(sides: Int, _ point: (Float) -> Vec3) -> [Vec3] {
        (0..<sides).map { point(Float($0) / Float(sides) * 2 * .pi) }
    }
}

/// Puts a mesh together from positions, joining any that land in the same place.
private struct Builder {
    var mesh = Mesh()
    private var known: [SIMD3<Int32>: VertexID] = [:]

    mutating func point(_ p: Vec3) -> VertexID {
        let key = SIMD3<Int32>(p * 10_000, rounding: .toNearestOrAwayFromZero)
        if let id = known[key] { return id }
        let id = mesh.addVertex(p)
        known[key] = id
        return id
    }

    mutating func points(_ ps: [Vec3]) -> [VertexID] { ps.map { point($0) } }

    /// Turns the faces to face `outward`, which is given a face's middle. The renderer tints the
    /// backs of faces, so they need to face the camera.
    mutating func orient(_ outward: (Vec3) -> Vec3) {
        var score: Float = 0
        for f in mesh.aliveFaces {
            let loop = mesh.loop(f)
            let middle = loop.reduce(Vec3.zero) { $0 + mesh.positions[Int($1)] } / Float(loop.count)
            score += simd_dot(mesh.faceNormal(f), outward(middle))
        }
        if score < 0 { mesh.reverseFaces(Set(mesh.aliveFaces)) }
    }

    /// Faces pointing away from the middle of the mesh, for round shapes.
    mutating func orientOut() {
        let middle = mesh.bounds.center
        orient { $0 - middle }
    }

    mutating func face(_ loop: [VertexID]) {
        _ = try? mesh.addFace(loop)
    }

    mutating func quad(_ a: Vec3, _ b: Vec3, _ c: Vec3, _ d: Vec3) {
        face([point(a), point(b), point(c), point(d)])
    }

    /// Quads between each row and the next.
    mutating func bridge(_ rows: [[VertexID]], wraps: Bool) {
        for r in 0..<(rows.count - 1) {
            let n = rows[r].count
            for i in 0..<(wraps ? n : n - 1) {
                let j = (i + 1) % n
                face([rows[r][i], rows[r][j], rows[r + 1][j], rows[r + 1][i]])
            }
        }
    }

    func edges(along path: [VertexID], closed: Bool) -> Set<EdgeID> {
        var out = Set<EdgeID>()
        let count = closed ? path.count : path.count - 1
        for i in 0..<max(count, 0) {
            if let e = mesh.edge(between: path[i], path[(i + 1) % path.count]) { out.insert(e) }
        }
        return out
    }
}
