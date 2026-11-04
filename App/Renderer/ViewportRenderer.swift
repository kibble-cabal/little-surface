import LittleSurfaceCore
import MetalKit
import simd
import UIKit

/// Must match `Uniforms` in Shaders.msl.
private struct Uniforms {
    var viewProj: Mat4
    var view: Mat4
    var eye: Vec3
    var lightDir: Vec3
    var viewport: Vec2
    var lightIntensity: Float
    var edgeWidth: Float
    var dotSize: Float
    var depthBias: Float
    var faceOpacity: Float
    var surfacePull: Float = 0
}

private struct WorldLine {
    var a: Vec3
    var b: Vec3
    var color: Vec4
    var width: Float
}

private struct ScreenLine {
    var a: Vec2
    var b: Vec2
    var color: Vec4
    var width: Float
}

private struct WorldPoint {
    var position: Vec3
    var color: Vec4
    var size: Float
}

/// Colors for each element state, indexed by the flags written in `RetopoBuffers`.
private enum ElementFlag {
    static let normal: UInt8 = 0
    static let selected: UInt8 = 1
    static let hovered: UInt8 = 2
    static let issue: UInt8 = 3
    static let boundary: UInt8 = 4
}

struct ViewportStyle {
    var background: MTLClearColor
    var source: Vec4
    var faces: [Vec4]
    var edges: [Vec4]
    var dots: [Vec4]
    var backTint: Vec4
    var preview: Vec4
    var mirror: Vec4
    var warning: Vec4
    var chain: Vec4
    var ink: Vec4
    var plane: Vec4
    var wire: Vec4

    static func make(dark: Bool, backgroundLevel: Float?) -> ViewportStyle {
        // The mesh wears the app's emerald. Selection is the system's blue, so it stands out from it.
        let emerald = dark ? Vec4(0.20, 0.83, 0.60, 1) : Vec4(0.02, 0.59, 0.41, 1)
        let topo = dark ? Vec4(0.43, 0.91, 0.72, 1) : Vec4(0.01, 0.34, 0.25, 1)
        let selected = dark ? Vec4(0.04, 0.52, 1.0, 1) : Vec4(0.0, 0.48, 1.0, 1)
        let hover = dark ? Vec4(1.0, 0.84, 0.04, 1) : Vec4(0.95, 0.72, 0.0, 1)
        let issue = Vec4(0.86, 0.16, 0.25, 1)
        let level = backgroundLevel.map(Double.init) ?? (dark ? 0.11 : 0.949)
        return ViewportStyle(
            background: MTLClearColor(red: level, green: level, blue: level + (dark ? 0.008 : 0.02), alpha: 1),
            source: dark ? Vec4(0.55, 0.55, 0.57, 1) : Vec4(0.79, 0.79, 0.81, 1),
            faces: [
                Vec4(emerald.x, emerald.y, emerald.z, 0.32), Vec4(selected.x, selected.y, selected.z, 0.7),
                Vec4(hover.x, hover.y, hover.z, 0.7), Vec4(issue.x, issue.y, issue.z, 0.8),
                Vec4(emerald.x, emerald.y, emerald.z, 0.32),
            ],
            edges: [topo, selected, hover, issue, emerald],
            dots: [topo, selected, hover, issue, topo],
            backTint: Vec4(0.72, 0.18, 0.42, 0.7),
            preview: emerald,
            mirror: Vec4(topo.x, topo.y, topo.z, 0.65),
            warning: issue,
            chain: selected,
            ink: Vec4(emerald.x, emerald.y, emerald.z, 0.95),
            plane: Vec4(emerald.x, emerald.y, emerald.z, 0.09),
            wire: dark ? Vec4(0.70, 0.70, 0.72, 0.5) : Vec4(0.30, 0.30, 0.32, 0.42)
        )
    }
}

/// GPU copy of the editable mesh, updated only as far as the mesh actually changed.
/// Three sets exist so the CPU never writes one the GPU may still be reading.
private final class RetopoBuffers {
    var positions: MTLBuffer?
    var corners: MTLBuffer?
    var triFlags: MTLBuffer?
    var edges: MTLBuffer?
    var edgeFlags: MTLBuffer?
    var dots: MTLBuffer?
    var dotFlags: MTLBuffer?
    var cornerCount = 0
    var edgeCount = 0
    var dotCount = 0
    var positionVersion: UInt64 = .max
    var topologyVersion: UInt64 = .max
    var flagsKey: FlagsKey?
}

