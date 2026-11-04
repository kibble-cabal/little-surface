import Foundation
import simd

public enum DisplayMode: String, Codable, CaseIterable {
    case solid, wireframe, xray

    public var label: String {
        switch self {
        case .solid: return "Solid"
        case .wireframe: return "Wireframe"
        case .xray: return "X-ray"
        }
    }
}

public enum SubdivisionDisplay: String, Codable, CaseIterable {
    case cage, smooth, both

    public var label: String {
        switch self {
        case .cage: return "Control cage"
        case .smooth: return "Subdivided"
        case .both: return "Both"
        }
    }
}

public struct ViewportSettings: Codable, Equatable {
    public var displayMode = DisplayMode.solid
    public var showSource = true
    public var showRetopology = true
    public var sourceOpacity: Float = 1
    public var faceOpacity: Float = 0.45
    public var lightIntensity: Float = 1
    public var lightAzimuth: Float = 0.6
    public var lightElevation: Float = 0.7
    /// Viewport background brightness. Nil follows the app's light or dark appearance.
    public var backgroundLevel: Float?
    public var subdivisionPreview = false
    public var subdivisionLevels = 1
    public var subdivisionDisplay = SubdivisionDisplay.both
    public init() {}
}

public struct ToolSettings: Codable, Equatable {
    public var stroke = StrokeSettings()
    public var strip = QuadStripParameters()
    public var patch = QuadPatchParameters()
    public var brush = BrushSettings()
    public var surfaceSnapping = true
    public var surfaceOffset: Float = 0
    public var extrudeDistance: Float = 0.05
    public init() {}
}

public struct CameraState: Codable, Equatable {
    public var target: Vec3
    public var distance: Float
    public var orientation: Vec4
    public var projection: ProjectionMode
    public var sceneRadius: Float

    public init(_ camera: Camera) {
        target = camera.target
        distance = camera.distance
        orientation = camera.orientation.vector
        projection = camera.projection
        sceneRadius = camera.sceneRadius
    }

    public func applied(to base: Camera) -> Camera {
        var out = base
        out.target = target
        out.distance = distance
        out.orientation = simd_quatf(vector: orientation)
        out.projection = projection
        out.sceneRadius = sceneRadius
        return out
    }
}

/// Everything that's saved. Value types throughout, so taking one on the main thread is instant and
/// encoding can run in the background.
public struct ProjectSnapshot {
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var sources: [SourceObject]
    public var mesh: Mesh
    public var selection: Selection
    public var camera: CameraState
    public var symmetry: SymmetrySettings
    public var viewport: ViewportSettings
    public var tools: ToolSettings
    public var activeTool: Tool
    public var patchChains: [BoundaryChain]
    public var faceBuilderVertices: [VertexID]

    public init(name: String) {
        self.name = name
        createdAt = Date()
        modifiedAt = createdAt
        sources = []
        mesh = Mesh()
        selection = Selection()
        camera = CameraState(Camera())
        symmetry = SymmetrySettings()
        viewport = ViewportSettings()
        tools = ToolSettings()
        activeTool = .drawEdges
        patchChains = []
        faceBuilderVertices = []
    }
}

public enum ProjectFileError: LocalizedError, Equatable {
    case notAProject
    case newerVersion(Int)
    case damaged(String)

    public var errorDescription: String? {
        switch self {
        case .notAProject: return "This isn't a Little Surface project."
        case .newerVersion(let v): return "This project was saved by a newer version of Little Surface (format \(v)). Update the app to open it."
        case .damaged(let detail): return "This project file is damaged: \(detail)."
        }
    }
}

/// The on-disk format:
///
///     8 bytes   magic "LSURFACE"
///     u32       format version
///     u32       chunk count
///     chunks:   4-byte tag, u32 flags (1 = LZFSE), u64 stored length, u64 raw length, data
///
/// `META` holds settings as JSON, `MESH` the editable topology, and each `SRC ` one source object.
/// Readers skip unknown chunks and missing JSON keys take defaults, so the format can grow without
/// breaking older projects. A bump in the version is only needed for changes older readers can't
/// safely skip.
public enum ProjectCodec {
    public static let currentVersion: UInt32 = 1
    private static let magic = Data("LSURFACE".utf8)

