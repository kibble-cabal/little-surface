import Foundation

/// The state undo restores: connectivity, positions, face indices and selection all live in these two
/// value types, so restoring a snapshot can't disagree with itself.
public struct EditSnapshot {
    public var mesh: Mesh
    public var selection: Selection
    /// The geometry of every source that has been updated, so undo can go back across an update.
    public var sculpts: [UUID: SculptVersion]
    public var sketches: [SketchStroke]

    public init(mesh: Mesh, selection: Selection, sculpts: [UUID: SculptVersion] = [:], sketches: [SketchStroke] = []) {
        self.mesh = mesh
        self.selection = selection
        self.sculpts = sculpts
        self.sketches = sketches
    }
}

/// One version of a source's geometry. Its arrays are shared with the source itself until replaced.
public struct SculptVersion {
    public var positions: [Vec3]
    public var normals: [Vec3]
    public var indices: [UInt32]
    public var bvh: TriangleBVH?
    public var revision: UInt64

    var approximateBytes: Int {
        positions.count * MemoryLayout<Vec3>.stride * 2 + indices.count * MemoryLayout<UInt32>.stride
    }
}

/// Snapshot undo with a memory budget. Mesh arrays are copy-on-write, so snapshots share whatever an
/// edit didn't touch; the accounting below measures only what's actually unique to each one.
public struct EditHistory {
    public struct Entry {
        public var label: String
        public var snapshot: EditSnapshot
        var uniqueBytes: Int
    }

    public private(set) var undoStack: [Entry] = []
    public private(set) var redoStack: [Entry] = []
    public let byteBudget: Int
    public let maxEntries: Int
    /// Bumped whenever a committed change is made, undone or redone. Save state keys off this.
    public private(set) var generation: UInt64 = 0

    public init(byteBudget: Int = 192 * 1024 * 1024, maxEntries: Int = 256) {
        self.byteBudget = byteBudget
        self.maxEntries = maxEntries
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoLabel: String? { undoStack.last?.label }
    public var redoLabel: String? { redoStack.last?.label }
    public var usedBytes: Int { undoStack.reduce(0) { $0 + $1.uniqueBytes } + redoStack.reduce(0) { $0 + $1.uniqueBytes } }

    /// Records `before` as the state to return to, with `label` naming the edit that followed it.
    public mutating func record(before: EditSnapshot, label: String) {
        var bytes = before.mesh.approximateBytes(sharedWith: undoStack.last?.snapshot.mesh)
        for (id, version) in before.sculpts where undoStack.last?.snapshot.sculpts[id]?.revision != version.revision {
            bytes += version.approximateBytes
        }
        undoStack.append(Entry(label: label, snapshot: before, uniqueBytes: bytes))
        redoStack.removeAll()
        generation &+= 1
        trim()
    }

    public mutating func undo(current: EditSnapshot) -> EditSnapshot? {
        guard let entry = undoStack.popLast() else { return nil }
        let bytes = current.mesh.approximateBytes(sharedWith: entry.snapshot.mesh)
        redoStack.append(Entry(label: entry.label, snapshot: current, uniqueBytes: bytes))
        generation &+= 1
        return entry.snapshot
    }

    public mutating func redo(current: EditSnapshot) -> EditSnapshot? {
        guard let entry = redoStack.popLast() else { return nil }
        let bytes = current.mesh.approximateBytes(sharedWith: entry.snapshot.mesh)
        undoStack.append(Entry(label: entry.label, snapshot: current, uniqueBytes: bytes))
        generation &+= 1
        return entry.snapshot
    }

    public mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// Forgets the oldest undo steps until what's left fits a fraction of the budget.
    public mutating func shrink(toFractionOfBudget fraction: Double) {
        trim(to: Int(Double(byteBudget) * fraction))
    }

    private mutating func trim() { trim(to: byteBudget) }

    private mutating func trim(to budget: Int) {
        while undoStack.count > maxEntries { undoStack.removeFirst() }
        var used = usedBytes
        while used > budget && undoStack.count > 1 {
            used -= undoStack.removeFirst().uniqueBytes
        }
    }
}

extension Mesh {
    /// Rough size of this mesh's storage, leaving out arrays shared with `other`.
    func approximateBytes(sharedWith other: Mesh?) -> Int {
        func bytes<T>(_ a: [T], _ b: [T]?) -> Int {
            if let b, a.withUnsafeBufferPointer({ $0.baseAddress }) == b.withUnsafeBufferPointer({ $0.baseAddress }) { return 0 }
            return a.count * MemoryLayout<T>.stride
        }
        var total = bytes(positions, other?.positions)
        total += bytes(vertexAlive, other?.vertexAlive)
        total += bytes(mirrorPartner, other?.mirrorPartner)
        total += bytes(edgeEnds, other?.edgeEnds)
        total += bytes(edgeFaces, other?.edgeFaces)
        total += bytes(edgeAlive, other?.edgeAlive)
        total += bytes(faceAlive, other?.faceAlive)
        // Outer arrays of arrays. Their inner buffers are mostly shared and aren't counted.
        total += bytes(vertexEdges, other?.vertexEdges)
        total += bytes(faceLoops, other?.faceLoops)
        total += bytes(faceEdgeLoops, other?.faceEdgeLoops)
        if other == nil { total += faceCount * 64 + vertexCount * 48 }
        return total
    }
}