private struct FlagsKey: Equatable {
    var selection: Selection
    var hover: PickedElement?
    var issue: MeshIssue?
    var topology: UInt64
}

/// Flattened topology, computed once per topology change and shared by the buffer sets.
private struct TopologyCache {
    var version: UInt64 = .max
    var corners: [UInt32] = []
    var triFaces: [FaceID] = []
    var edges: [SIMD2<UInt32>] = []
    var edgeIDs: [EdgeID] = []
    var dots: [UInt32] = []
}

final class SubdivisionBuffers {
    let positions: MTLBuffer
    let normals: MTLBuffer
    let indices: MTLBuffer
    let indexCount: Int

    init?(device: MTLDevice, data: TriangleMeshData) {
        guard !data.indices.isEmpty,
              let p = device.makeBuffer(bytes: data.positions, length: data.positions.count * MemoryLayout<Vec3>.stride),
              let n = device.makeBuffer(bytes: data.normals, length: data.normals.count * MemoryLayout<Vec3>.stride),
              let i = device.makeBuffer(bytes: data.indices, length: data.indices.count * MemoryLayout<UInt32>.stride) else { return nil }
        positions = p
        normals = n
        indices = i
        indexCount = data.indices.count
    }
}

private final class SourceBuffers {
    let positions: MTLBuffer
    let normals: MTLBuffer
    let indices: MTLBuffer
    let indexCount: Int

    init?(device: MTLDevice, object: SourceObject) {
        guard !object.indices.isEmpty,
              let p = device.makeBuffer(bytes: object.positions, length: object.positions.count * MemoryLayout<Vec3>.stride),
              let n = device.makeBuffer(bytes: object.normals, length: object.normals.count * MemoryLayout<Vec3>.stride),
              let i = device.makeBuffer(bytes: object.indices, length: object.indices.count * MemoryLayout<UInt32>.stride) else { return nil }
        positions = p
        normals = n
        indices = i
        indexCount = object.indices.count
    }
}

