import Foundation
import simd

/// Immutable SAH binned BVH over one source object's triangles. Safe to query from any thread.
public final class TriangleBVH {
    struct Node {
        var lo: Vec3
        var hi: Vec3
        /// Index of the first triangle for a leaf, or the left child (right child is left + 1).
        var first: Int32
        /// Triangle count for a leaf, 0 for an interior node.
        var count: Int32
    }

    let nodes: ContiguousArray<Node>
    /// Node triangles in leaf order, as triples into the vertex arrays. Copied here for query locality.
    let triangleOrder: ContiguousArray<UInt32>
    private let positions: ContiguousArray<Vec3>
    private let normals: ContiguousArray<Vec3>
    private let indices: ContiguousArray<UInt32>

    public let bounds: AABB
    public var triangleCount: Int { triangleOrder.count }

    private static let binCount = 12
    private static let leafSize = 4

    /// Returns nil only when `isCancelled` fires during the build.
    public init?(positions: [Vec3], normals: [Vec3], indices: [UInt32], isCancelled: () -> Bool = { false }) {
        let triCount = indices.count / 3
        self.positions = ContiguousArray(positions)
        self.normals = ContiguousArray(normals)
        self.indices = ContiguousArray(indices)

        var order = ContiguousArray<UInt32>((0..<UInt32(triCount)))
        var centroids = ContiguousArray<Vec3>(repeating: Vec3(repeating: 0), count: triCount)
        var boxes = ContiguousArray<AABB>(repeating: .empty, count: triCount)
        var all = AABB.empty
        for t in 0..<triCount {
            var b = AABB.empty
            b.grow(positions[Int(indices[t * 3])])
            b.grow(positions[Int(indices[t * 3 + 1])])
            b.grow(positions[Int(indices[t * 3 + 2])])
            boxes[t] = b
            centroids[t] = b.center
            all.grow(b)
        }
        bounds = all

        var built = ContiguousArray<Node>()
        built.reserveCapacity(max(1, triCount / 2))
        built.append(Node(lo: all.minCorner, hi: all.maxCorner, first: 0, count: Int32(triCount)))

        struct Work {
            var node: Int32
            var depth: Int32
        }
        var stack: [Work] = triCount > 0 ? [Work(node: 0, depth: 0)] : []
        var processed = 0

        let binCount = TriangleBVH.binCount
        var binBoxes = [AABB](repeating: .empty, count: binCount)
        var binCounts = [Int32](repeating: 0, count: binCount)
        var rightAreas = [Float](repeating: 0, count: binCount)
        var rightCounts = [Int32](repeating: 0, count: binCount)

        while let work = stack.popLast() {
            processed += 1
            if processed & 0xFFF == 0, isCancelled() { return nil }

            let first = Int(built[Int(work.node)].first)
            let count = Int(built[Int(work.node)].count)
            if count <= TriangleBVH.leafSize || work.depth >= 60 { continue }

            var centroidBox = AABB.empty
            for i in first..<(first + count) { centroidBox.grow(centroids[Int(order[i])]) }
            let extent = centroidBox.extent

            var bestAxis = -1, bestSplit = 0
            var bestCost = Float.infinity
            for axis in 0..<3 where extent[axis] > 1e-12 {
                for b in 0..<binCount {
                    binBoxes[b] = .empty
                    binCounts[b] = 0
                }
                let scale = Float(binCount) / extent[axis]
                let origin = centroidBox.minCorner[axis]
                for i in first..<(first + count) {
                    let t = Int(order[i])
                    let b = min(binCount - 1, Int((centroids[t][axis] - origin) * scale))
                    binBoxes[b].grow(boxes[t])
                    binCounts[b] += 1
                }
                var box = AABB.empty
                var running: Int32 = 0
                for b in stride(from: binCount - 1, to: 0, by: -1) {
                    box.grow(binBoxes[b])
                    running += binCounts[b]
                    rightAreas[b] = box.isEmpty ? 0 : box.halfArea
                    rightCounts[b] = running
                }
                box = .empty
                running = 0
                for b in 0..<(binCount - 1) {
                    box.grow(binBoxes[b])
                    running += binCounts[b]
                    guard running > 0, rightCounts[b + 1] > 0 else { continue }
                    let cost = Float(running) * box.halfArea + Float(rightCounts[b + 1]) * rightAreas[b + 1]
                    if cost < bestCost {
                        bestCost = cost
                        bestAxis = axis
                        bestSplit = b
                    }
                }
            }

            var mid = first
            if bestAxis >= 0 {
                let scale = Float(binCount) / extent[bestAxis]
                let origin = centroidBox.minCorner[bestAxis]
                var lo = first, hi = first + count - 1
                while lo <= hi {
                    let t = Int(order[lo])
                    let b = min(binCount - 1, Int((centroids[t][bestAxis] - origin) * scale))
                    if b <= bestSplit {
                        lo += 1
                    } else {
                        order.swapAt(lo, hi)
                        hi -= 1
                    }
                }
                mid = lo
            }
            if mid == first || mid == first + count {
                // All centroids coincide: split down the middle so the tree still terminates.
                mid = first + count / 2
            }

            func boxOf(_ range: Range<Int>) -> AABB {
                var b = AABB.empty
                for i in range { b.grow(boxes[Int(order[i])]) }
                return b
            }
            let leftBox = boxOf(first..<mid), rightBox = boxOf(mid..<(first + count))
            let left = Int32(built.count)
            built.append(Node(lo: leftBox.minCorner, hi: leftBox.maxCorner, first: Int32(first), count: Int32(mid - first)))
            built.append(Node(lo: rightBox.minCorner, hi: rightBox.maxCorner, first: Int32(mid), count: Int32(first + count - mid)))
            built[Int(work.node)].first = left
            built[Int(work.node)].count = 0
            stack.append(Work(node: left + 1, depth: work.depth + 1))
            stack.append(Work(node: left, depth: work.depth + 1))
        }
        nodes = built
        triangleOrder = order
    }

