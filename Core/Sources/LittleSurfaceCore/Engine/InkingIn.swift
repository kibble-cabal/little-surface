import simd

/// The sides of quads a stroke has just finished, for the moment they spend going from pencil to ink.
/// It's only for show: the mesh already has them straight, and the renderer draws these over the top.
public struct InkingIn {
    public struct Side {
        public var edge: EdgeID
        /// The side as it was drawn.
        public var curve: [Vec3]
        /// Where each of those points ends up on the straight side.
        public var straight: [Vec3]
    }

    public var generation = 0
    public var sides: [Side] = []
    /// A change to the mesh after the stroke leaves these out of date, so they stop being shown.
    public var topologyVersion: UInt64 = 0

    /// What's ink before a stroke, so that afterwards only what's newly ink changes.
    struct Inked {
        var pairs = Set<SIMD2<VertexID>>()
        var segments: [(Vec3, Vec3)] = []

        init(_ mesh: Mesh) {
            for e in mesh.aliveEdges where mesh.facesOf(edge: e).contains(where: mesh.isQuad) {
                let (a, b) = mesh.ends(e)
                pairs.insert(InkingIn.pair(a, b))
                segments.append((mesh.position(a), mesh.position(b)))
            }
        }

        /// A stroke crossing an inked line splits it, and the pieces are the same ink as before.
        func isPiece(from a: Vec3, to b: Vec3) -> Bool {
            let middle = (a + b) * 0.5
            let tolerance = simd_length(b - a) * 0.05
            return segments.contains { p, q in
                let line = q - p
                let t = simd_clamp(simd_dot(middle - p, line) / max(simd_length_squared(line), 1e-12), 0, 1)
                return simd_length(p + line * t - middle) <= tolerance
            }
        }
    }

    init(generation: Int, mesh: Mesh, before: Inked, straightened: [StraightenedSide]) {
        self.generation = generation
        topologyVersion = mesh.topologyVersion
        var curves: [SIMD2<VertexID>: [Vec3]] = [:]
        for side in straightened { curves[Self.pair(side.a, side.b)] = side.curve }
        for e in mesh.aliveEdges where mesh.facesOf(edge: e).contains(where: mesh.isQuad) {
            let (a, b) = mesh.ends(e)
            let pair = Self.pair(a, b)
            let pa = mesh.position(a), pb = mesh.position(b)
            guard !before.pairs.contains(pair), !before.isPiece(from: pa, to: pb) else { continue }
            var curve = curves[pair] ?? [pa, pb]
            // A side's curve runs whichever way its face did.
            if simd_length_squared(curve[0] - pa) > simd_length_squared(curve[curve.count - 1] - pa) { curve.reverse() }
            sides.append(Side(edge: e, curve: curve, straight: Self.laidOut(curve, from: pa, to: pb)))
        }
    }

    public init() {}

    /// Each point goes as far along the straight side as it had come along the curve.
    private static func laidOut(_ curve: [Vec3], from a: Vec3, to b: Vec3) -> [Vec3] {
        var along: [Float] = [0]
        for (p, q) in zip(curve, curve.dropFirst()) { along.append(along[along.count - 1] + simd_length(q - p)) }
        let total = max(along[along.count - 1], 1e-6)
        return along.map { simd_mix(a, b, Vec3(repeating: $0 / total)) }
    }

    private static func pair(_ a: VertexID, _ b: VertexID) -> SIMD2<VertexID> {
        SIMD2(min(a, b), max(a, b))
    }
}