final class ViewportRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let inFlight = DispatchSemaphore(value: 3)
    private var frameIndex = 0
    private var buffers = [RetopoBuffers(), RetopoBuffers(), RetopoBuffers()]
    private var topology = TopologyCache()
    private var sourceBuffers: [UUID: SourceBuffers] = [:]
    var subdivision: SubdivisionBuffers?

    weak var engine: RetopoEngine?
    var isDark = false

    private let surfacePipeline: MTLRenderPipelineState
    private let depthOnlyPipeline: MTLRenderPipelineState
    private let facePipeline: MTLRenderPipelineState
    private let edgePipeline: MTLRenderPipelineState
    private let dotPipeline: MTLRenderPipelineState
    private let worldLinePipeline: MTLRenderPipelineState
    private let worldPointPipeline: MTLRenderPipelineState
    private let screenLinePipeline: MTLRenderPipelineState
    private let flatPipeline: MTLRenderPipelineState

    private let depthWrite: MTLDepthStencilState
    private let depthRead: MTLDepthStencilState
    private let depthOccluded: MTLDepthStencilState
    private let depthOff: MTLDepthStencilState

    static let colorFormat = MTLPixelFormat.bgra8Unorm
    static let depthFormat = MTLPixelFormat.depth32Float
    static let sampleCount = 4

    /// Shaders ship as source and compile on the device. A `.metal` file would need Xcode's optional
    /// Metal Toolchain download at build time, and this way the project builds without it.
    private static let library: MTLLibrary? = {
        guard let device = MTLCreateSystemDefaultDevice(),
              let url = Bundle(for: ViewportRenderer.self).url(forResource: "Shaders", withExtension: "msl"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            assertionFailure("Shaders failed to compile: \(error)")
            return nil
        }
    }()

    /// Compiles ahead of time, so opening the first project doesn't wait for it.
    static func warmUp() {
        DispatchQueue.global(qos: .userInitiated).async { _ = library }
    }

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue(), let library = Self.library else { return nil }
        self.queue = queue

        func pipeline(_ vertex: String, _ fragment: String?, blended: Bool = true, writesColor: Bool = true) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = fragment.flatMap { library.makeFunction(name: $0) }
            d.rasterSampleCount = Self.sampleCount
            d.depthAttachmentPixelFormat = Self.depthFormat
            let color = d.colorAttachments[0]!
            color.pixelFormat = Self.colorFormat
            color.writeMask = writesColor ? .all : []
            if blended {
                color.isBlendingEnabled = true
                color.sourceRGBBlendFactor = .sourceAlpha
                color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color.sourceAlphaBlendFactor = .one
                color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let surface = pipeline("surface_vertex", "surface_fragment"),
              let depthOnly = pipeline("surface_vertex", nil, blended: false, writesColor: false),
              let face = pipeline("face_vertex", "face_fragment"),
              let edge = pipeline("edge_vertex", "line_fragment"),
              let dot = pipeline("dot_vertex", "dot_fragment"),
              let worldLine = pipeline("world_line_vertex", "line_fragment"),
              let worldPoint = pipeline("world_point_vertex", "dot_fragment"),
              let screenLine = pipeline("screen_line_vertex", "line_fragment"),
              let flat = pipeline("flat_vertex", "flat_fragment") else { return nil }
        surfacePipeline = surface
        depthOnlyPipeline = depthOnly
        facePipeline = face
        edgePipeline = edge
        dotPipeline = dot
        worldLinePipeline = worldLine
        worldPointPipeline = worldPoint
        screenLinePipeline = screenLine
        flatPipeline = flat

        func depth(_ compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState? {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)
        }
        guard let w = depth(.less, write: true), let r = depth(.lessEqual, write: false),
              let o = depth(.greater, write: false), let n = depth(.always, write: false) else { return nil }
        depthWrite = w
        depthRead = r
        depthOccluded = o
        depthOff = n
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let engine, view.bounds.width > 0 else { return }
        inFlight.wait()
        guard let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        let style = ViewportStyle.make(dark: isDark, backgroundLevel: engine.viewport.backgroundLevel)
        descriptor.colorAttachments[0].clearColor = style.background
        descriptor.colorAttachments[0].loadAction = .clear
        frameIndex = (frameIndex + 1) % buffers.count
        update(buffers[frameIndex], from: engine)
        if let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) {
            encode(encoder, engine: engine, style: style, camera: engine.camera, includesInteraction: true)
            encoder.endEncoding()
        }
        commands.present(drawable)
        commands.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        commands.commit()
    }

    // MARK: Buffers

    private func updateTopologyCache(_ mesh: Mesh) {
        guard topology.version != mesh.topologyVersion else { return }
        var cache = TopologyCache()
        cache.version = mesh.topologyVersion
        cache.corners.reserveCapacity(mesh.faceCount * 6)
        cache.triFaces.reserveCapacity(mesh.faceCount * 2)
        for f in mesh.aliveFaces {
            let loop = mesh.loop(f)
            if loop.count == 3 {
                cache.corners.append(contentsOf: loop.map { UInt32($0) })
                cache.triFaces.append(f)
            } else {
                for t in Triangulation.triangulate(mesh.facePositions(f)) {
                    cache.corners.append(UInt32(loop[Int(t.x)]))
                    cache.corners.append(UInt32(loop[Int(t.y)]))
                    cache.corners.append(UInt32(loop[Int(t.z)]))
                    cache.triFaces.append(f)
                }
            }
        }
        cache.edgeIDs = mesh.aliveEdges
        cache.edges = cache.edgeIDs.map { e in
            let (a, b) = mesh.ends(e)
            return SIMD2<UInt32>(UInt32(a), UInt32(b))
        }
        cache.dots = mesh.aliveVertices.map { UInt32($0) }
        topology = cache
    }

    private func write<T>(_ array: [T], into buffer: inout MTLBuffer?) {
        let length = array.count * MemoryLayout<T>.stride
        guard length > 0 else { return }
        if buffer == nil || buffer!.length < length {
            buffer = device.makeBuffer(length: max(length + length / 2, 4096), options: .storageModeShared)
        }
        array.withUnsafeBytes { bytes in
            buffer?.contents().copyMemory(from: bytes.baseAddress!, byteCount: length)
        }
    }

    private func update(_ b: RetopoBuffers, from engine: RetopoEngine) {
        let mesh = engine.mesh
        updateTopologyCache(mesh)
        if b.topologyVersion != mesh.topologyVersion {
            write(topology.corners, into: &b.corners)
            write(topology.edges, into: &b.edges)
            write(topology.dots, into: &b.dots)
            b.cornerCount = topology.corners.count
            b.edgeCount = topology.edges.count
            b.dotCount = topology.dots.count
            b.topologyVersion = mesh.topologyVersion
            b.positionVersion = .max
        }
        if b.positionVersion != mesh.positionVersion {
            write(mesh.positions, into: &b.positions)
            b.positionVersion = mesh.positionVersion
        }
        let key = FlagsKey(selection: engine.selection, hover: engine.hoverElement, issue: engine.issueHighlight, topology: mesh.topologyVersion)
        if b.flagsKey != key {
            writeFlags(b, mesh: mesh, key: key)
            b.flagsKey = key
        }
    }

    private func writeFlags(_ b: RetopoBuffers, mesh: Mesh, key: FlagsKey) {
        let selection = key.selection
        var hoverVertex = invalidID, hoverEdge = invalidID, hoverFace = invalidID
        switch key.hover {
        case .vertex(let v): hoverVertex = v
        case .edge(let e, _): hoverEdge = e
        case .face(let f): hoverFace = f
        case nil: break
        }
        let issue = key.issue

        var edgesOfSelectedFaces = Set<EdgeID>()
        for f in selection.faces where mesh.isFaceAlive(f) {
            edgesOfSelectedFaces.formUnion(mesh.edgeLoop(f))
        }

        write(topology.triFaces.map { f -> UInt8 in
            if issue?.faces.contains(f) == true { return ElementFlag.issue }
            if selection.faces.contains(f) { return ElementFlag.selected }
            if f == hoverFace { return ElementFlag.hovered }
            return ElementFlag.normal
        }, into: &b.triFlags)
        write(topology.edgeIDs.map { e -> UInt8 in
            if issue?.edges.contains(e) == true { return ElementFlag.issue }
            if selection.edges.contains(e) || edgesOfSelectedFaces.contains(e) { return ElementFlag.selected }
            if e == hoverEdge { return ElementFlag.hovered }
            if mesh.isBoundary(e) { return ElementFlag.boundary }
            return ElementFlag.normal
        }, into: &b.edgeFlags)
        write(topology.dots.map { v -> UInt8 in
            let id = VertexID(v)
            if issue?.vertices.contains(id) == true { return ElementFlag.issue }
            if selection.vertices.contains(id) { return ElementFlag.selected }
            if id == hoverVertex { return ElementFlag.hovered }
            return ElementFlag.normal
        }, into: &b.dotFlags)
    }

    private func syncSources(_ engine: RetopoEngine) {
        let ids = Set(engine.sources.map(\.id))
        for id in sourceBuffers.keys where !ids.contains(id) { sourceBuffers[id] = nil }
        for object in engine.sources where sourceBuffers[object.id] == nil {
            sourceBuffers[object.id] = SourceBuffers(device: device, object: object)
        }
    }

    // MARK: Encoding

    private func encode(_ e: MTLRenderCommandEncoder, engine: RetopoEngine, style: ViewportStyle, camera: Camera, includesInteraction: Bool) {
        let viewport = engine.viewport
        syncSources(engine)
        let azimuth = viewport.lightAzimuth, elevation = viewport.lightElevation
        // The light rides with the camera, so the form always reads whichever way the model is turned.
        let lightLocal = Vec3(sin(azimuth) * cos(elevation), sin(elevation), cos(azimuth) * cos(elevation))
        let bias: Float = camera.projection == .perspective ? 0.00035 : 0.0006
        var uniforms = Uniforms(
            viewProj: camera.viewProjection,
            view: camera.viewMatrix,
            eye: camera.eye,
            lightDir: simd_normalize(camera.orientation.act(lightLocal)),
            viewport: camera.viewSize,
            lightIntensity: viewport.lightIntensity,
            // Thumbnails show the model small, where full-size wires and dots would turn the mesh into a blob.
            edgeWidth: includesInteraction ? 1.6 : 0.7,
            dotSize: includesInteraction ? 7 : 2,
            depthBias: bias,
            faceOpacity: viewport.faceOpacity * 2.2,
            surfacePull: engine.sceneBounds.diagonal * 0.006
        )
        e.setFrontFacing(.counterClockwise)
        e.setCullMode(.none)

        let xray = viewport.displayMode == .xray
        drawSources(e, engine: engine, style: style, uniforms: &uniforms)

        let cageVisible = viewport.showRetopology && !(viewport.subdivisionPreview && viewport.subdivisionDisplay == .smooth && subdivision != nil)
        if viewport.showRetopology, viewport.subdivisionPreview, viewport.subdivisionDisplay != .cage, let s = subdivision {
            e.setRenderPipelineState(surfacePipeline)
            e.setDepthStencilState(depthWrite)
            e.setVertexBuffer(s.positions, offset: 0, index: 0)
            e.setVertexBuffer(s.normals, offset: 0, index: 1)
            e.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
            var b = bias * 0.5
            e.setVertexBytes(&b, length: 4, index: 3)
            e.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            var color = style.faces[0]
            color.w = 1
            color = simd_mix(color, style.source, Vec4(repeating: 0.55))
            color.w = 1
            e.setFragmentBytes(&color, length: 16, index: 1)
            e.drawIndexedPrimitives(type: .triangle, indexCount: s.indexCount, indexType: .uint32, indexBuffer: s.indices, indexBufferOffset: 0)
        }

        if cageVisible {
            drawRetopology(e, style: style, uniforms: &uniforms, xray: xray)
        }
        drawOverlays(e, engine: engine, style: style, uniforms: &uniforms)
        if includesInteraction {
            drawScreenOverlays(e, engine: engine, style: style, uniforms: &uniforms)
        }
    }

    private func drawSources(_ e: MTLRenderCommandEncoder, engine: RetopoEngine, style: ViewportStyle, uniforms: inout Uniforms) {
        let viewport = engine.viewport
        guard viewport.showSource else { return }
        let visible = engine.sources.filter(\.isVisible).compactMap { sourceBuffers[$0.id] }
        guard !visible.isEmpty else { return }
        var noBias: Float = 0
        func bind(_ s: SourceBuffers) {
            e.setVertexBuffer(s.positions, offset: 0, index: 0)
            e.setVertexBuffer(s.normals, offset: 0, index: 1)
        }
        e.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
        e.setVertexBytes(&noBias, length: 4, index: 3)
        e.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)

        var opacity = viewport.sourceOpacity
        if viewport.displayMode == .xray { opacity = min(opacity, 0.35) }

        switch viewport.displayMode {
        case .solid, .xray:
            // Pushed back where it slopes away, which is where flat quads otherwise sink into it.
            e.setDepthBias(1, slopeScale: 1, clamp: 0.01)
            defer { e.setDepthBias(0, slopeScale: 0, clamp: 0) }
            if opacity < 0.999 {
                // Depth first, so only the nearest surface blends and the model doesn't show its insides.
                e.setRenderPipelineState(depthOnlyPipeline)
                e.setDepthStencilState(depthWrite)
                for s in visible {
                    bind(s)
                    e.drawIndexedPrimitives(type: .triangle, indexCount: s.indexCount, indexType: .uint32, indexBuffer: s.indices, indexBufferOffset: 0)
                }
                e.setDepthStencilState(depthRead)
            } else {
                e.setDepthStencilState(depthWrite)
            }
            e.setRenderPipelineState(surfacePipeline)
            var color = style.source
            color.w = opacity
            e.setFragmentBytes(&color, length: 16, index: 1)
            for s in visible {
                bind(s)
                e.drawIndexedPrimitives(type: .triangle, indexCount: s.indexCount, indexType: .uint32, indexBuffer: s.indices, indexBufferOffset: 0)
            }
        case .wireframe:
            e.setRenderPipelineState(depthOnlyPipeline)
            e.setDepthStencilState(depthWrite)
            e.setDepthBias(1, slopeScale: 1, clamp: 0.01)
            for s in visible {
                bind(s)
                e.drawIndexedPrimitives(type: .triangle, indexCount: s.indexCount, indexType: .uint32, indexBuffer: s.indices, indexBufferOffset: 0)
            }
            e.setDepthBias(0, slopeScale: 0, clamp: 0)
            e.setRenderPipelineState(surfacePipeline)
            e.setDepthStencilState(depthRead)
            e.setTriangleFillMode(.lines)
            var color = style.wire
            color.w *= opacity
            e.setFragmentBytes(&color, length: 16, index: 1)
            for s in visible {
                bind(s)
                e.drawIndexedPrimitives(type: .triangle, indexCount: s.indexCount, indexType: .uint32, indexBuffer: s.indices, indexBufferOffset: 0)
            }
            e.setTriangleFillMode(.fill)
        }
    }

    private func drawRetopology(_ e: MTLRenderCommandEncoder, style: ViewportStyle, uniforms: inout Uniforms, xray: Bool) {
        let b = buffers[frameIndex]
        guard let positions = b.positions else { return }

        if b.cornerCount > 0, let corners = b.corners, let flags = b.triFlags {
            e.setRenderPipelineState(facePipeline)
            e.setVertexBuffer(positions, offset: 0, index: 0)
            e.setVertexBuffer(corners, offset: 0, index: 1)
            e.setVertexBuffer(flags, offset: 0, index: 2)
            e.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 3)
            style.faces.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 4) }
            var back = style.backTint
            e.setFragmentBytes(&back, length: 16, index: 1)
            if !xray {
                // Where a face dips under the model, it tints the surface instead of disappearing.
                // Only faces turned toward the viewer do this, so the far side of the model stays hidden.
                var tint = uniforms
                tint.faceOpacity *= 0.65
                e.setFragmentBytes(&tint, length: MemoryLayout<Uniforms>.stride, index: 0)
                e.setDepthStencilState(depthOccluded)
                e.setCullMode(.back)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: b.cornerCount)
                e.setCullMode(.none)
            }
            e.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            e.setDepthStencilState(xray ? depthOff : depthRead)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: b.cornerCount)
        }

        func lines(alpha: Float) {
            guard b.edgeCount > 0, let edges = b.edges, let flags = b.edgeFlags else { return }
            var a = alpha
            e.setRenderPipelineState(edgePipeline)
            e.setVertexBuffer(positions, offset: 0, index: 0)
            e.setVertexBuffer(edges, offset: 0, index: 1)
            e.setVertexBuffer(flags, offset: 0, index: 2)
            e.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 3)
            style.edges.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 4) }
            e.setVertexBytes(&a, length: 4, index: 5)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: b.edgeCount)
        }
        func dots(alpha: Float) {
            guard b.dotCount > 0, let slots = b.dots, let flags = b.dotFlags else { return }
            var a = alpha
            e.setRenderPipelineState(dotPipeline)
            e.setVertexBuffer(positions, offset: 0, index: 0)
            e.setVertexBuffer(slots, offset: 0, index: 1)
            e.setVertexBuffer(flags, offset: 0, index: 2)
            e.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 3)
            style.dots.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 4) }
            e.setVertexBytes(&a, length: 4, index: 5)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: b.dotCount)
        }
        if xray {
            e.setDepthStencilState(depthOff)
            lines(alpha: 1)
            dots(alpha: 1)
        } else {
            // A faint pass for what's behind the model, so the far side stays readable while orbiting.
            e.setDepthStencilState(depthOccluded)
            lines(alpha: 0.14)
            e.setDepthStencilState(depthRead)
            lines(alpha: 1)
            dots(alpha: 1)
        }
    }

    private func setWorldLines(_ e: MTLRenderCommandEncoder, _ lines: [WorldLine], uniforms: inout Uniforms) {
        guard !lines.isEmpty else { return }
        e.setRenderPipelineState(worldLinePipeline)
        let length = lines.count * MemoryLayout<WorldLine>.stride
        if length <= 4096 {
            lines.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: length, index: 0) }
        } else if let buffer = device.makeBuffer(bytes: lines, length: length, options: .storageModeShared) {
            e.setVertexBuffer(buffer, offset: 0, index: 0)
        }
        e.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: lines.count)
    }

    private func setFlatTriangles(_ e: MTLRenderCommandEncoder, _ triangles: [Vec3], color: Vec4, uniforms: inout Uniforms) {
        guard !triangles.isEmpty else { return }
        e.setRenderPipelineState(flatPipeline)
        let length = triangles.count * MemoryLayout<Vec3>.stride
        if length <= 4096 {
            triangles.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: length, index: 0) }
        } else if let buffer = device.makeBuffer(bytes: triangles, length: length, options: .storageModeShared) {
            e.setVertexBuffer(buffer, offset: 0, index: 0)
        }
        e.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        var c = color
        e.setFragmentBytes(&c, length: 16, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: triangles.count)
    }

    private func drawOverlays(_ e: MTLRenderCommandEncoder, engine: RetopoEngine, style: ViewportStyle, uniforms: inout Uniforms) {
        let overlay = engine.overlay
        // Previews show whole, so what's about to be made can be judged even where it dips under the model.
        e.setDepthStencilState(depthOccluded)
        setFlatTriangles(e, overlay.previewTriangles, color: Vec4(style.preview.x, style.preview.y, style.preview.z, 0.14), uniforms: &uniforms)
        var hiddenPreview: [WorldLine] = []
        var previewIndex = 0
        while previewIndex + 1 < overlay.previewEdges.count {
            hiddenPreview.append(WorldLine(a: overlay.previewEdges[previewIndex], b: overlay.previewEdges[previewIndex + 1], color: Vec4(style.preview.x, style.preview.y, style.preview.z, 0.3), width: 1.2))
            previewIndex += 2
        }
        setWorldLines(e, hiddenPreview, uniforms: &uniforms)
        e.setDepthStencilState(depthRead)
        setFlatTriangles(e, overlay.previewTriangles, color: Vec4(style.preview.x, style.preview.y, style.preview.z, 0.24), uniforms: &uniforms)

        var lines: [WorldLine] = []
        func add(_ pairs: [Vec3], color: Vec4, width: Float) {
            var i = 0
            while i + 1 < pairs.count {
                lines.append(WorldLine(a: pairs[i], b: pairs[i + 1], color: color, width: width))
                i += 2
            }
        }
        add(overlay.previewEdges, color: style.preview, width: 1.5)
        add(overlay.mirrorEdges, color: style.mirror, width: 1.5)
        add(overlay.warningEdges, color: style.warning, width: 2.4)
        for chain in overlay.chains { add(chain, color: style.chain, width: 3.2) }
        e.setDepthStencilState(depthRead)
        setWorldLines(e, lines, uniforms: &uniforms)

        if !overlay.previewPoints.isEmpty {
            let points = overlay.previewPoints.map { WorldPoint(position: $0, color: style.preview, size: 5.5) }
            e.setRenderPipelineState(worldPointPipeline)
            let length = points.count * MemoryLayout<WorldPoint>.stride
            if length <= 4096 {
                points.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: length, index: 0) }
            } else if let buffer = device.makeBuffer(bytes: points, length: length, options: .storageModeShared) {
                e.setVertexBuffer(buffer, offset: 0, index: 0)
            }
            e.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: points.count)
        }

        // The mirror plane, so it's clear where the sides meet.
        if let plane = engine.symmetry.activePlane {
            let box = engine.sceneBounds
            if !box.isEmpty {
                let pad = box.diagonal * 0.05
                let lo = box.minCorner - Vec3(repeating: pad), hi = box.maxCorner + Vec3(repeating: pad)
                let axis = plane.axis.rawValue, u = (axis + 1) % 3, v = (axis + 2) % 3
                func corner(_ a: Float, _ b: Float) -> Vec3 {
                    var p = Vec3(repeating: 0)
                    p[axis] = plane.offset
                    p[u] = a
                    p[v] = b
                    return p
                }
                let c = [corner(lo[u], lo[v]), corner(hi[u], lo[v]), corner(hi[u], hi[v]), corner(lo[u], hi[v])]
                setFlatTriangles(e, [c[0], c[1], c[2], c[0], c[2], c[3]], color: style.plane, uniforms: &uniforms)
                var outline = style.plane
                outline.w = 0.45
                setWorldLines(e, (0..<4).map { WorldLine(a: c[$0], b: c[($0 + 1) % 4], color: outline, width: 1) }, uniforms: &uniforms)
            }
        }
    }

    private func drawScreenOverlays(_ e: MTLRenderCommandEncoder, engine: RetopoEngine, style: ViewportStyle, uniforms: inout Uniforms) {
        var lines: [ScreenLine] = []
        func polyline(_ points: [Vec2], color: Vec4, width: Float, closed: Bool = false) {
            guard points.count > 1 else { return }
            for i in 1..<points.count { lines.append(ScreenLine(a: points[i - 1], b: points[i], color: color, width: width)) }
            if closed { lines.append(ScreenLine(a: points[points.count - 1], b: points[0], color: color, width: width)) }
        }
        polyline(engine.inkPath, color: style.ink, width: 2.6)
        if let last = engine.inkPath.last, !engine.inkPrediction.isEmpty {
            var faded = style.ink
            faded.w = 0.45
            polyline([last] + engine.inkPrediction, color: faded, width: 2.2)
        }
        var lassoColor = style.ink
        lassoColor.w = 0.8
        polyline(engine.lassoPath, color: lassoColor, width: 1.5, closed: true)
        if let cursor = engine.brushCursor {
            let radius = engine.tools.brush.radiusPoints
            let ring = (0..<64).map { i -> Vec2 in
                let a = 2 * Float.pi * Float(i) / 64
                return cursor + Vec2(cos(a), sin(a)) * radius
            }
            polyline(ring, color: lassoColor, width: 1.4, closed: true)
        }
        guard !lines.isEmpty else { return }
        e.setRenderPipelineState(screenLinePipeline)
        e.setDepthStencilState(depthOff)
        let length = lines.count * MemoryLayout<ScreenLine>.stride
        if length <= 4096 {
            lines.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: length, index: 0) }
        } else if let buffer = device.makeBuffer(bytes: lines, length: length, options: .storageModeShared) {
            e.setVertexBuffer(buffer, offset: 0, index: 0)
        }
        e.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: lines.count)
    }

    // MARK: Thumbnails

    /// Renders the document to an image for the project list.
    func thumbnail(engine: RetopoEngine, size: CGSize) -> UIImage? {
        let width = Int(size.width), height = Int(size.height)
        var camera = engine.camera
        camera.viewSize = Vec2(Float(width), Float(height))
        let ms = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.colorFormat, width: width, height: height, mipmapped: false)
        ms.textureType = .type2DMultisample
        ms.sampleCount = Self.sampleCount
        ms.storageMode = .private
        ms.usage = .renderTarget
        let resolve = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.colorFormat, width: width, height: height, mipmapped: false)
        resolve.storageMode = .private
        resolve.usage = .renderTarget
        let depth = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.depthFormat, width: width, height: height, mipmapped: false)
        depth.textureType = .type2DMultisample
        depth.sampleCount = Self.sampleCount
        depth.storageMode = .private
        depth.usage = .renderTarget
        let bytesPerRow = width * 4
        guard let msTexture = device.makeTexture(descriptor: ms), let resolveTexture = device.makeTexture(descriptor: resolve),
              let depthTexture = device.makeTexture(descriptor: depth),
              let readback = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let commands = queue.makeCommandBuffer() else { return nil }
        let style = ViewportStyle.make(dark: false, backgroundLevel: nil)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msTexture
        pass.colorAttachments[0].resolveTexture = resolveTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.colorAttachments[0].clearColor = style.background
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        inFlight.wait()
        frameIndex = (frameIndex + 1) % buffers.count
        update(buffers[frameIndex], from: engine)
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            inFlight.signal()
            return nil
        }
        encode(encoder, engine: engine, style: style, camera: camera, includesInteraction: false)
        encoder.endEncoding()
        if let blit = commands.makeBlitCommandEncoder() {
            blit.copy(from: resolveTexture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1),
                      to: readback, destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
            blit.endEncoding()
        }
        commands.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        commands.commit()
        commands.waitUntilCompleted()
        guard let provider = CGDataProvider(data: Data(bytes: readback.contents(), count: bytesPerRow * height) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: image)
    }
}
