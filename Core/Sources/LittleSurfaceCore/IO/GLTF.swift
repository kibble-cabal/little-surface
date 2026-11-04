import Foundation
import simd

// MARK: JSON model

private struct GLTFRoot: Codable {
    struct Asset: Codable {
        var version: String
        var generator: String?
    }
    struct Scene: Codable {
        var nodes: [Int]?
        var name: String?
    }
    struct Node: Codable {
        var name: String?
        var mesh: Int?
        var skin: Int?
        var children: [Int]?
        var matrix: [Float]?
        var translation: [Float]?
        var rotation: [Float]?
        var scale: [Float]?
    }
    struct Mesh: Codable {
        var name: String?
        var primitives: [Primitive]
    }
    struct Primitive: Codable {
        var attributes: [String: Int]
        var indices: Int?
        var mode: Int?
        var extensions: [String: JSONIgnored]?
    }
    struct Accessor: Codable {
        struct Sparse: Codable {
            struct Indices: Codable {
                var bufferView: Int
                var byteOffset: Int?
                var componentType: Int
            }
            struct Values: Codable {
                var bufferView: Int
                var byteOffset: Int?
            }
            var count: Int
            var indices: Indices
            var values: Values
        }
        var bufferView: Int?
        var byteOffset: Int?
        var componentType: Int
        var normalized: Bool?
        var count: Int
        var type: String
        var min: [Float]?
        var max: [Float]?
        var sparse: Sparse?
    }
    struct BufferView: Codable {
        var buffer: Int
        var byteOffset: Int?
        var byteLength: Int
        var byteStride: Int?
        var target: Int?
    }
    struct Buffer: Codable {
        var byteLength: Int
        var uri: String?
    }

    var asset: Asset
    var scene: Int?
    var scenes: [Scene]?
    var nodes: [Node]?
    var meshes: [Mesh]?
    var accessors: [Accessor]?
    var bufferViews: [BufferView]?
    var buffers: [Buffer]?
    var extensionsUsed: [String]?
    var extensionsRequired: [String]?
}

/// Decodes to nothing, for extension payloads that only need detecting.
private struct JSONIgnored: Codable {
    init(from decoder: Decoder) throws {}
    func encode(to encoder: Encoder) throws {}
}

// MARK: Import

public enum GLTFImporter {
    private static let glbMagic: UInt32 = 0x4654_6C67
    private static let jsonChunk: UInt32 = 0x4E4F_534A
    private static let binChunk: UInt32 = 0x004E_4942

    /// Compression extensions store geometry in a form this reader can't decode. Reporting this up
    /// front is better than failing on an accessor with no data.
    private static let unsupportedExtensions: [String: String] = [
        "KHR_draco_mesh_compression": "Draco compression",
        "EXT_meshopt_compression": "Meshopt compression",
        "KHR_meshopt_compression": "Meshopt compression",
    ]

    public static func loadGLB(data: Data, name: String) throws -> ImportedModel {
        guard data.count >= 20 else { throw ImportError.malformed("it's too short to be a GLB file") }
        let magic = readUInt32(data, 0)
        guard magic == glbMagic else { throw ImportError.malformed("it doesn't start with a GLB header") }
        let version = readUInt32(data, 4)
        guard version == 2 else {
            throw ImportError.unsupportedFeature("This is a glTF \(version).0 file. Little Surface reads glTF 2.0.")
        }
        var offset = 12
        var json: Data?
        var bin: Data?
        while offset + 8 <= data.count {
            let length = Int(readUInt32(data, offset))
            let type = readUInt32(data, offset + 4)
            let start = offset + 8
            guard start + length <= data.count else { throw ImportError.malformed("a chunk runs past the end of the file") }
            let begin = data.startIndex + start
            if type == jsonChunk && json == nil { json = data.subdata(in: begin..<(begin + length)) }
            if type == binChunk && bin == nil { bin = data.subdata(in: begin..<(begin + length)) }
            offset = start + length + ((4 - length % 4) % 4)
        }
        guard let json else { throw ImportError.malformed("it has no JSON chunk") }
        return try build(json: json, bin: bin, baseURL: nil, name: name)
    }

