import Foundation
import simd

/// Polygon data as an OBJ file states it, before triangulating for display.
public struct OBJDocument {
    public struct Object {
        public var name: String
        public var faceStarts: [Int32] = [0]
        /// Corner position indices, zero-based into `positions`.
        public var faceVertices: [Int32] = []
        /// Corner normal indices, zero-based into `normals`, or -1. Parallel to `faceVertices`.
        public var faceNormals: [Int32] = []
        public var lines: [SIMD2<Int32>] = []
        public var faceCount: Int { faceStarts.count - 1 }
    }
    public var positions: [Vec3] = []
    public var normals: [Vec3] = []
    public var objects: [Object] = []
}

public enum OBJImporter {
    public static func parse(data: Data, isCancelled: () -> Bool = { false }) throws -> OBJDocument {
        var document = OBJDocument()
        var current = OBJDocument.Object(name: "Mesh")
        var sawExplicitObject = false
        var lineNumber = 0
        var corner: [(Int32, Int32)] = []

        func finishObject() {
            if current.faceCount > 0 || !current.lines.isEmpty { document.objects.append(current) }
        }

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            var i = 0

            @inline(__always) func skipSpaces() {
                while i < count, bytes[i] == 32 || bytes[i] == 9 { i += 1 }
            }
            @inline(__always) func skipLine() {
                while i < count, bytes[i] != 10 { i += 1 }
            }
            func parseFloat() -> Float? {
                skipSpaces()
                let start = i
                var negative = false
                if i < count, bytes[i] == 45 { negative = true; i += 1 } else if i < count, bytes[i] == 43 { i += 1 }
                var mantissa: Double = 0
                var digits = 0
                while i < count, bytes[i] >= 48, bytes[i] <= 57 {
                    mantissa = mantissa * 10 + Double(bytes[i] - 48)
                    i += 1
                    digits += 1
                }
                var scale: Double = 1
                if i < count, bytes[i] == 46 {
                    i += 1
                    while i < count, bytes[i] >= 48, bytes[i] <= 57 {
                        mantissa = mantissa * 10 + Double(bytes[i] - 48)
                        scale *= 10
                        i += 1
                        digits += 1
                    }
                }
                guard digits > 0 else { i = start; return nil }
                var value = mantissa / scale
                if i < count, bytes[i] == 101 || bytes[i] == 69 {
                    i += 1
                    var expNegative = false
                    if i < count, bytes[i] == 45 { expNegative = true; i += 1 } else if i < count, bytes[i] == 43 { i += 1 }
                    var e = 0
                    while i < count, bytes[i] >= 48, bytes[i] <= 57 {
                        e = e * 10 + Int(bytes[i] - 48)
                        i += 1
                    }
                    value *= pow(10, Double(expNegative ? -e : e))
                }
                return Float(negative ? -value : value)
            }
            func parseInt() -> Int? {
                let start = i
                var negative = false
                if i < count, bytes[i] == 45 { negative = true; i += 1 }
                var value = 0
                var digits = 0
                while i < count, bytes[i] >= 48, bytes[i] <= 57 {
                    value = value * 10 + Int(bytes[i] - 48)
                    i += 1
                    digits += 1
                }
                guard digits > 0 else { i = start; return nil }
                return negative ? -value : value
            }
            func restOfLine() -> String {
                skipSpaces()
                let start = i
                while i < count, bytes[i] != 10, bytes[i] != 13 { i += 1 }
                let slice = UnsafeBufferPointer(rebasing: bytes[start..<i])
                return String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            }

            while i < count {
                lineNumber += 1
                if lineNumber & 0x3FFFF == 0, isCancelled() { throw ImportError.cancelled }
                skipSpaces()
                guard i < count else { break }
                let c = bytes[i]
                let next: UInt8 = i + 1 < count ? bytes[i + 1] : 0
                if c == 118 /* v */ && (next == 32 || next == 9) {
                    i += 1
                    guard let x = parseFloat(), let y = parseFloat(), let z = parseFloat() else {
                        throw ImportError.malformed("line \(lineNumber) has an invalid vertex")
                    }
                    document.positions.append(Vec3(x, y, z))
                } else if c == 118 && next == 110 /* vn */ {
                    i += 2
                    guard let x = parseFloat(), let y = parseFloat(), let z = parseFloat() else {
                        throw ImportError.malformed("line \(lineNumber) has an invalid normal")
                    }
                    document.normals.append(Vec3(x, y, z))
                } else if c == 102 /* f */ && (next == 32 || next == 9) {
                    i += 1
                    corner.removeAll(keepingCapacity: true)
                    while true {
                        skipSpaces()
                        guard i < count, bytes[i] != 10, bytes[i] != 13 else { break }
                        guard let vi = parseInt() else {
                            throw ImportError.malformed("line \(lineNumber) has an invalid face")
                        }
                        var ni = 0
                        if i < count, bytes[i] == 47 {
                            i += 1
                            _ = parseInt() // Texture coordinates aren't needed.
                            if i < count, bytes[i] == 47 {
                                i += 1
                                ni = parseInt() ?? 0
                            }
                        }
                        let position = vi < 0 ? document.positions.count + vi : vi - 1
                        guard position >= 0, position < document.positions.count else {
                            throw ImportError.malformed("line \(lineNumber) refers to vertex \(vi), which doesn't exist")
                        }
                        let normal = ni == 0 ? -1 : (ni < 0 ? document.normals.count + ni : ni - 1)
                        corner.append((Int32(position), Int32(normal >= document.normals.count ? -1 : normal)))
                    }
                    guard corner.count >= 3 else {
                        skipLine()
                        continue
                    }
                    for (v, n) in corner {
                        current.faceVertices.append(v)
                        current.faceNormals.append(n)
                    }
                    current.faceStarts.append(Int32(current.faceVertices.count))
                } else if c == 108 /* l */ && (next == 32 || next == 9) {
                    i += 1
                    var previous: Int32 = -1
                    while true {
                        skipSpaces()
                        guard i < count, bytes[i] != 10, bytes[i] != 13, let vi = parseInt() else { break }
                        if i < count, bytes[i] == 47 {
                            i += 1
                            _ = parseInt()
                        }
                        let v = Int32(vi < 0 ? document.positions.count + vi : vi - 1)
                        if previous >= 0 { current.lines.append(SIMD2<Int32>(previous, v)) }
                        previous = v
                    }
                } else if c == 111 /* o */ && (next == 32 || next == 9) {
                    i += 1
                    let name = restOfLine()
                    finishObject()
                    current = OBJDocument.Object(name: name.isEmpty ? "Object \(document.objects.count + 1)" : name)
                    sawExplicitObject = true
                } else if c == 103 /* g */ && (next == 32 || next == 9) && !sawExplicitObject {
                    // `g` starts a new object only in files that don't use `o`.
                    i += 1
                    let name = restOfLine()
                    if current.faceCount > 0 || !current.lines.isEmpty {
                        finishObject()
                        current = OBJDocument.Object(name: name.isEmpty ? "Group \(document.objects.count + 1)" : name)
                    } else if !name.isEmpty {
                        current.name = name
                    }
                }
                skipLine()
                if i < count { i += 1 }
            }
        }
        finishObject()
        return document
    }

    public static func load(data: Data, name: String, isCancelled: () -> Bool = { false }) throws -> ImportedModel {
        let document = try parse(data: data, isCancelled: isCancelled)
        var objects: [SourceObject] = []
        var warnings: [String] = []
        for object in document.objects where object.faceCount > 0 {
            if isCancelled() { throw ImportError.cancelled }
            objects.append(buildSource(object, document: document))
        }
        let lineObjects = document.objects.filter { $0.faceCount == 0 }.count
        if lineObjects > 0 { warnings.append("Skipped \(lineObjects) line-only objects.") }
        return ImportedModel(objects: objects, warnings: warnings, name: name)
    }

    private static func buildSource(_ object: OBJDocument.Object, document: OBJDocument) -> SourceObject {
        // Each distinct position/normal pair becomes one output vertex.
        var remap = [UInt64: UInt32]()
        remap.reserveCapacity(object.faceVertices.count)
        var positions: [Vec3] = []
        var normals: [Vec3] = []
        var indices: [UInt32] = []
        indices.reserveCapacity(object.faceVertices.count * 3 / 2)
        var hasAllNormals = true

        func vertex(_ c: Int) -> UInt32 {
            let v = object.faceVertices[c], n = object.faceNormals[c]
            if n < 0 { hasAllNormals = false }
            let key = (UInt64(UInt32(bitPattern: v)) << 32) | UInt64(UInt32(bitPattern: n))
            if let found = remap[key] { return found }
            let id = UInt32(positions.count)
            positions.append(document.positions[Int(v)])
            normals.append(n >= 0 ? document.normals[Int(n)] : Vec3(repeating: 0))
            remap[key] = id
            return id
        }

        for f in 0..<object.faceCount {
            let start = Int(object.faceStarts[f]), end = Int(object.faceStarts[f + 1])
            let n = end - start
            if n == 3 {
                indices.append(vertex(start))
                indices.append(vertex(start + 1))
                indices.append(vertex(start + 2))
            } else {
                let corners = (start..<end).map { document.positions[Int(object.faceVertices[$0])] }
                for t in Triangulation.triangulate(corners) {
                    indices.append(vertex(start + Int(t.x)))
                    indices.append(vertex(start + Int(t.y)))
                    indices.append(vertex(start + Int(t.z)))
                }
            }
        }
        if hasAllNormals {
            for i in 0..<normals.count { normals[i] = GeometryMath.safeNormalize(normals[i]) }
            return SourceObject(name: object.name, positions: positions, normals: normals, indices: indices)
        }
        return SourceObject(name: object.name, positions: positions, indices: indices)
    }
}