    private struct SourceMeta: Codable {
        var id: UUID
        var name: String
        var isVisible: Bool
        var isSnapTarget: Bool
    }

    private struct Meta: Codable {
        var name: String
        var createdAt: Date
        var modifiedAt: Date
        var sources: [SourceMeta]
        var camera: CameraState
        var symmetry: SymmetrySettings
        var viewport: ViewportSettings
        var tools: ToolSettings
        var activeTool: Tool
        var selectionMode: SelectionMode
        var selectedVertices: [VertexID]
        var selectedEdges: [EdgeID]
        var selectedFaces: [FaceID]
        var patchChains: [BoundaryChain]
        var faceBuilderVertices: [VertexID]
    }

    // MARK: Encode

    public static func encode(_ snapshot: ProjectSnapshot) throws -> Data {
        let meta = Meta(
            name: snapshot.name,
            createdAt: snapshot.createdAt,
            modifiedAt: snapshot.modifiedAt,
            sources: snapshot.sources.map { SourceMeta(id: $0.id, name: $0.name, isVisible: $0.isVisible, isSnapTarget: $0.isSnapTarget) },
            camera: snapshot.camera,
            symmetry: snapshot.symmetry,
            viewport: snapshot.viewport,
            tools: snapshot.tools,
            activeTool: snapshot.activeTool,
            selectionMode: snapshot.selection.mode,
            selectedVertices: snapshot.selection.vertices.sorted(),
            selectedEdges: snapshot.selection.edges.sorted(),
            selectedFaces: snapshot.selection.faces.sorted(),
            patchChains: snapshot.patchChains,
            faceBuilderVertices: snapshot.faceBuilderVertices
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        var chunks: [(tag: String, data: Data)] = []
        chunks.append(("META", try encoder.encode(meta)))
        chunks.append(("MESH", encodeMesh(snapshot.mesh)))
        for source in snapshot.sources { chunks.append(("SRC ", encodeSource(source))) }

        var out = Data()
        out.append(magic)
        appendValue(&out, currentVersion)
        appendValue(&out, UInt32(chunks.count))
        for chunk in chunks {
            let compressed = try? (chunk.data as NSData).compressed(using: .lzfse) as Data
            let useCompressed = (compressed?.count ?? .max) < chunk.data.count
            let stored = useCompressed ? compressed! : chunk.data
            out.append(Data(chunk.tag.utf8))
            appendValue(&out, UInt32(useCompressed ? 1 : 0))
            appendValue(&out, UInt64(stored.count))
            appendValue(&out, UInt64(chunk.data.count))
            out.append(stored)
        }
        return out
    }

    private static func appendValue<T>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }

    private static func appendArray<T>(_ data: inout Data, _ array: [T]) {
        appendValue(&data, UInt64(array.count))
        array.withUnsafeBytes { data.append(contentsOf: $0) }
    }

    private static func encodeSource(_ source: SourceObject) -> Data {
        var out = Data()
        out.reserveCapacity(source.positions.count * 32 + source.indices.count * 4 + 64)
        // SIMD3 is stored at full stride: this keeps the code simple, and LZFSE removes the padding.
        appendArray(&out, source.positions)
        appendArray(&out, source.normals)
        appendArray(&out, source.indices)
        return out
    }

    private static func encodeMesh(_ mesh: Mesh) -> Data {
        var out = Data()
        appendArray(&out, mesh.positions)
        appendArray(&out, mesh.vertexAlive.map { UInt8($0 ? 1 : 0) })
        appendArray(&out, mesh.mirrorPartner)
        appendArray(&out, mesh.edgeEnds)
        appendArray(&out, mesh.edgeAlive.map { UInt8($0 ? 1 : 0) })

        // Faces are flattened: a live flag per slot, and the corners of live faces in slot order.
        // Connectivity beyond this is derived on load, but it's written as stated so that slot IDs,
        // and with them the saved selection, survive exactly.
        appendArray(&out, mesh.faceAlive.map { UInt8($0 ? 1 : 0) })
        var sizes = [Int32]()
        var corners = [Int32]()
        var cornerEdges = [Int32]()
        sizes.reserveCapacity(mesh.faceLoops.count)
        for f in 0..<mesh.faceLoops.count {
            sizes.append(Int32(mesh.faceLoops[f].count))
            corners.append(contentsOf: mesh.faceLoops[f])
            cornerEdges.append(contentsOf: mesh.faceEdgeLoops[f])
        }
        appendArray(&out, sizes)
        appendArray(&out, corners)
        appendArray(&out, cornerEdges)
        return out
    }