    public convenience init?(object: SourceObject, isCancelled: () -> Bool = { false }) {
        self.init(positions: object.positions, normals: object.normals, indices: object.indices, isCancelled: isCancelled)
    }

    public struct Hit {
        public var distance: Float
        public var position: Vec3
        public var normal: Vec3
        public var triangle: Int
    }

    @inline(__always)
    private static func slabEntry(_ node: Node, origin: Vec3, inverse: Vec3, tMax: Float) -> Float {
        // A ray lying exactly in a box's face has 0 * infinity = NaN there. It counts as inside that slab.
        var t0 = (node.lo - origin) * inverse
        var t1 = (node.hi - origin) * inverse
        t0.replace(with: -.infinity, where: t0 .!= t0)
        t1.replace(with: .infinity, where: t1 .!= t1)
        let near = simd_min(t0, t1), far = simd_max(t0, t1)
        let tNear = max(near.max(), 0)
        let tFar = min(far.min(), tMax)
        // The small allowance stops rounding from opening cracks between neighbouring boxes.
        return tNear <= tFar * 1.00001 ? tNear : .infinity
    }

    /// Per-axis 1/d. Zero is always +infinity, so -0 can't turn a slab inside out.
    @inline(__always)
    private static func inverseDirection(_ d: Vec3) -> Vec3 {
        Vec3(d.x == 0 ? .infinity : 1 / d.x, d.y == 0 ? .infinity : 1 / d.y, d.z == 0 ? .infinity : 1 / d.z)
    }

    /// Nearest hit along the ray, before `tMax`.
    public func raycast(_ ray: Ray, tMax: Float = .infinity) -> Hit? {
        guard !triangleOrder.isEmpty else { return nil }
        let inverse = TriangleBVH.inverseDirection(ray.direction)
        var best = tMax
        var bestTri = -1
        var bestU: Float = 0, bestV: Float = 0

        nodes.withUnsafeBufferPointer { nodes in
        triangleOrder.withUnsafeBufferPointer { order in
        indices.withUnsafeBufferPointer { idx in
        positions.withUnsafeBufferPointer { pos in
            withUnsafeTemporaryAllocation(of: Int32.self, capacity: 128) { stack in
                guard TriangleBVH.slabEntry(nodes[0], origin: ray.origin, inverse: inverse, tMax: best) < .infinity else { return }
                var top = 0
                stack[0] = 0
                top = 1
                while top > 0 {
                    top -= 1
                    let node = nodes[Int(stack[top])]
                    if node.count > 0 {
                        let first = Int(node.first)
                        for i in first..<(first + Int(node.count)) {
                            let t = Int(order[i])
                            let a = pos[Int(idx[t * 3])], b = pos[Int(idx[t * 3 + 1])], c = pos[Int(idx[t * 3 + 2])]
                            if let hit = GeometryMath.intersectTriangle(ray, a, b, c, tMax: best) {
                                best = hit.t
                                bestTri = t
                                bestU = hit.u
                                bestV = hit.v
                            }
                        }
                    } else {
                        let left = node.first, right = node.first + 1
                        let dl = TriangleBVH.slabEntry(nodes[Int(left)], origin: ray.origin, inverse: inverse, tMax: best)
                        let dr = TriangleBVH.slabEntry(nodes[Int(right)], origin: ray.origin, inverse: inverse, tMax: best)
                        // Push the far child first so the near one is visited next.
                        if dl < dr {
                            if dr < .infinity { stack[top] = right; top += 1 }
                            if dl < .infinity { stack[top] = left; top += 1 }
                        } else {
                            if dl < .infinity { stack[top] = left; top += 1 }
                            if dr < .infinity { stack[top] = right; top += 1 }
                        }
                    }
                }
            }
        }}}}

        guard bestTri >= 0 else { return nil }
        let bary = Vec3(1 - bestU - bestV, bestU, bestV)
        return Hit(distance: best, position: ray.at(best), normal: interpolatedNormal(triangle: bestTri, bary: bary), triangle: bestTri)
    }