public struct ExportOptions: Equatable, Codable {
    public var includeSource = false
    public init() {}
}

public enum OBJExporter {
    /// Writes real polygons (quads stay quads), with one smooth normal per vertex. Loose edges are
    /// written as `l` elements so nothing is silently lost. Source objects, when included, follow as
    /// separate `o` blocks.
    public static func export(mesh: Mesh, name: String, sources: [SourceObject] = [], options: ExportOptions = ExportOptions()) -> Data {
        var text = String()
        text.reserveCapacity(mesh.vertexCount * 60 + mesh.faceCount * 40)
        text += "# Little Surface retopology export\n"
        text += "# \(mesh.vertexCount) vertices, \(mesh.edgeCount) edges, \(mesh.faceCount) faces\n"
        text += "o \(sanitized(name))\n"

        var indexOf = [Int32](repeating: 0, count: mesh.positions.count)
        var next: Int32 = 1
        for v in mesh.aliveVertices {
            indexOf[Int(v)] = next
            next += 1
            let p = mesh.position(v)
            text += "v \(fmt(p.x)) \(fmt(p.y)) \(fmt(p.z))\n"
        }
        for v in mesh.aliveVertices {
            var n = mesh.vertexNormal(v)
            if simd_length_squared(n) == 0 { n = Vec3(0, 1, 0) }
            text += "vn \(fmt(n.x)) \(fmt(n.y)) \(fmt(n.z))\n"
        }
        text += "s 1\n"
        for f in mesh.aliveFaces {
            text += "f"
            for v in mesh.loop(f) {
                let i = indexOf[Int(v)]
                text += " \(i)//\(i)"
            }
            text += "\n"
        }
        for e in mesh.aliveEdges where mesh.isWire(e) {
            let (a, b) = mesh.ends(e)
            text += "l \(indexOf[Int(a)]) \(indexOf[Int(b)])\n"
        }

        if options.includeSource {
            var base = next - 1
            for source in sources {
                text += "o \(sanitized(source.name))\n"
                for p in source.positions { text += "v \(fmt(p.x)) \(fmt(p.y)) \(fmt(p.z))\n" }
                for n in source.normals { text += "vn \(fmt(n.x)) \(fmt(n.y)) \(fmt(n.z))\n" }
                var i = 0
                while i + 2 < source.indices.count {
                    let a = Int32(source.indices[i]) + base + 1
                    let b = Int32(source.indices[i + 1]) + base + 1
                    let c = Int32(source.indices[i + 2]) + base + 1
                    text += "f \(a)//\(a) \(b)//\(b) \(c)//\(c)\n"
                    i += 3
                }
                base += Int32(source.positions.count)
            }
        }
        return Data(text.utf8)
    }

    private static func sanitized(_ name: String) -> String {
        let clean = name.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? "Retopology" : clean
    }

    private static func fmt(_ value: Float) -> String {
        // Shortest round-trippable form, which keeps positions exact across save and reload.
        if value == 0 { return "0" }
        return "\(value)"
    }
}