    // MARK: Decode

    public static func decode(_ data: Data, isCancelled: () -> Bool = { false }) throws -> ProjectSnapshot {
        guard data.count >= 16, data.prefix(8) == magic else { throw ProjectFileError.notAProject }
        var reader = BinaryReader(data: data, offset: 8)
        let version: UInt32 = try reader.value()
        guard version <= currentVersion else { throw ProjectFileError.newerVersion(Int(version)) }
        let count: UInt32 = try reader.value()

        var metaData: Data?
        var meshData: Data?
        var sourceData: [Data] = []
        for _ in 0..<count {
            if isCancelled() { throw ImportError.cancelled }
            let tag = String(decoding: try reader.bytes(4), as: UTF8.self)
            let flags: UInt32 = try reader.value()
            let storedLength: UInt64 = try reader.value()
            let rawLength: UInt64 = try reader.value()
            let stored = try reader.bytes(Int(storedLength))
            var chunk: Data
            if flags & 1 != 0 {
                guard let raw = try? (stored as NSData).decompressed(using: .lzfse) as Data else {
                    throw ProjectFileError.damaged("a section couldn't be decompressed")
                }
                chunk = raw
            } else {
                chunk = stored
            }
            guard chunk.count == Int(rawLength) else { throw ProjectFileError.damaged("a section has the wrong length") }
            chunk = Data(chunk)
            switch tag {
            case "META": metaData = chunk
            case "MESH": meshData = chunk
            case "SRC ": sourceData.append(chunk)
            default: break
            }
        }
        guard let metaData, let meshData else { throw ProjectFileError.damaged("a required section is missing") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meta: Meta
        do {
            meta = try decoder.decode(Meta.self, from: metaData)
        } catch {
            throw ProjectFileError.damaged("its settings couldn't be read")
        }
        guard meta.sources.count == sourceData.count else { throw ProjectFileError.damaged("a source model is missing") }

        var snapshot = ProjectSnapshot(name: meta.name)
        snapshot.createdAt = meta.createdAt
        snapshot.modifiedAt = meta.modifiedAt
        snapshot.camera = meta.camera
        snapshot.symmetry = meta.symmetry
        snapshot.viewport = meta.viewport
        snapshot.tools = meta.tools
        snapshot.activeTool = meta.activeTool
        snapshot.patchChains = meta.patchChains
        snapshot.faceBuilderVertices = meta.faceBuilderVertices
        snapshot.mesh = try decodeMesh(meshData)
        for (info, chunk) in zip(meta.sources, sourceData) {
            if isCancelled() { throw ImportError.cancelled }
            var r = BinaryReader(data: chunk, offset: 0)
            let positions: [Vec3] = try r.array()
            let normals: [Vec3] = try r.array()
            let indices: [UInt32] = try r.array()
            var object = SourceObject(id: info.id, name: info.name, positions: positions, normals: normals, indices: indices)
            object.isVisible = info.isVisible
            object.isSnapTarget = info.isSnapTarget
            snapshot.sources.append(object)
        }
        snapshot.selection.mode = meta.selectionMode
        snapshot.selection.vertices = Set(meta.selectedVertices)
        snapshot.selection.edges = Set(meta.selectedEdges)
        snapshot.selection.faces = Set(meta.selectedFaces)
        snapshot.selection.prune(in: snapshot.mesh)
        return snapshot
    }

    private static func decodeMesh(_ data: Data) throws -> Mesh {
        var r = BinaryReader(data: data, offset: 0)
        var mesh = Mesh()
        mesh.positions = try r.array()
        let vertexAlive: [UInt8] = try r.array()
        mesh.vertexAlive = vertexAlive.map { $0 != 0 }
        mesh.mirrorPartner = try r.array()
        mesh.edgeEnds = try r.array()
        let edgeAlive: [UInt8] = try r.array()
        mesh.edgeAlive = edgeAlive.map { $0 != 0 }
        let faceAlive: [UInt8] = try r.array()
        mesh.faceAlive = faceAlive.map { $0 != 0 }
        let sizes: [Int32] = try r.array()
        let corners: [Int32] = try r.array()
        let cornerEdges: [Int32] = try r.array()

        guard mesh.positions.count == mesh.vertexAlive.count, mesh.positions.count == mesh.mirrorPartner.count,
              mesh.edgeEnds.count == mesh.edgeAlive.count, mesh.faceAlive.count == sizes.count, corners.count == cornerEdges.count else {
            throw ProjectFileError.damaged("the mesh tables disagree")
        }

        mesh.vertexEdges = [[EdgeID]](repeating: [], count: mesh.positions.count)
        mesh.edgeFaces = [SIMD2<Int32>](repeating: SIMD2<Int32>(invalidID, invalidID), count: mesh.edgeEnds.count)
        for i in 0..<mesh.positions.count {
            if mesh.vertexAlive[i] { mesh.vertexCount += 1 } else { mesh.freeVertices.append(VertexID(i)) }
        }
        for i in 0..<mesh.edgeEnds.count {
            guard mesh.edgeAlive[i] else {
                mesh.freeEdges.append(EdgeID(i))
                continue
            }
            let pair = mesh.edgeEnds[i]
            guard mesh.isVertexAlive(pair.x), mesh.isVertexAlive(pair.y) else {
                throw ProjectFileError.damaged("an edge refers to a missing vertex")
            }
            mesh.vertexEdges[Int(pair.x)].append(EdgeID(i))
            mesh.vertexEdges[Int(pair.y)].append(EdgeID(i))
            mesh.edgeCount += 1
        }
        mesh.faceLoops = [[VertexID]](repeating: [], count: sizes.count)
        mesh.faceEdgeLoops = [[EdgeID]](repeating: [], count: sizes.count)
        var cursor = 0
        for f in 0..<sizes.count {
            let n = Int(sizes[f])
            guard n >= 0, cursor + n <= corners.count else { throw ProjectFileError.damaged("a face runs off the end of its table") }
            mesh.faceLoops[f] = Array(corners[cursor..<(cursor + n)])
            mesh.faceEdgeLoops[f] = Array(cornerEdges[cursor..<(cursor + n)])
            cursor += n
            guard mesh.faceAlive[f] else {
                mesh.freeFaces.append(FaceID(f))
                continue
            }
            mesh.faceCount += 1
            for e in mesh.faceEdgeLoops[f] {
                guard mesh.isEdgeAlive(e) else { throw ProjectFileError.damaged("a face refers to a missing edge") }
                if mesh.edgeFaces[Int(e)].x < 0 {
                    mesh.edgeFaces[Int(e)].x = FaceID(f)
                } else if mesh.edgeFaces[Int(e)].y < 0 {
                    mesh.edgeFaces[Int(e)].y = FaceID(f)
                } else {
                    throw ProjectFileError.damaged("an edge has more than two faces")
                }
            }
        }
        if let problem = mesh.firstInvariantViolation() {
            throw ProjectFileError.damaged("its mesh is inconsistent (\(problem))")
        }
        mesh.positionVersion = 1
        mesh.topologyVersion = 1
        return mesh
    }

    private struct BinaryReader {
        let data: Data
        var offset: Int

        mutating func bytes(_ count: Int) throws -> Data {
            guard count >= 0, offset + count <= data.count else { throw ProjectFileError.damaged("it ends early") }
            let begin = data.startIndex + offset
            defer { offset += count }
            return data.subdata(in: begin..<(begin + count))
        }

        mutating func value<T>() throws -> T {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { throw ProjectFileError.damaged("it ends early") }
            defer { offset += size }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        }

        mutating func array<T>() throws -> [T] {
            let count: UInt64 = try value()
            let byteCount = Int(count) * MemoryLayout<T>.stride
            guard count < UInt64(Int32.max), offset + byteCount <= data.count else { throw ProjectFileError.damaged("it ends early") }
            let out = [T](unsafeUninitializedCapacity: Int(count)) { buffer, initialized in
                data.withUnsafeBytes { raw in
                    let source = raw.baseAddress!.advanced(by: offset)
                    UnsafeMutableRawPointer(buffer.baseAddress!).copyMemory(from: source, byteCount: byteCount)
                }
                initialized = Int(count)
            }
            offset += byteCount
            return out
        }
    }
}