    /// True if anything blocks the ray before `tMax`.
    public func anyHit(_ ray: Ray, tMax: Float) -> Bool {
        raycast(ray, tMax: tMax) != nil
    }

    /// Closest surface point to `p` within `maxDistance`. When a normal hint is given, triangles whose
    /// face normal points away from it are ignored, which keeps a vertex from jumping through a thin
    /// surface to the far side.
    public func closestPoint(to p: Vec3, maxDistance: Float = .infinity, normalHint: Vec3? = nil, minDot: Float = 0) -> Hit? {
        guard !triangleOrder.isEmpty else { return nil }
        var bestSq = maxDistance.isFinite ? maxDistance * maxDistance : Float.infinity
        var bestTri = -1
        var bestPoint = p
        var bestBary = Vec3(1, 0, 0)

        nodes.withUnsafeBufferPointer { nodes in
        triangleOrder.withUnsafeBufferPointer { order in
        indices.withUnsafeBufferPointer { idx in
        positions.withUnsafeBufferPointer { pos in
            withUnsafeTemporaryAllocation(of: Int32.self, capacity: 128) { stack in
                @inline(__always) func distSq(_ n: Node) -> Float {
                    let d = simd_max(simd_max(n.lo - p, p - n.hi), Vec3(repeating: 0))
                    return simd_dot(d, d)
                }
                stack[0] = 0
                var top = 1
                while top > 0 {
                    top -= 1
                    let node = nodes[Int(stack[top])]
                    if distSq(node) > bestSq { continue }
                    if node.count > 0 {
                        let first = Int(node.first)
                        for i in first..<(first + Int(node.count)) {
                            let t = Int(order[i])
                            let a = pos[Int(idx[t * 3])], b = pos[Int(idx[t * 3 + 1])], c = pos[Int(idx[t * 3 + 2])]
                            if let hint = normalHint {
                                let n = simd_cross(b - a, c - a)
                                let len = simd_length(n)
                                if len > 1e-14 && simd_dot(n, hint) < minDot * len { continue }
                            }
                            let q = GeometryMath.closestPointOnTriangle(p, a, b, c)
                            let d = simd_length_squared(q.point - p)
                            if d < bestSq {
                                bestSq = d
                                bestTri = t
                                bestPoint = q.point
                                bestBary = q.bary
                            }
                        }
                    } else {
                        let left = node.first, right = node.first + 1
                        let dl = distSq(nodes[Int(left)]), dr = distSq(nodes[Int(right)])
                        if dl < dr {
                            if dr <= bestSq { stack[top] = right; top += 1 }
                            if dl <= bestSq { stack[top] = left; top += 1 }
                        } else {
                            if dl <= bestSq { stack[top] = left; top += 1 }
                            if dr <= bestSq { stack[top] = right; top += 1 }
                        }
                    }
                }
            }
        }}}}

        guard bestTri >= 0 else { return nil }
        return Hit(distance: sqrt(bestSq), position: bestPoint, normal: interpolatedNormal(triangle: bestTri, bary: bestBary), triangle: bestTri)
    }

    private func interpolatedNormal(triangle t: Int, bary: Vec3) -> Vec3 {
        let i0 = Int(indices[t * 3]), i1 = Int(indices[t * 3 + 1]), i2 = Int(indices[t * 3 + 2])
        let n = normals[i0] * bary.x + normals[i1] * bary.y + normals[i2] * bary.z
        if simd_length_squared(n) > 1e-10 { return simd_normalize(n) }
        return GeometryMath.safeNormalize(simd_cross(positions[i1] - positions[i0], positions[i2] - positions[i0]))
    }
}