    public static func loadGLTF(json: Data, name: String, baseURL: URL?) throws -> ImportedModel {
        try build(json: json, bin: nil, baseURL: baseURL, name: name)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    private static func build(json: Data, bin: Data?, baseURL: URL?, name: String) throws -> ImportedModel {
        let root: GLTFRoot
        do {
            root = try JSONDecoder().decode(GLTFRoot.self, from: json)
        } catch {
            throw ImportError.malformed("its glTF JSON couldn't be read")
        }
        guard root.asset.version.hasPrefix("2") else {
            throw ImportError.unsupportedFeature("This is a glTF \(root.asset.version) file. Little Surface reads glTF 2.0.")
        }
        for ext in root.extensionsRequired ?? [] {
            if let label = unsupportedExtensions[ext] {
                throw ImportError.unsupportedFeature("This model uses \(label), which Little Surface can't read yet. Re-export it from your 3D app without compression.")
            }
        }

        var buffers: [Data] = []
        for (i, buffer) in (root.buffers ?? []).enumerated() {
            if let uri = buffer.uri {
                buffers.append(try loadURI(uri, baseURL: baseURL))
            } else if i == 0, let bin {
                buffers.append(bin)
            } else {
                throw ImportError.malformed("buffer \(i) has no data")
            }
            guard buffers[i].count >= buffer.byteLength else {
                throw ImportError.malformed("buffer \(i) is shorter than it claims to be")
            }
        }

        let reader = AccessorReader(root: root, buffers: buffers)
        var objects: [SourceObject] = []
        var warnings: [String] = []
        var skippedPrimitives = 0
        var usedCompressedAttributes = false

        func visit(nodeIndex: Int, parent: Mat4, depth: Int) throws {
            guard depth < 256, let nodes = root.nodes, nodeIndex >= 0, nodeIndex < nodes.count else { return }
            let node = nodes[nodeIndex]
            let world = parent * localMatrix(node)
            if let meshIndex = node.mesh, let meshes = root.meshes, meshIndex >= 0, meshIndex < meshes.count {
                let mesh = meshes[meshIndex]
                // Skinned meshes are authored in the skeleton's space, so glTF ignores their node transform.
                let transform = node.skin != nil ? Mat4.identity : world
                for (pi, primitive) in mesh.primitives.enumerated() {
                    if primitive.extensions?.keys.contains(where: { unsupportedExtensions[$0] != nil }) == true {
                        usedCompressedAttributes = true
                        continue
                    }
                    let mode = primitive.mode ?? 4
                    guard mode == 4 || mode == 5 || mode == 6 else {
                        skippedPrimitives += 1
                        continue
                    }
                    guard let positionAccessor = primitive.attributes["POSITION"] else {
                        skippedPrimitives += 1
                        continue
                    }
                    var positions = try reader.readVec3(positionAccessor)
                    var normals: [Vec3] = []
                    if let n = primitive.attributes["NORMAL"] { normals = try reader.readVec3(n) }
                    var indices: [UInt32]
                    if let i = primitive.indices {
                        indices = try reader.readIndices(i)
                        if let bad = indices.first(where: { Int($0) >= positions.count }) {
                            throw ImportError.malformed("a triangle refers to vertex \(bad) of \(positions.count)")
                        }
                    } else {
                        indices = (0..<UInt32(positions.count)).map { $0 }
                    }
                    indices = expand(indices: indices, mode: mode)

                    positions = positions.map { transform.transformPoint($0) }
                    let linear = transform.upperLeft3x3
                    if !normals.isEmpty {
                        let normalMatrix = linear.inverse.transpose
                        normals = normals.map { GeometryMath.safeNormalize(normalMatrix * $0) }
                    }
                    // A mirroring transform turns triangles inside out; swapping restores their winding.
                    if linear.determinant < 0 {
                        var t = 0
                        while t + 2 < indices.count {
                            indices.swapAt(t + 1, t + 2)
                            t += 3
                        }
                    }
                    var objectName = node.name ?? mesh.name ?? "Mesh \(objects.count + 1)"
                    if mesh.primitives.count > 1 { objectName += " \(pi + 1)" }
                    objects.append(SourceObject(name: objectName, positions: positions, normals: normals, indices: indices))
                }
            }
            for child in node.children ?? [] { try visit(nodeIndex: child, parent: world, depth: depth + 1) }
        }

        let sceneRoots: [Int]
        if let scenes = root.scenes, !scenes.isEmpty {
            let index = root.scene ?? 0
            sceneRoots = (index >= 0 && index < scenes.count ? scenes[index] : scenes[0]).nodes ?? []
        } else {
            // No scene: treat every node that isn't anybody's child as a root.
            let children = Set((root.nodes ?? []).flatMap { $0.children ?? [] })
            sceneRoots = (0..<(root.nodes ?? []).count).filter { !children.contains($0) }
        }
        for r in sceneRoots { try visit(nodeIndex: r, parent: .identity, depth: 0) }

        if objects.isEmpty && usedCompressedAttributes {
            throw ImportError.unsupportedFeature("This model uses compressed geometry that Little Surface can't read yet. Re-export it from your 3D app without compression.")
        }
        if usedCompressedAttributes { warnings.append("Some compressed parts of this model were skipped.") }
        if skippedPrimitives > 0 { warnings.append("Skipped \(skippedPrimitives) parts that aren't triangles (points or lines).") }
        return ImportedModel(objects: objects, warnings: warnings, name: name)
    }

    private static func expand(indices: [UInt32], mode: Int) -> [UInt32] {
        switch mode {
        case 5:
            guard indices.count >= 3 else { return [] }
            var out: [UInt32] = []
            out.reserveCapacity((indices.count - 2) * 3)
            for i in 0..<(indices.count - 2) {
                if i % 2 == 0 {
                    out += [indices[i], indices[i + 1], indices[i + 2]]
                } else {
                    out += [indices[i + 1], indices[i], indices[i + 2]]
                }
            }
            return out
        case 6:
            guard indices.count >= 3 else { return [] }
            var out: [UInt32] = []
            out.reserveCapacity((indices.count - 2) * 3)
            for i in 1..<(indices.count - 1) { out += [indices[0], indices[i], indices[i + 1]] }
            return out
        default:
            return indices
        }
    }

    private static func localMatrix(_ node: GLTFRoot.Node) -> Mat4 {
        if let m = node.matrix, m.count == 16 {
            return Mat4(columns: (
                Vec4(m[0], m[1], m[2], m[3]),
                Vec4(m[4], m[5], m[6], m[7]),
                Vec4(m[8], m[9], m[10], m[11]),
                Vec4(m[12], m[13], m[14], m[15])
            ))
        }
        var out = Mat4.identity
        if let s = node.scale, s.count == 3 {
            out = Mat4(diagonal: Vec4(s[0], s[1], s[2], 1))
        }
        if let r = node.rotation, r.count == 4 {
            let q = simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3])
            out = Mat4(simd_normalize(q)) * out
        }
        if let t = node.translation, t.count == 3 {
            var translate = Mat4.identity
            translate.columns.3 = Vec4(t[0], t[1], t[2], 1)
            out = translate * out
        }
        return out
    }

    private static func loadURI(_ uri: String, baseURL: URL?) throws -> Data {
        if uri.hasPrefix("data:") {
            guard let comma = uri.firstIndex(of: ","), uri[..<comma].hasSuffix(";base64"),
                  let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])) else {
                throw ImportError.malformed("an embedded buffer can't be decoded")
            }
            return data
        }
        let name = uri.removingPercentEncoding ?? uri
        guard let baseURL, let data = try? Data(contentsOf: baseURL.appendingPathComponent(name), options: .mappedIfSafe) else {
            throw ImportError.missingExternalFile(name)
        }
        return data
    }

    private struct AccessorReader {
        let root: GLTFRoot
        let buffers: [Data]

        private func accessor(_ index: Int) throws -> GLTFRoot.Accessor {
            guard let list = root.accessors, index >= 0, index < list.count else {
                throw ImportError.malformed("an accessor index is out of range")
            }
            return list[index]
        }

        private func componentSize(_ type: Int) throws -> Int {
            switch type {
            case 5120, 5121: return 1
            case 5122, 5123: return 2
            case 5125, 5126: return 4
            default: throw ImportError.malformed("component type \(type) isn't part of glTF")
            }
        }

        private func view(_ index: Int) throws -> (buffer: Data, view: GLTFRoot.BufferView) {
            guard let views = root.bufferViews, index >= 0, index < views.count else {
                throw ImportError.malformed("a buffer view index is out of range")
            }
            let v = views[index]
            guard v.buffer >= 0, v.buffer < buffers.count else {
                throw ImportError.malformed("a buffer index is out of range")
            }
            return (buffers[v.buffer], v)
        }

        @inline(__always)
        private func component(_ raw: UnsafeRawBufferPointer, _ offset: Int, type: Int, normalized: Bool) -> Float {
            switch type {
            case 5126:
                return raw.loadUnaligned(fromByteOffset: offset, as: Float.self)
            case 5120:
                let v = Float(raw.loadUnaligned(fromByteOffset: offset, as: Int8.self))
                return normalized ? max(v / 127, -1) : v
            case 5121:
                let v = Float(raw.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
                return normalized ? v / 255 : v
            case 5122:
                let v = Float(raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))
                return normalized ? max(v / 32767, -1) : v
            case 5123:
                let v = Float(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                return normalized ? v / 65535 : v
            default:
                return Float(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
        }

        func readVec3(_ index: Int) throws -> [Vec3] {
            let a = try accessor(index)
            guard a.type == "VEC3" else { throw ImportError.malformed("a position or normal isn't a 3D vector") }
            var out = [Vec3](repeating: Vec3(repeating: 0), count: a.count)
            let size = try componentSize(a.componentType)
            let normalized = a.normalized ?? false

            if let viewIndex = a.bufferView {
                let (buffer, v) = try view(viewIndex)
                let stride = v.byteStride ?? (size * 3)
                let start = (v.byteOffset ?? 0) + (a.byteOffset ?? 0)
                let needed = a.count > 0 ? start + stride * (a.count - 1) + size * 3 : start
                guard needed <= buffer.count else { throw ImportError.malformed("an accessor runs past the end of its buffer") }
                buffer.withUnsafeBytes { raw in
                    for i in 0..<a.count {
                        let o = start + i * stride
                        out[i] = Vec3(
                            component(raw, o, type: a.componentType, normalized: normalized),
                            component(raw, o + size, type: a.componentType, normalized: normalized),
                            component(raw, o + size * 2, type: a.componentType, normalized: normalized)
                        )
                    }
                }
            }
            if let sparse = a.sparse {
                let (indexBuffer, indexView) = try view(sparse.indices.bufferView)
                let (valueBuffer, valueView) = try view(sparse.values.bufferView)
                let indexSize = try componentSize(sparse.indices.componentType)
                let indexStart = (indexView.byteOffset ?? 0) + (sparse.indices.byteOffset ?? 0)
                let valueStart = (valueView.byteOffset ?? 0) + (sparse.values.byteOffset ?? 0)
                guard indexStart + indexSize * sparse.count <= indexBuffer.count, valueStart + size * 3 * sparse.count <= valueBuffer.count else {
                    throw ImportError.malformed("sparse data runs past the end of its buffer")
                }
                indexBuffer.withUnsafeBytes { rawIndices in
                    valueBuffer.withUnsafeBytes { rawValues in
                        for s in 0..<sparse.count {
                            let target = Int(component(rawIndices, indexStart + s * indexSize, type: sparse.indices.componentType, normalized: false))
                            guard target < out.count else { continue }
                            let o = valueStart + s * size * 3
                            out[target] = Vec3(
                                component(rawValues, o, type: a.componentType, normalized: normalized),
                                component(rawValues, o + size, type: a.componentType, normalized: normalized),
                                component(rawValues, o + size * 2, type: a.componentType, normalized: normalized)
                            )
                        }
                    }
                }
            }
            return out
        }

        func readIndices(_ index: Int) throws -> [UInt32] {
            let a = try accessor(index)
            guard a.type == "SCALAR", let viewIndex = a.bufferView else {
                throw ImportError.malformed("an index list isn't readable")
            }
            let (buffer, v) = try view(viewIndex)
            let size = try componentSize(a.componentType)
            let stride = v.byteStride ?? size
            let start = (v.byteOffset ?? 0) + (a.byteOffset ?? 0)
            guard start + stride * max(a.count - 1, 0) + size <= buffer.count else {
                throw ImportError.malformed("an index list runs past the end of its buffer")
            }
            var out = [UInt32](repeating: 0, count: a.count)
            buffer.withUnsafeBytes { raw in
                for i in 0..<a.count {
                    let o = start + i * stride
                    switch a.componentType {
                    case 5121: out[i] = UInt32(raw.loadUnaligned(fromByteOffset: o, as: UInt8.self))
                    case 5123: out[i] = UInt32(raw.loadUnaligned(fromByteOffset: o, as: UInt16.self))
                    default: out[i] = raw.loadUnaligned(fromByteOffset: o, as: UInt32.self)
                    }
                }
            }
            return out
        }
    }
}

// MARK: Export

public enum GLBExporter {
    /// Writes a self-contained GLB with the triangulated retopology mesh as its own node. The editable
    /// topology in the project isn't changed by this. Source objects, when included, are separate nodes.
    public static func export(mesh: Mesh, name: String, sources: [SourceObject] = [], options: ExportOptions = ExportOptions()) -> Data {
        var parts: [(name: String, data: TriangleMeshData)] = [(name.isEmpty ? "Retopology" : name, mesh.triangulated())]
        if options.includeSource {
            for source in sources {
                var data = TriangleMeshData()
                data.positions = source.positions
                data.normals = source.normals
                data.indices = source.indices
                parts.append((source.name, data))
            }
        }
        return encode(parts: parts)
    }

    static func encode(parts: [(name: String, data: TriangleMeshData)]) -> Data {
        var bin = Data()
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []
        var meshes: [[String: Any]] = []
        var nodes: [[String: Any]] = []

        func appendView<T>(_ array: [T], target: Int) -> Int {
            while bin.count % 4 != 0 { bin.append(0) }
            let offset = bin.count
            array.withUnsafeBytes { bin.append(contentsOf: $0) }
            bufferViews.append(["buffer": 0, "byteOffset": offset, "byteLength": bin.count - offset, "target": target])
            return bufferViews.count - 1
        }

        for part in parts where !part.data.indices.isEmpty {
            // Tightly packed float triples: SIMD3<Float> would carry a padding word.
            var packedPositions = [Float]()
            packedPositions.reserveCapacity(part.data.positions.count * 3)
            var lo = Vec3(repeating: .infinity), hi = Vec3(repeating: -.infinity)
            for p in part.data.positions {
                packedPositions += [p.x, p.y, p.z]
                lo = simd_min(lo, p)
                hi = simd_max(hi, p)
            }
            var packedNormals = [Float]()
            packedNormals.reserveCapacity(part.data.normals.count * 3)
            for n in part.data.normals { packedNormals += [n.x, n.y, n.z] }

            let positionView = appendView(packedPositions, target: 34962)
            accessors.append([
                "bufferView": positionView, "componentType": 5126, "count": part.data.positions.count, "type": "VEC3",
                "min": [Double(lo.x), Double(lo.y), Double(lo.z)], "max": [Double(hi.x), Double(hi.y), Double(hi.z)],
            ])
            let positionAccessor = accessors.count - 1

            let normalView = appendView(packedNormals, target: 34962)
            accessors.append(["bufferView": normalView, "componentType": 5126, "count": part.data.normals.count, "type": "VEC3"])
            let normalAccessor = accessors.count - 1

            let indexView = appendView(part.data.indices, target: 34963)
            accessors.append(["bufferView": indexView, "componentType": 5125, "count": part.data.indices.count, "type": "SCALAR"])
            let indexAccessor = accessors.count - 1

            meshes.append([
                "name": part.name,
                "primitives": [["attributes": ["POSITION": positionAccessor, "NORMAL": normalAccessor], "indices": indexAccessor, "mode": 4]],
            ])
            nodes.append(["name": part.name, "mesh": meshes.count - 1])
        }
        while bin.count % 4 != 0 { bin.append(0) }

        var root: [String: Any] = [
            "asset": ["version": "2.0", "generator": "Little Surface"],
            "scene": 0,
            "scenes": [["nodes": Array(0..<nodes.count)]],
        ]
        if !nodes.isEmpty {
            root["nodes"] = nodes
            root["meshes"] = meshes
            root["accessors"] = accessors
            root["bufferViews"] = bufferViews
            root["buffers"] = [["byteLength": bin.count]]
        }
        var json = (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data("{}".utf8)
        while json.count % 4 != 0 { json.append(0x20) }

        var out = Data()
        func put(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        let total = 12 + 8 + json.count + (bin.isEmpty ? 0 : 8 + bin.count)
        put(0x4654_6C67)
        put(2)
        put(UInt32(total))
        put(UInt32(json.count))
        put(0x4E4F_534A)
        out.append(json)
        if !bin.isEmpty {
            put(UInt32(bin.count))
            put(0x004E_4942)
            out.append(bin)
        }
        return out
    }
}
