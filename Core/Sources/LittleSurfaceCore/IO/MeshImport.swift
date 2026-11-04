import Foundation
import simd

/// A mesh from another app, ready to keep editing: its faces stay as the file states them, rather than
/// becoming triangles to draw on.
public struct ImportedMesh {
    public var mesh = Mesh()
    public var name: String
    /// Faces the mesh can't hold, such as a third face on one edge, or a face that repeats a corner.
    public var skippedFaces = 0
    /// Points that sat exactly on top of another, which some formats split along seams.
    public var weldedVertices = 0
    /// The file's format only stores triangles, so any quads it came from are gone.
    public var isTriangleFormat = false
}

public enum MeshImporter {
    /// Past this it's a sculpt rather than topology, and editing it face by face wouldn't be usable.
    public static let faceLimit = 200_000

    public static func load(url: URL, isCancelled: @escaping () -> Bool = { false }) throws -> ImportedMesh {
        let ext = url.pathExtension.lowercased()
        let name = url.deletingPathExtension().lastPathComponent
        if ext == "obj" {
            let document = try OBJImporter.parse(data: Data(contentsOf: url, options: .mappedIfSafe), isCancelled: isCancelled)
            return try build(document, name: name, isCancelled: isCancelled)
        }
        let model = try ModelImporter.load(url: url, isCancelled: isCancelled)
        var document = OBJDocument()
        for source in model.objects {
            let base = Int32(document.positions.count)
            document.positions.append(contentsOf: source.positions)
            var object = OBJDocument.Object(name: source.name)
            for i in 0..<source.triangleCount {
                for corner in 0..<3 { object.faceVertices.append(base + Int32(source.indices[i * 3 + corner])) }
                object.faceStarts.append(Int32(object.faceVertices.count))
            }
            document.objects.append(object)
        }
        var out = try build(document, name: name, isCancelled: isCancelled)
        out.isTriangleFormat = true
        return out
    }

    /// Builds the mesh. A face that can't be added is left out and counted, so that a messy file still
    /// opens with everything that's usable in it.
    public static func build(_ document: OBJDocument, name: String, isCancelled: () -> Bool = { false }) throws -> ImportedMesh {
        let faceTotal = document.objects.reduce(0) { $0 + $1.faceCount }
        guard faceTotal <= faceLimit else {
            throw ImportError.unsupportedFeature("This file has \(faceTotal.formatted()) faces, which is a sculpt rather than a mesh to edit by hand. Import it as a model to draw on instead.")
        }
        let lineTotal = document.objects.reduce(0) { $0 + $1.lines.count }
        guard faceTotal + lineTotal > 0 else { throw ImportError.noGeometry }

        var out = ImportedMesh(name: name)
        let cell = max(AABB(points: document.positions).diagonal, 1e-6) * 1e-6
        var byPosition: [SIMD3<Int64>: VertexID] = [:]
        var made = [VertexID](repeating: invalidID, count: document.positions.count)

        /// The mesh vertex for a file position. Only what the file's faces and lines use gets one.
        func vertex(_ index: Int32) throws -> VertexID {
            guard index >= 0, Int(index) < made.count else { throw ImportError.malformed("a face refers to a point that doesn't exist") }
            if made[Int(index)] != invalidID { return made[Int(index)] }
            let p = document.positions[Int(index)]
            let q = p / cell
            let key = SIMD3<Int64>(Int64(q.x.rounded()), Int64(q.y.rounded()), Int64(q.z.rounded()))
            if let found = byPosition[key] {
                made[Int(index)] = found
                out.weldedVertices += 1
                return found
            }
            let v = out.mesh.addVertex(p)
            byPosition[key] = v
            made[Int(index)] = v
            return v
        }

        for object in document.objects {
            for f in 0..<object.faceCount {
                if f % 4096 == 0, isCancelled() { throw ImportError.cancelled }
                let start = Int(object.faceStarts[f]), end = Int(object.faceStarts[f + 1])
                let loop = try (start..<end).map { try vertex(object.faceVertices[$0]) }
                do {
                    // The file's winding is the artist's, so it's kept as stated.
                    _ = try out.mesh.addFace(loop, autoOrient: false)
                } catch is MeshError {
                    out.skippedFaces += 1
                }
            }
            for line in object.lines {
                let a = try vertex(line.x), b = try vertex(line.y)
                if a != b { _ = try out.mesh.ensureEdge(a, b) }
            }
        }
        // Corners of faces that were all skipped would otherwise be left floating.
        out.mesh.deleteVertices(Set(out.mesh.aliveVertices.filter { out.mesh.edgesOf($0).isEmpty }))
        guard !out.mesh.isEmpty else { throw ImportError.noGeometry }
        return out
    }
}

extension Mesh {
    /// Adds a copy of all of `other`, as a separate part of this mesh.
    public mutating func append(_ other: Mesh) throws {
        var map = [VertexID](repeating: invalidID, count: other.positions.count)
        for v in other.aliveVertices { map[Int(v)] = addVertex(other.position(v)) }
        for f in other.aliveFaces {
            _ = try addFace(other.loop(f).map { map[Int($0)] }, autoOrient: false)
        }
        for e in other.aliveEdges where other.isWire(e) {
            let (a, b) = other.ends(e)
            _ = try ensureEdge(map[Int(a)], map[Int(b)])
        }
    }

    /// The faces as one triangulated object, to use as a surface.
    public func asSurface(named name: String) -> SourceObject {
        var slots = [Int32](repeating: -1, count: positions.count)
        var points: [Vec3] = []
        var indices: [UInt32] = []
        for f in aliveFaces {
            let corners = loop(f)
            for v in corners where slots[Int(v)] < 0 {
                slots[Int(v)] = Int32(points.count)
                points.append(position(v))
            }
            for t in Triangulation.triangulate(corners.map(position)) {
                indices.append(UInt32(slots[Int(corners[Int(t.x)])]))
                indices.append(UInt32(slots[Int(corners[Int(t.y)])]))
                indices.append(UInt32(slots[Int(corners[Int(t.z)])]))
            }
        }
        return SourceObject(name: name, positions: points, indices: indices)
    }
}
