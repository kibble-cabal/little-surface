import Foundation
import simd

public enum Tool: String, Codable, CaseIterable {
    case pencil, select, sketch, drawEdges, edgeLoop, quadStrip, quadPatch, face, moveBrush, relaxBrush, erase

    public var isDrawingTool: Bool {
        switch self {
        case .pencil, .drawEdges, .edgeLoop, .quadStrip, .quadPatch: return true
        default: return false
        }
    }
    public var isBrush: Bool { self == .moveBrush || self == .relaxBrush || self == .erase }
}

public enum SelectionOperation: String, CaseIterable {
    case replace, add, remove
}

public enum DragBehavior: String, CaseIterable {
    /// Drag along the surface.
    case move
    /// Drag along connected edges.
    case slide
}

public struct EngineMessage: Equatable {
    public enum Kind { case info, success, warning, error }
    public var id = UUID()
    public var text: String
    public var kind: Kind

    public init(_ text: String, kind: Kind = .info) {
        self.text = text
        self.kind = kind
    }
}

/// A stroke awaiting a decision: closing a near-closed path, or an interpretation worth checking.
public struct PendingStroke {
    public var paths: [ProcessedPath]
    public var plans: [StrokePlan]
    /// The ends are near each other, and closing the loop is on offer.
    public var canClose: Bool
    public var closedPlan: StrokePlan?
    public var note: String?
}

public struct PendingStrip {
    public var path: ProcessedPath
    public var clippedAtCenterline: Bool
    public var plan: TopologyPlan?
    public var error: String?
    /// The stroke as drawn, when its ends were near enough to make this a ring.
    public var openPath: ProcessedPath? = nil
}

/// Quads that would fill between the line just drawn and the one beside it, on offer until the next stroke.
public struct FillSuggestion {
    public var chains: [BoundaryChain]
    public var preview: PatchPlan
}

public enum FaceCorner: Equatable {
    case vertex(VertexID)
    case edgePoint(EdgeID, t: Float, position: Vec3)
    case surface(position: Vec3, normal: Vec3)
}

/// Everything the viewport draws that isn't the committed mesh or source, in world space.
public struct OverlayGeometry {
    public var previewEdges: [Vec3] = []
    public var previewPoints: [Vec3] = []
    public var previewTriangles: [Vec3] = []
    public var mirrorEdges: [Vec3] = []
    public var warningEdges: [Vec3] = []
    /// What the eraser is about to take, as line-segment pairs.
    public var erasingEdges: [Vec3] = []
    /// Each picked patch chain, as line-segment pairs.
    public var chains: [[Vec3]] = []
    public init() {}
}

/// The document's editing engine: everything that changes topology goes through here, so the UI is
/// nothing but input and display. It's main-thread-only; the source surface, snapshots and mesh values
/// it hands out are all safe to use elsewhere.
public final class RetopoEngine {
    // MARK: Document state

    public var name: String
    public private(set) var createdAt: Date
    public private(set) var sources: [SourceObject] = []
    public private(set) var mesh = Mesh()
    public private(set) var selection = Selection()
    public private(set) var history = EditHistory()
    public private(set) var projector: SurfaceProjector?
    private var bvhs: [UUID: TriangleBVH] = [:]

    public var camera = Camera()
    public private(set) var symmetry = SymmetrySettings()
    public var viewport = ViewportSettings() { didSet { notify() } }
    public var tools = ToolSettings()
    public private(set) var activeTool = Tool.drawEdges

    // MARK: Interaction state

    public var selectionOperation = SelectionOperation.replace
    public var dragBehavior = DragBehavior.move
    public var ignoresOcclusionForPicking: Bool { viewport.displayMode != .solid || !viewport.showSource }
    public private(set) var hoverPoint: Vec2?
    public private(set) var hoverElement: PickedElement?
    public private(set) var lassoPath: [Vec2] = []
    public private(set) var inkPath: [Vec2] = []
    public private(set) var inkPrediction: [Vec2] = []
    public private(set) var inkingIn = InkingIn()
    public private(set) var brushCursor: Vec2?
    /// How far around the cursor a brush reaches, in screen points. The eraser takes whole lines, so it's
    /// kept to about the size of its tip.
    public var brushReach: Float { tools.brush.radiusPoints * (activeTool == .erase ? 0.4 : 1) }

    public private(set) var pendingStroke: PendingStroke?
    public private(set) var pendingStrip: PendingStrip?
    /// Set when a stroke just closed by itself: the same stroke left open, in case it shouldn't have.
    public private(set) var reopenablePlans: [StrokePlan]?
    public private(set) var fillSuggestion: FillSuggestion?
    /// Strokes whose ends land near each other become loops, or rings for Quad Strip.
    public var closesLoopsAutomatically = true
    /// A line drawn next to another offers to fill the space between them with quads.
    public var suggestsFills = true
    public private(set) var patchChains: [BoundaryChain] = []
    public private(set) var patchPreview: PatchPlan?
    public private(set) var patchError: String?
    public private(set) var faceCorners: [FaceCorner] = []
    public private(set) var overlay = OverlayGeometry()
    public private(set) var issueHighlight: MeshIssue?

    /// Set by every edit, cleared by the document layer.
    public private(set) var editGeneration: UInt64 = 0
    public private(set) var message: EngineMessage?
    /// Called on the main thread after anything visible changes.
    public var onChange: (() -> Void)?
    /// Called when an action reaches a milestone the tutorial follows.
    public var onEvent: ((EngineEvent) -> Void)?

    public enum EngineEvent: Equatable {
        case modelImported, strokeCommitted, loopClosed, facesGenerated, vertexMoved, exported
        /// A stroke picked up an existing vertex or line.
        case strokeSnapped
        /// Create Patch made its quads.
        case patchCreated
    }

    // MARK: Gesture state

    private enum Gesture {
        case idle
        case stroke(StrokeCapture)
        case tapOnly(start: Vec2)
        case select(SelectDrag)
        case lasso([Vec2])
        case brush(before: EditSnapshot, lastHit: SurfaceHit?, label: String)
        case erase
        /// A stroke that's become a clean shape. `grabbed` is where the Pencil was when it did, and it
        /// can still resize and turn it from there, until it lifts.
        case quickShape(base: QuickShape, grabbed: Vec2, current: QuickShape)
        case sketch(StrokeCapture)
        case sketchErase(before: EditSnapshot, changed: Bool)
    }

    private struct SelectDrag {
        var start: Vec2
        var startedOn: PickedElement?
        var before: EditSnapshot
        var basePositions: [VertexID: Vec3]
        var grabPoint: Vec3
        var grabPlaneNormal: Vec3
        var moved = false
        var targets: [VertexID]
        /// A point picked up by resting on it goes back to being drawn from once it's been put down.
        var staysPicked = true
    }

    private var gesture = Gesture.idle
    private let tapSlop: Float = 10
    private var statsCache: (version: UInt64, stats: MeshStatistics)?

    public init(name: String = "Untitled") {
        self.name = name
        createdAt = Date()
    }

    private func notify() { onChange?() }

    public func say(_ text: String, kind: EngineMessage.Kind = .info) {
        message = EngineMessage(text, kind: kind)
        notify()
    }

    public func clearMessage() {
        message = nil
        notify()
    }

    public var statistics: MeshStatistics {
        if let cache = statsCache, cache.version == mesh.topologyVersion { return cache.stats }
        let stats = MeshStatistics(mesh)
        statsCache = (mesh.topologyVersion, stats)
        return stats
    }

    public var canUndo: Bool { history.canUndo || pendingStroke != nil || pendingStrip != nil || !faceCorners.isEmpty }
    public var canRedo: Bool { history.canRedo }
    public var hasSurface: Bool { !(projector?.isEmpty ?? true) }
    private var activeProjector: SurfaceProjector? { tools.surfaceSnapping ? projector : nil }

    // MARK: Sources

    /// Builds what's needed to query an object. Slow for dense meshes, so call it off the main thread.
    public static func buildBVHs(for objects: [SourceObject], isCancelled: () -> Bool = { false }) -> [UUID: TriangleBVH] {
        var out: [UUID: TriangleBVH] = [:]
        for object in objects {
            if isCancelled() { return out }
            if let bvh = TriangleBVH(object: object, isCancelled: isCancelled) { out[object.id] = bvh }
        }
        return out
    }

    /// Adds imported objects. On a project's first model, this also sets scale-aware tool defaults.
    public func addSources(_ objects: [SourceObject], bvhs built: [UUID: TriangleBVH], frame: Bool = true) {
        let isFirst = sources.isEmpty
        sources.append(contentsOf: objects)
        bvhs.merge(built) { _, new in new }
        rebuildProjector()
        if isFirst { applyScaleDefaults() }
        updateCameraScale()
        if frame { frameAll() }
        onEvent?(.modelImported)
        notify()
    }

    /// Installs objects loaded from a saved project, keeping the settings saved with them.
    public func installLoadedBVHs(_ built: [UUID: TriangleBVH]) {
        bvhs = built
        rebuildProjector()
        if !patchChains.isEmpty { updatePatchPreview() }
        notify()
    }

    public func removeSource(id: UUID) {
        sources.removeAll { $0.id == id }
        bvhs[id] = nil
        rebuildProjector()
        editGeneration &+= 1
        notify()
    }

    public func setSourceVisible(id: UUID, _ visible: Bool) {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[i].isVisible = visible
        editGeneration &+= 1
        notify()
    }

    public func setSourceSnapTarget(id: UUID, _ available: Bool) {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[i].isSnapTarget = available
        rebuildProjector()
        editGeneration &+= 1
        notify()
    }

    /// Brings a mesh from another app into the topology, as one undoable edit. With nothing to draw on
    /// yet, a copy of it becomes the surface so tools work straight away. Vertices then move freely
    /// instead of sticking to that copy, which would stop the mesh from ever changing shape.
    @discardableResult
    public func addEditableMesh(_ imported: ImportedMesh, surface: (object: SourceObject, bvh: TriangleBVH)?, replacing: Bool = false) -> Bool {
        // It can arrive from Blender at any moment, including under the Pencil.
        if isMidGesture { pencilCancelled() }
        cancelTransientState()
        let ok = perform(replacing ? "Replace mesh" : "Import mesh") { mesh, selection in
            if replacing { mesh = Mesh() }
            try mesh.append(imported.mesh)
            selection.clear()
        }
        guard ok else { return false }
        if let surface, sources.isEmpty {
            addSources([surface.object], bvhs: [surface.object.id: surface.bvh])
            tools.surfaceSnapping = false
        } else {
            updateCameraScale()
            frameAll()
        }
        return true
    }

    /// What updating a sculpt did to the topology.
    public struct SculptUpdate {
        public var movedVertices: Int
        /// Too far from the new surface to follow it. They stayed where they were and are now selected.
        public var unreachableVertices: Int
        public var largestMove: Float
        /// New size over old. A long way from 1 usually means the file was exported at another scale.
        public var sizeRatio: Float
        /// False when the source isn't a surface to draw on, so nothing was snapped to it.
        public var snapped: Bool
    }

    /// Swaps a source for a changed version of itself and snaps the topology onto it. Connectivity,
    /// symmetry partners and everything else about the mesh stay, and one undo reverses all of it.
    @discardableResult
    public func updateSource(id: UUID, with replacement: SourceObject, bvh: TriangleBVH) -> SculptUpdate? {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return nil }
        if isMidGesture { pencilCancelled() }
        cancelTransientState()
        var before = currentSnapshot
        before.sculpts[id] = SculptVersion(positions: sources[index].positions, normals: sources[index].normals, indices: sources[index].indices, bvh: bvhs[id], revision: sources[index].geometryRevision)
        let oldDiagonal = sources[index].bounds.diagonal

        let oldSurface = projector
        sculptRevisionCounter &+= 1
        let version = SculptVersion(positions: replacement.positions, normals: replacement.normals, indices: replacement.indices, bvh: bvh, revision: sculptRevisionCounter)
        install(version, sourceAt: index)
        rebuildProjector()
        updateCameraScale()

        let newDiagonal = sources[index].bounds.diagonal
        var result = SculptUpdate(movedVertices: 0, unreachableVertices: 0, largestMove: 0, sizeRatio: newDiagonal / max(oldDiagonal, 1e-6), snapped: sources[index].isSnapTarget)
        if result.snapped, let projector {
            // Past this, the nearest surface is a different part of the model, not the same part moved.
            let reach = newDiagonal * 0.25
            var updates: [(VertexID, Vec3)] = []
            var unreachable = Set<VertexID>()
            for v in mesh.aliveVertices {
                let p = mesh.position(v)
                guard var target = Self.followSurface(from: p, faceNormal: mesh.vertexNormal(v), old: oldSurface, new: projector, reach: reach) else {
                    unreachable.insert(v)
                    continue
                }
                if let plane = symmetry.activePlane, mesh.mirrorPartner[Int(v)] == v { target = plane.snap(target) }
                updates.append((v, target))
                result.largestMove = max(result.largestMove, simd_length(target - p))
            }
            mesh.setPositions(updates)
            result.movedVertices = updates.count
            // The planning lines are drawn on the same surface, so they go with it.
            for s in sketches.indices {
                sketches[s].points = sketches[s].points.map { Self.followSurface(from: $0, faceNormal: .zero, old: oldSurface, new: projector, reach: reach) ?? $0 }
            }
            sketchRevision &+= 1
            result.unreachableVertices = unreachable.count
            if !unreachable.isEmpty {
                selection.clear()
                selection.mode = .vertex
                selection.vertices = unreachable
            }
        }
        recordEdit(before: before, label: "Update sculpt")
        return result
    }

    /// Where a vertex goes when the surface under it changes. It travels along the old surface's normal,
    /// which keeps neighbours in order. The nearest point is only the fallback, because a bump can pull
    /// one vertex toward it and leave the next behind, which is what makes lines wobble.
    private static func followSurface(from p: Vec3, faceNormal: Vec3, old: SurfaceProjector?, new: SurfaceProjector, reach: Float) -> Vec3? {
        let hint = simd_length_squared(faceNormal) > 0 ? faceNormal : nil
        if let normal = old?.closest(to: p, normalHint: hint, maxDistance: reach)?.normal ?? hint {
            var best: SurfaceHit?
            for direction in [normal, -normal] {
                guard let hit = new.raycast(Ray(origin: p, direction: direction), tMax: reach), simd_dot(hit.normal, normal) > 0.2 else { continue }
                if hit.distance < (best?.distance ?? .infinity) { best = hit }
            }
            if let best { return best.offsetPosition(new.surfaceOffset) }
        }
        return new.project(p, normalHint: hint, maxDistance: reach)?.position
    }

    private func install(_ version: SculptVersion, sourceAt index: Int) {
        sources[index].positions = version.positions
        sources[index].normals = version.normals
        sources[index].indices = version.indices
        sources[index].geometryRevision = version.revision
        bvhs[sources[index].id] = version.bvh
        sculpts[sources[index].id] = version
    }

    private func installSculpts(_ recorded: [UUID: SculptVersion]) {
        var changed = false
        for (id, version) in recorded {
            guard let index = sources.firstIndex(where: { $0.id == id }), sources[index].geometryRevision != version.revision else { continue }
            install(version, sourceAt: index)
            changed = true
        }
        if changed {
            rebuildProjector()
            updateCameraScale()
        }
    }

    public var sourceBounds: AABB {
        var box = AABB.empty
        for bvh in bvhs.values where bvh.triangleCount > 0 { box.grow(bvh.bounds) }
        return box
    }

    /// A replay has no surface built to measure, so it's told how big the scene is.
    public var replayBounds: AABB?

    public var sceneBounds: AABB {
        if let replayBounds { return replayBounds }
        var box = sourceBounds
        if !mesh.isEmpty { box.grow(mesh.bounds) }
        return box
    }

    private func rebuildProjector() {
        let active = sources.filter(\.isSnapTarget).compactMap { bvhs[$0.id] }
        projector = active.isEmpty ? nil : SurfaceProjector(bvhs: active, surfaceOffset: tools.surfaceOffset)
    }

    /// A sensible starting scale, based on the model: all these stay editable afterward.
    private func applyScaleDefaults() {
        let box = sourceBounds
        let diagonal = max(box.diagonal, 1e-4)
        tools.stroke.edgeLength = diagonal * 0.02
        tools.strip.width = diagonal * 0.05
        tools.strip.vertexSpacing = diagonal * 0.02
        tools.extrudeDistance = diagonal * 0.02
        tools.surfaceOffset = diagonal * 0.0005
        symmetry.centerTolerance = diagonal * 0.003
        symmetry.plane.axis = .x
        // A model centered near zero mirrors about zero, which is what most exporters intend.
        symmetry.plane.offset = abs(box.center.x) < diagonal * 0.01 ? 0 : box.center.x
        projector?.surfaceOffset = tools.surfaceOffset
    }

    private func updateCameraScale() {
        camera.sceneRadius = max(sceneBounds.diagonal * 0.5, 1e-3)
    }

    public func setSurfaceOffset(_ offset: Float) {
        tools.surfaceOffset = offset
        projector?.surfaceOffset = offset
        editGeneration &+= 1
        notify()
    }

    // MARK: Camera commands

    public func frameAll() {
        let box = sceneBounds
        guard !box.isEmpty else { return }
        camera.sceneRadius = max(box.diagonal * 0.5, 1e-3)
        camera.frame(box)
        notify()
    }

    public func frameSelection() {
        let box = selection.bounds(in: mesh)
        guard !box.isEmpty else {
            frameAll()
            return
        }
        // A single vertex has no size, so give it some surroundings.
        let padded = box.diagonal > 1e-5 ? box : box.expanded(by: max(sceneBounds.diagonal * 0.05, 1e-3))
        camera.frame(padded, padding: 1.6)
        notify()
    }

    public func setProjection(_ mode: ProjectionMode) {
        camera.projection = mode
        notify()
    }

    public func cameraChanged() { notify() }

    // MARK: Tools

    public func setTool(_ tool: Tool) {
        guard tool != activeTool else { return }
        settlePending()
        cancelFaceBuilder()
        if tool != .quadPatch && tool != .drawEdges { clearPatchPicks() }
        activeTool = tool
        hoverElement = nil
        rebuildOverlay()
        notify()
    }

    private func settlePending() {
        if pendingStroke != nil { commitPendingStroke(close: false) }
        if pendingStrip != nil { commitPendingStrip() }
        clearOffers()
    }

    private func clearOffers() {
        guard reopenablePlans != nil || fillSuggestion != nil else { return }
        reopenablePlans = nil
        fillSuggestion = nil
        rebuildOverlay()
    }

    public func setSelectionMode(_ mode: SelectionMode) {
        guard mode != selection.mode else { return }
        // Convert what's selected rather than dropping it, so that switching modes loses nothing.
        let touched = selection.touchedVertices(in: mesh)
        var next = Selection()
        next.mode = mode
        SelectionTools.select(vertices: touched, in: mesh, mode: mode, into: &next, additive: true)
        selection = next
        notify()
    }

    public func setIssueHighlight(_ issue: MeshIssue?) {
        issueHighlight = issue
        notify()
    }

    // MARK: Timelapse

    public let timelapse = TimelapseRecorder()

    /// An engine for drawing the frames of a replay. It has the project's models and nothing else.
    public static func forReplay(of snapshot: ProjectSnapshot) -> RetopoEngine {
        var bare = snapshot
        bare.mesh = Mesh()
        bare.selection = Selection()
        bare.patchChains = []
        bare.faceBuilderVertices = []
        bare.symmetry.isEnabled = false
        bare.sketches = []
        bare.showsSketch = true
        bare.timelapse = []
        bare.activeTool = .select
        bare.viewport.showRetopology = true
        bare.viewport.showSource = true
        bare.viewport.displayMode = .solid
        return RetopoEngine(snapshot: bare)
    }

    public func showForReplay(mesh: Mesh, sketches: [SketchStroke]) {
        install(EditSnapshot(mesh: mesh, selection: Selection(), sketches: sketches))
        rebuildOverlay()
    }

    // MARK: Sketch layer

    public private(set) var sketches: [SketchStroke] = []
    /// Changes whenever the sketch does, so what's drawn from it knows to refresh.
    public private(set) var sketchRevision: UInt64 = 0
    public var sketchColorIndex = 0
    public var sketchErases = false
    public var showsSketch = true

    private func finishSketch(_ capture: StrokeCapture, colorIndex: Int? = nil) {
        let colorIndex = colorIndex ?? sketchColorIndex
        guard capture.screenLength >= minimumStrokeLength else { return }
        let before = currentSnapshot
        // Lifted just clear of the surface, so the model doesn't cut through the line.
        let lift = max(tools.surfaceOffset * 2, sceneBounds.diagonal * 0.0008)
        var added: [SketchStroke] = []
        for run in capture.usableRuns {
            var points: [Vec3] = []
            for sample in run {
                let p = sample.position + sample.normal * lift
                // A loose line doesn't need every sample the Pencil sends.
                if let last = points.last, simd_length(p - last) < camera.worldPerPoint(at: p) * 1.5, sample != run.last { continue }
                points.append(p)
            }
            guard points.count >= 2 else { continue }
            added.append(SketchStroke(points: points, colorIndex: colorIndex))
            if let plane = symmetry.activePlane {
                added.append(SketchStroke(points: points.map(plane.reflect), colorIndex: colorIndex))
            }
        }
        guard !added.isEmpty else { return }
        sketches += added
        sketchRevision &+= 1
        recordEdit(before: before, label: "Sketch")
    }

    /// Takes out whole lines the Pencil touches. Those on the far side of the model are left alone.
    private func eraseSketch(at screen: Vec2) {
        guard case .sketchErase(let before, _) = gesture else { return }
        let kept = sketches.filter { !touches($0, at: screen) }
        guard kept.count != sketches.count else { return }
        sketches = kept
        sketchRevision &+= 1
        gesture = .sketchErase(before: before, changed: true)
    }

    private func touches(_ stroke: SketchStroke, at screen: Vec2, radius: Float = 18) -> Bool {
        let tolerance = sceneBounds.diagonal * 0.01
        var previous: Vec2?
        for p in stroke.points {
            guard let projected = camera.project(p) else {
                previous = nil
                continue
            }
            defer { previous = projected.screen }
            let a = previous ?? projected.screen, b = projected.screen
            let along = simd_clamp(simd_dot(screen - a, b - a) / max(simd_length_squared(b - a), 1e-6), 0, 1)
            guard simd_length(screen - (a + (b - a) * along)) <= radius else { continue }
            if projector?.isOccluded(p, from: camera.occlusionEye(for: p), tolerance: tolerance) ?? false { continue }
            return true
        }
        return false
    }

    public func clearSketch() {
        guard !sketches.isEmpty else { return }
        let before = currentSnapshot
        sketches = []
        sketchRevision &+= 1
        recordEdit(before: before, label: "Clear sketch")
    }

    // MARK: Poly budget and topology check

    /// The target for the finished mesh, in triangles.
    public private(set) var polyBudget: Int?

    public func setPolyBudget(_ budget: Int?) {
        polyBudget = budget.map { max($0, 1) }
        notify()
    }

    private var jumpPositions: [TopologyCheck: Int] = [:]

    /// One place each of what's being looked for. `report` supplies bad geometry, which takes too long
    /// to work out as often as the others.
    public func spots(of check: TopologyCheck, report: ValidationReport?) -> [TopologySpot] {
        switch check {
        case .triangles: return mesh.aliveFaces.filter { mesh.loop($0).count == 3 }.map(TopologySpot.face)
        case .ngons: return mesh.aliveFaces.filter { mesh.cornerCount(of: $0) > 4 }.map(TopologySpot.face)
        case .poles: return MeshValidator.poles(mesh).map(TopologySpot.vertex)
        case .badGeometry:
            var out: [TopologySpot] = []
            for issue in report?.issues ?? [] where issue.kind.isError {
                out += issue.faces.sorted().filter(mesh.isFaceAlive).map(TopologySpot.face)
                out += issue.edges.sorted().filter(mesh.isEdgeAlive).map(TopologySpot.edge)
                out += issue.vertices.sorted().filter(mesh.isVertexAlive).map(TopologySpot.vertex)
            }
            return out
        }
    }

    /// Takes the view to the next one, selected and facing the viewer. Each call moves on to another and
    /// comes back round after the last. Returns which it is, counting from one, and how many there are.
    @discardableResult
    public func jump(to check: TopologyCheck, report: ValidationReport? = nil) -> (position: Int, count: Int)? {
        let spots = spots(of: check, report: report)
        guard !spots.isEmpty else { return nil }
        let index = (jumpPositions[check] ?? -1) + 1
        let wrapped = index % spots.count
        jumpPositions[check] = wrapped
        let spot = spots[wrapped]
        cancelTransientState()
        activeTool = .select

        var next = Selection()
        var normal = Vec3(repeating: 0)
        var center = Vec3(repeating: 0)
        switch spot {
        case .face(let f):
            next.mode = .face
            next.faces = [f]
            normal = mesh.faceNormal(f)
            center = mesh.faceCenter(f)
        case .edge(let e):
            next.mode = .edge
            next.edges = [e]
            let (a, b) = mesh.ends(e)
            normal = mesh.vertexNormal(a) + mesh.vertexNormal(b)
            center = (mesh.position(a) + mesh.position(b)) * 0.5
        case .vertex(let v):
            next.mode = .vertex
            next.vertices = [v]
            normal = mesh.vertexNormal(v)
            center = mesh.position(v)
        }
        selection = next
        camera.look(along: normal)
        // Far enough back to see what's around it, not just the one element.
        let size = max(sceneBounds.diagonal * 0.14, mesh.averageEdgeLength * 2, 1e-3)
        camera.frame(AABB(points: [center]).expanded(by: size), padding: 1.4)
        rebuildOverlay()
        notify()
        return (wrapped + 1, spots.count)
    }

    public func selectIssue(_ issue: MeshIssue) {
        var next = Selection()
        if !issue.faces.isEmpty {
            next.mode = .face
            next.faces = issue.faces
        } else if !issue.edges.isEmpty {
            next.mode = .edge
            next.edges = issue.edges
        } else {
            next.mode = .vertex
            next.vertices = issue.vertices
        }
        next.prune(in: mesh)
        selection = next
        activeTool = .select
        notify()
    }

    // MARK: Transactions

    /// Runs an edit on a copy. Success commits it as one undo step; a throw shows the reason and
    /// leaves the mesh and selection exactly as they were.
    @discardableResult
    public func perform(_ label: String, _ body: (inout Mesh, inout Selection) throws -> Void) -> Bool {
        var nextMesh = mesh
        var nextSelection = selection
        do {
            try body(&nextMesh, &nextSelection)
        } catch {
            say(error.localizedDescription, kind: .error)
            return false
        }
        commit(label: label, mesh: nextMesh, selection: nextSelection)
        return true
    }

    private func commit(label: String, mesh nextMesh: Mesh, selection nextSelection: Selection) {
        let before = currentSnapshot
        var finalMesh = nextMesh
        if let plane = symmetry.activePlane { repairPairs(&finalMesh, plane: plane) }
        finalMesh.settleBends()
        mesh = finalMesh
        selection = nextSelection
        selection.prune(in: mesh)
        recordEdit(before: before, label: label)
    }

    private var currentSnapshot: EditSnapshot {
        var snapshot = EditSnapshot(mesh: mesh, selection: selection, sculpts: sculpts, sketches: sketches)
        snapshot.pickedMark = pickedMark
        return snapshot
    }

    private static let pickLabel = "Pick"

    /// Picking is a step of its own, so undo can go back through it. Nothing about the drawing changes,
    /// so it isn't an edit and doesn't reach the timelapse.
    private func recordPick(from before: EditSnapshot) {
        guard !showsSamePick(as: before) else { return }
        history.record(before: before, label: Self.pickLabel)
    }

    private func showsSamePick(as snapshot: EditSnapshot) -> Bool {
        selection.vertices == snapshot.selection.vertices && selection.edges == snapshot.selection.edges
            && selection.faces == snapshot.selection.faces && pickedMark == snapshot.pickedMark
    }

    private func restorePick(_ snapshot: EditSnapshot) {
        selection = snapshot.selection
        if pickedMark != snapshot.pickedMark {
            pickedMark = snapshot.pickedMark
            sketchRevision &+= 1
        }
        rebuildOverlay()
        notify()
    }

    /// Every committed change to the mesh passes through here, whichever tool made it, so undo and
    /// everything that follows an edit treat them all alike. `before` is the state the edit started from.
    private func recordEdit(before: EditSnapshot, label: String) {
        history.record(before: before, label: label)
        didEdit()
    }

    private func repairPairs(_ target: inout Mesh, plane: MirrorPlane) {
        let tolerance = max(symmetry.centerTolerance * 2, target.averageEdgeLength * 0.3)
        Symmetry.repairPairs(in: &target, plane: plane, centerTolerance: symmetry.centerTolerance, pairingTolerance: tolerance)
    }

    private func didEdit() {
        pickedMark = nil
        // Here rather than at each tool, so that no edit, undo or redo can miss the timelapse.
        timelapse.record(mesh: mesh, sketches: sketches, orientation: camera.orientation)
        editGeneration &+= 1
        reopenablePlans = nil
        fillSuggestion = nil
        refreshPatchChains()
        issueHighlight = nil
        rebuildOverlay()
        notify()
    }

    public func undo() {
        // Undo takes back what's still in progress before it touches anything already committed, so a
        // stray tap never costs an earlier edit as well.
        if undoUncommittedWork() { return }
        cancelTransientState()
        let isPick = history.undoLabel == Self.pickLabel
        guard let snapshot = history.undo(current: currentSnapshot) else { return }
        if isPick {
            // A pick already let go some other way has nothing to show, so it shouldn't take a press.
            let showsNothing = showsSamePick(as: snapshot)
            restorePick(snapshot)
            if showsNothing { undo() }
            return
        }
        restore(snapshot)
        pickAgain(from: snapshot)
        say("Undid \(history.redoLabel ?? "edit")")
    }

    public func redo() {
        if isMidGesture { pencilCancelled() }
        cancelTransientState()
        let isPick = history.redoLabel == Self.pickLabel
        guard let snapshot = history.redo(current: currentSnapshot) else { return }
        if isPick {
            let showsNothing = showsSamePick(as: snapshot)
            restorePick(snapshot)
            if showsNothing { redo() }
            return
        }
        restore(snapshot)
        pickAgain(from: snapshot)
        say("Redid \(history.undoLabel ?? "edit")")
    }

    /// A mark that was picked when this state was recorded still is, once the edit is taken back.
    private func pickAgain(from snapshot: EditSnapshot) {
        guard snapshot.pickedMark != nil else { return }
        pickedMark = snapshot.pickedMark
        sketchRevision &+= 1
    }

    /// Throws away one piece of unfinished work. Returns false when there was none.
    private func undoUncommittedWork() -> Bool {
        if isMidGesture {
            pencilCancelled()
            say("Cancelled that stroke")
            return true
        }
        if pendingStroke != nil || pendingStrip != nil {
            cancelPending()
            return true
        }
        if !faceCorners.isEmpty {
            undoFaceCorner()
            return true
        }
        return false
    }

    private var isMidGesture: Bool {
        switch gesture {
        case .idle, .tapOnly: return false
        default: return true
        }
    }

    private func restore(_ snapshot: EditSnapshot) {
        install(snapshot)
        installSculpts(snapshot.sculpts)
        // Symmetry may have been turned on since this state was recorded, and it wouldn't have partners.
        if let plane = symmetry.activePlane { repairPairs(&mesh, plane: plane) }
        didEdit()
    }

    /// Puts a recorded state back without counting it as an edit.
    private func install(_ snapshot: EditSnapshot) {
        mesh = snapshot.mesh
        // Versions must move forward even when restoring older content, or the renderer keeps stale buffers.
        mesh.positionVersion = max(mesh.positionVersion, snapshotVersionFloor.0) &+ 1
        mesh.topologyVersion = max(mesh.topologyVersion, snapshotVersionFloor.1) &+ 1
        snapshotVersionFloor = (mesh.positionVersion, mesh.topologyVersion)
        selection = snapshot.selection
        if sketches != snapshot.sketches {
            sketches = snapshot.sketches
            sketchRevision &+= 1
        }
    }

    /// Gives memory back when the system asks, by forgetting the oldest undo steps first.
    public func releaseUndoMemory() {
        history.shrink(toFractionOfBudget: 0.25)
    }

    private var snapshotVersionFloor: (UInt64, UInt64) = (0, 0)
    private var sculpts: [UUID: SculptVersion] = [:]
    private var sculptRevisionCounter: UInt64 = 0

    private func cancelTransientState() {
        pendingStroke = nil
        pendingStrip = nil
        reopenablePlans = nil
        fillSuggestion = nil
        faceCorners = []
        gesture = .idle
        inkPath = []
        inkPrediction = []
        lassoPath = []
        snapshotVersionFloor = (max(snapshotVersionFloor.0, mesh.positionVersion), max(snapshotVersionFloor.1, mesh.topologyVersion))
    }

    // MARK: Pencil input

    public var minimumStrokeLength: Float { 8 }
    /// How much a pencil line is steadied as it's drawn, from 0 to 1.
    public var steadiness: Float = 0.4
    private var stabilizer: StrokeStabilizer?
    /// The lines on screen as a pencil stroke starts, to see where it crosses them as it goes.
    private var strokeLines: [(a: Vec2, b: Vec2, pa: Vec3, pb: Vec3)] = []
    private var strokeLinesChecked = 0
    /// The lines and marks the rub still going has reached, shown until they go as it lifts.
    private var rubbedLines = Set<EdgeID>()
    private var rubbedMarks = Set<Int>()
    private var lastRub: Vec2?
    private var strokeSide: Float = 0
    private var strokeReachedMiddle = false

    public func pencilBegan(at screen: Vec2, pressure: Float = 1) {
        hoverElement = nil
        switch activeTool {
        case .pencil:
            guard let projector else {
                gesture = .idle
                return
            }
            if startsOnPick(screen) {
                beginSelectGesture(at: screen)
                break
            }
            var capture = StrokeCapture(camera: camera, projector: projector)
            capture.add(screen: screen, pressure: pressure)
            gesture = .stroke(capture)
            inkPath = [screen]
            stabilizer = StrokeStabilizer(start: screen, strength: steadiness)
            strokeLines = mesh.aliveEdges.compactMap { e in
                let (a, b) = mesh.ends(e)
                let pa = mesh.position(a), pb = mesh.position(b)
                guard let sa = camera.project(pa)?.screen, let sb = camera.project(pb)?.screen else { return nil }
                return (sa, sb, pa, pb)
            }
            strokeLinesChecked = 0
            overlay.previewPoints = []
            strokeSide = 0
            strokeReachedMiddle = false
            noteSide(of: capture)
        case .drawEdges, .edgeLoop, .quadStrip, .quadPatch:
            guard let projector else {
                if sources.isEmpty {
                    say("Import a model first, then draw on its surface.")
                } else {
                    say("The surface is still being prepared.")
                }
                gesture = .idle
                return
            }
            settlePending()
            var capture = StrokeCapture(camera: camera, projector: projector)
            capture.add(screen: screen, pressure: pressure)
            gesture = .stroke(capture)
            inkPath = [screen]
        case .select:
            beginSelectGesture(at: screen)
        case .face:
            gesture = .tapOnly(start: screen)
        case .moveBrush, .relaxBrush:
            let label = activeTool == .moveBrush ? "Move brush" : "Relax brush"
            gesture = .brush(before: currentSnapshot, lastHit: nil, label: label)
            brushCursor = screen
            applyBrush(at: screen, pressure: pressure)
        case .erase:
            gesture = .erase
            brushCursor = screen
            clearRub()
            rub(to: screen)
        case .sketch:
            guard let projector else {
                say(sources.isEmpty ? "Import a model first, then sketch on its surface." : "The surface is still being prepared.")
                gesture = .idle
                return
            }
            settlePending()
            showsSketch = true
            if sketchErases {
                gesture = .sketchErase(before: currentSnapshot, changed: false)
                eraseSketch(at: screen)
            } else {
                var capture = StrokeCapture(camera: camera, projector: projector)
                capture.add(screen: screen, pressure: pressure)
                gesture = .sketch(capture)
                inkPath = [screen]
            }
        }
        notify()
    }

    public func pencilMoved(to screen: Vec2, pressure: Float = 1, predicted: [Vec2] = []) {
        switch gesture {
        case .idle, .tapOnly:
            break
        case .stroke(var capture):
            if activeTool == .pencil, strokeReachedMiddle { break }
            if activeTool == .pencil, var steady = stabilizer {
                for point in steady.pull(to: screen) { capture.add(screen: point, pressure: pressure) }
                stabilizer = steady
            } else {
                capture.add(screen: screen, pressure: pressure)
            }
            noteSide(of: capture)
            gesture = .stroke(capture)
            inkPath = capture.screenPath
            inkPrediction = strokeReachedMiddle ? [] : (activeTool == .pencil ? [screen] + predicted : predicted)
            updateLiveMirrorOverlay(capture)
            if activeTool == .pencil { showPointsAhead(of: capture) }
        case .select(var drag):
            updateSelectDrag(&drag, to: screen)
            gesture = .select(drag)
        case .lasso(var points):
            if let last = points.last, simd_length(last - screen) < 2 { break }
            points.append(screen)
            gesture = .lasso(points)
            lassoPath = points
        case .brush:
            brushCursor = screen
            applyBrush(at: screen, pressure: pressure)
        case .erase:
            brushCursor = screen
            rub(to: screen)
        case .quickShape(let base, let grabbed, _):
            showQuickShape(base.dragged(from: grabbed, to: screen), base: base, grabbed: grabbed)
        case .sketch(var capture):
            capture.add(screen: screen, pressure: pressure)
            gesture = .sketch(capture)
            inkPath = capture.screenPath
            inkPrediction = predicted
        case .sketchErase:
            eraseSketch(at: screen)
        }
        notify()
    }

    public func pencilEnded(at screen: Vec2, pressure: Float = 1) {
        let finished = gesture
        gesture = .idle
        inkPrediction = []
        switch finished {
        case .idle:
            break
        case .tapOnly(let start):
            if activeTool == .face { faceToolTap(at: start) }
        case .stroke(var capture):
            if activeTool != .pencil {
                capture.add(screen: screen, pressure: pressure)
            } else if !strokeReachedMiddle {
                capture.add(screen: stabilizer?.end(at: screen) ?? screen, pressure: pressure)
            }
            inkPath = []
            finishStroke(capture, tapPoint: screen)
        case .select(let drag):
            if activeTool == .pencil, !drag.moved {
                // A press that went nowhere is a tap.
                selection = drag.before.selection
                pencilTap(at: screen)
                recordPick(from: drag.before)
            } else {
                finishSelectDrag(drag, at: screen)
                if activeTool == .pencil, !drag.staysPicked { selection.clear() }
            }
        case .lasso(let points):
            lassoPath = []
            finishLasso(points, tapPoint: screen)
        case .brush(let before, _, let label):
            brushCursor = nil
            // A stroke that reached nothing isn't worth an undo step that appears to do nothing.
            if mesh.positionVersion != before.mesh.positionVersion {
                recordEdit(before: before, label: label)
                if label == "Move brush" { onEvent?(.vertexMoved) }
            }
        case .erase:
            brushCursor = nil
            finishRub()
        case .quickShape(_, _, let shape):
            inkPath = []
            if let projector {
                var capture = StrokeCapture(camera: camera, projector: projector)
                for p in shape.points { capture.add(screen: p) }
                finishPencilStroke(capture, tapPoint: screen, shape: shape)
            }
        case .sketch(var capture):
            capture.add(screen: screen, pressure: pressure)
            inkPath = []
            finishSketch(capture)
        case .sketchErase(let before, let changed):
            if changed { recordEdit(before: before, label: "Erase sketch") }
        }
        rebuildOverlay()
        notify()
    }

    public func pencilCancelled() {
        switch gesture {
        case .brush(let before, _, _):
            install(before)
        case .erase:
            clearRub()
        case .select(let drag):
            if drag.moved { install(drag.before) }
        case .sketchErase(let before, _):
            install(before)
        default:
            break
        }
        gesture = .idle
        inkPath = []
        inkPrediction = []
        lassoPath = []
        brushCursor = nil
        rebuildOverlay()
        notify()
    }

    /// Pencil or pointer hover, for highlighting what a tap would hit. Nil when it leaves.
    public func hover(at screen: Vec2?) {
        hoverPoint = screen
        if activeTool.isBrush { brushCursor = screen }
        guard let screen else {
            hoverElement = nil
            notify()
            return
        }
        var picker = MeshPicker(camera: camera, mesh: mesh, projector: projector)
        picker.ignoresOcclusion = ignoresOcclusionForPicking
        switch activeTool {
        case .select:
            hoverElement = picker.pick(at: screen, mode: selection.mode, radius: pickRadius)
        case .quadPatch:
            hoverElement = picker.pickEdge(at: screen, radius: pickRadius).map { .edge($0.0, t: $0.t) }
        case .pencil, .face, .drawEdges, .edgeLoop, .quadStrip:
            hoverElement = picker.pickVertex(at: screen, radius: tools.stroke.snapRadiusPoints).map { .vertex($0) }
        default:
            hoverElement = nil
        }
        notify()
    }

    private var pickRadius: Float { 24 }

    // MARK: Stroke handling

    private func finishStroke(_ capture: StrokeCapture, tapPoint: Vec2) {
        if activeTool == .pencil {
            finishPencilStroke(capture, tapPoint: tapPoint)
            return
        }
        overlay.mirrorEdges = []
        if capture.screenLength < minimumStrokeLength {
            if activeTool == .quadPatch || (activeTool == .drawEdges && hasFreeEdge(at: tapPoint)) {
                patchTap(at: tapPoint)
            } else {
                say("Draw a longer line to make edges. Very short strokes are ignored so that stray touches don't add topology.")
            }
            return
        }
        guard let projector else { return }
        let runs = capture.usableRuns
        guard !runs.isEmpty else {
            say("That stroke missed the model, so nothing was added.", kind: .warning)
            return
        }

        let settings = tools.stroke
        let midpoint = runs[0][runs[0].count / 2].position
        let scale = camera.worldPerPoint(at: midpoint)
        let closeRadius = settings.closeRadiusPoints * scale
        var paths: [ProcessedPath] = []
        for run in runs {
            if let path = StrokeProcessor.process(run: run, settings: settings, projector: projector, closeRadius: closeRadius) {
                paths.append(path)
            }
        }
        guard !paths.isEmpty else {
            say("That stroke was too short to make an edge.", kind: .warning)
            return
        }
        let broken = paths.count > 1 || capture.hasGaps

        if activeTool == .quadStrip {
            // Long enough parts of a broken stroke would all compete for the strip, so use the longest.
            let longest = paths.max { $0.length < $1.length }!
            startStrip(path: longest, broken: paths.count > 1)
            return
        }

        let options = strokeOptions(scale: scale)
        var plans = paths.map { path -> StrokePlan in
            StrokePlanner.plan(path: prepared(path), mesh: mesh, options: options)
        }

        if activeTool == .edgeLoop {
            guard paths.count == 1 else {
                pendingStroke = PendingStroke(paths: paths, plans: plans, canClose: false, closedPlan: nil, note: "The stroke crossed a gap in the surface, so the loop is incomplete. Commit these parts and bridge the gap with another stroke, or cancel and try a different view.")
                return
            }
            if paths[0].canClose {
                let closed = StrokeProcessor.closed(paths[0], spacing: settings.edgeLength, projector: projector)
                let plan = StrokePlanner.plan(path: prepared(closed), mesh: mesh, options: options)
                offerFill(after: apply(plans: [plan], label: "Draw loop", event: .loopClosed))
                return
            }
            pendingStroke = PendingStroke(paths: paths, plans: plans, canClose: true, closedPlan: closedPlan(paths[0], options: options), note: "The ends are too far apart to close this loop without guessing. Commit it open, close it anyway with a straight edge, or cancel.")
            return
        }

        // In Draw Edges, once a line is picked, the next stroke is the next side of the patch.
        if activeTool == .quadPatch || (activeTool == .drawEdges && !patchChains.isEmpty) {
            // A drawn shape is a loop to fill, even if the ends didn't quite meet.
            if paths.count == 1, paths[0].canClose {
                let closed = closedPlan(paths[0], options: options)
                if !closed.plan.isEmpty { plans = [closed] }
            }
            let result = apply(plans: plans, label: "Draw chain", event: .strokeCommitted)
            if let result, let chain = drawnChain(result) {
                addPatchChain(chain)
            }
            return
        }

        if paths.count == 1 && paths[0].canClose {
            let closed = closedPlan(paths[0], options: options)
            guard closesLoopsAutomatically, !closed.plan.isEmpty else {
                pendingStroke = PendingStroke(paths: paths, plans: plans, canClose: true, closedPlan: closed, note: nil)
                return
            }
            if let result = apply(plans: [closed], label: "Draw loop", event: .loopClosed) {
                reopenablePlans = plans
                offerFill(after: result)
                rebuildOverlay()
            }
            return
        }
        let overFaces = plans.contains(where: \.droppedOverFaces)
        // One part means the stroke only ran off the silhouette at an end. That needs no question.
        if broken && paths.count > 1 {
            pendingStroke = PendingStroke(paths: paths, plans: plans, canClose: false, closedPlan: nil, note: "The stroke crossed a gap in the surface and broke into \(paths.count) parts. Nothing fills the gap automatically.")
            return
        }
        if overFaces {
            pendingStroke = PendingStroke(paths: paths, plans: plans, canClose: false, closedPlan: nil, note: plans[0].plan.notes.first)
            return
        }
        plans.removeAll { $0.plan.isEmpty }
        let result = apply(plans: plans, label: "Draw edges", event: .strokeCommitted)
        report(plans, result: result)
        offerFill(after: result)
    }

    // MARK: The pencil

    /// How finely a pencil line follows the stroke, on screen. Only its real points are topology.
    static let bendSpacingPoints: Float = 8

    /// The pencil mark a tap picked, by its place in `sketches`.
    public private(set) var pickedMark: Int?

    /// The Pencil has rested on a point for long enough to pick it up rather than draw from it.
    public func pencilHeld() {
        guard activeTool == .pencil, case .stroke(let capture) = gesture,
              capture.screenLength < tapSlop, let start = capture.screenPath.first else { return }
        var picker = MeshPicker(camera: camera, mesh: mesh, projector: projector)
        picker.ignoresOcclusion = ignoresOcclusionForPicking
        guard let vertex = picker.pickVertex(at: start, radius: pickRadius) else { return }
        inkPath = []
        let before = currentSnapshot
        selection.clear()
        selection.mode = .vertex
        selection.vertices = [vertex]
        beginSelectGesture(at: start)
        if case .select(var drag) = gesture {
            drag.before = before
            drag.staysPicked = false
            gesture = .select(drag)
        }
        rebuildOverlay()
        notify()
    }

    /// The Pencil has rested partway through a stroke. If it looks like it's going for a shape, it
    /// becomes that shape. Nothing's made until it lifts.
    public func pencilPaused(at screen: Vec2) {
        guard activeTool == .pencil, !strokeReachedMiddle, case .stroke(let capture) = gesture,
              let shape = QuickShape.recognize(capture.screenPath + [screen]) else { return }
        overlay.previewPoints = []
        inkPrediction = []
        showQuickShape(shape, base: shape, grabbed: screen)
        notify()
    }

    private func showQuickShape(_ shape: QuickShape, base: QuickShape, grabbed: Vec2) {
        gesture = .quickShape(base: base, grabbed: grabbed, current: shape)
        inkPath = shape.points
        guard let plane = symmetry.activePlane, let projector else { return }
        // Mirrored points are only shown, so a rough outline will do, and this runs at Pencil rate.
        let step = max(shape.points.count / 64, 1)
        var outline: [Vec3] = []
        for i in stride(from: 0, to: shape.points.count, by: step) {
            if let hit = projector.raycast(camera.ray(through: shape.points[i])) { outline.append(plane.reflect(hit.position)) }
        }
        overlay.mirrorEdges = zip(outline, outline.dropFirst()).flatMap { [$0, $1] }
    }

    /// Where a clean shape's corners land on the surface, on the point of the path nearest each one.
    private func placeCorners(of shape: QuickShape, on path: inout ProcessedPath) {
        guard let projector else { return }
        for corner in shape.corners {
            guard let i = path.points.indices.min(by: { simd_length(path.points[$0].screen - corner) < simd_length(path.points[$1].screen - corner) }),
                  let hit = projector.raycast(camera.ray(through: corner)) else { continue }
            path.points[i].position = hit.position
            path.points[i].normal = hit.normal
            path.points[i].isCorner = true
        }
    }

    private func finishPencilStroke(_ capture: StrokeCapture, tapPoint: Vec2, shape: QuickShape? = nil) {
        overlay.mirrorEdges = []
        guard capture.screenLength >= minimumStrokeLength else {
            let before = currentSnapshot
            pencilTap(at: tapPoint)
            recordPick(from: before)
            return
        }
        pickedMark = nil
        guard let projector else { return }
        // Scraps from where a stroke clipped an edge of the model would be tiny lines of their own.
        let runs = capture.usableRuns.filter { run in
            zip(run, run.dropFirst()).reduce(Float(0)) { $0 + simd_length($1.1.screen - $1.0.screen) } >= minimumStrokeLength
        }
        guard !runs.isEmpty else { return }
        let scale = camera.worldPerPoint(at: runs[0][runs[0].count / 2].position)
        let closeRadius = tools.stroke.closeRadiusPoints * scale
        tools.stroke.edgeLength = Self.bendSpacingPoints * scale
        var settings = tools.stroke
        // A clean shape has nothing to steady, and smoothing would round its corners.
        if shape != nil { settings.smoothing = 0 }
        var paths = runs.compactMap { StrokeProcessor.process(run: $0, settings: settings, projector: projector, closeRadius: closeRadius) }
        if let shape {
            for i in paths.indices { placeCorners(of: shape, on: &paths[i]) }
        }
        if let plane = symmetry.activePlane {
            var kept: [ProcessedPath] = []
            for path in paths {
                let (path, reachedMiddle) = keptToOneSide(path, plane: plane, reach: tools.stroke.snapRadiusPoints * scale)
                kept.append(path)
                if reachedMiddle { break }
            }
            paths = kept
        }
        if paths.count == 1, paths[0].canClose, closesLoopsAutomatically || shape?.isClosed == true {
            paths = [StrokeProcessor.closed(paths[0], spacing: tools.stroke.edgeLength, projector: projector)]
        }
        guard !paths.isEmpty else {
            keepAsMark(capture)
            return
        }
        var options = strokeOptions(scale: scale)
        options.camera = camera
        options.snapRadiusPoints = tools.stroke.snapRadiusPoints
        options.mirror = symmetry.activePlane

        let quadsBefore = mesh.aliveFaces.filter(mesh.isQuad).count
        let inkedBefore = InkingIn.Inked(mesh)
        var straightened: [StraightenedSide] = []
        let isLoop = paths.contains(where: \.isClosed)
        let ok = perform(isLoop ? "Draw loop" : "Draw line") { mesh, selection in
            var total = PlanResult()
            var met: [VertexID] = []
            for path in paths {
                let plan = StrokePlanner.plan(path: prepared(path), mesh: mesh, options: options)
                guard !plan.plan.nodes.isEmpty else { continue }
                let result = try PlanApplier.apply(plan.plan, to: &mesh, symmetry: symmetry, projector: projector)
                total.edges += result.edges
                met += result.nodeVertices
            }
            guard !met.isEmpty else { throw MeshError.invalid("Nothing to add.") }
            straightened = try DrawnFaces.update(after: total, met: met.filter { !mesh.isBendVertex($0) }, in: &mesh, projector: projector, symmetry: symmetry)
            selection.clear()
        }
        clearMessage()
        guard ok else {
            keepAsMark(capture)
            return
        }
        inkingIn = InkingIn(generation: inkingIn.generation &+ 1, mesh: mesh, before: inkedBefore, straightened: straightened)
        if mesh.aliveFaces.filter(mesh.isQuad).count > quadsBefore {
            onEvent?(.facesGenerated)
        } else {
            onEvent?(isLoop ? .loopClosed : .strokeCommitted)
        }
    }

    /// A mark that can't become topology stays on the model as a pencil line, as it would on paper.
    private func keepAsMark(_ capture: StrokeCapture) {
        showsSketch = true
        finishSketch(capture, colorIndex: SketchPalette.graphite)
    }

    public var hasPick: Bool { pickedMark != nil || !selection.isEmpty }

    public func clearPick() {
        if pickedMark != nil {
            pickedMark = nil
            sketchRevision &+= 1
        }
        selection.clear()
        rebuildOverlay()
        notify()
    }

    /// What's stopping a picked shape from being a quad.
    public var pickNote: String? {
        guard selection.faces.count == 1, let face = selection.faces.first, mesh.isFaceAlive(face), !mesh.isQuad(face) else { return nil }
        let corners = mesh.cornerCount(of: face)
        if corners == 4 { return "4 points, but a side curves too far to go straight" }
        return corners == 1 ? "1 point" : "\(corners) points"
    }

    /// Whether the picked shape can become quads using the points already on its sides, which takes an
    /// even number of them. Four would already be a quad.
    public var canFillPick: Bool {
        guard selection.faces.count == 1, let face = selection.faces.first, mesh.isFaceAlive(face) else { return false }
        let corners = mesh.cornerCount(of: face)
        return corners >= 6 && corners.isMultiple(of: 2)
    }

    /// Fills the picked shape with quads between the points on its sides. No points are made up along
    /// them, so the rows are the ones the drawing already set out.
    public func fillPick() {
        guard canFillPick, let face = selection.faces.first else { return }
        let ok = perform("Fill") { mesh, selection in
            var loops = [mesh.loop(face)]
            if symmetry.isEnabled {
                loops = Symmetry.expanded(faces: [face], in: mesh).map { mesh.loop($0) }
                loops.sort { a, _ in a.contains(mesh.loop(face)[0]) }
            }
            var plan: TopologyPlan?
            for loop in loops {
                for v in loop where mesh.isVertexAlive(v) && mesh.isBendVertex(v) { try mesh.dissolveVertex(v) }
                let corners = loop.filter(mesh.isVertexAlive)
                if let f = mesh.findFace(withVertices: corners) { mesh.removeFace(f) }
                guard plan == nil else { continue }
                let edges = corners.indices.compactMap { mesh.edge(between: corners[$0], corners[($0 + 1) % corners.count]) }
                let chain = BoundaryChain(vertices: corners, edges: edges, isClosed: true)
                plan = try QuadPatchBuilder.plan(chains: [chain], parameters: tools.patch, mesh: mesh, projector: projector).plan
            }
            if let plan { _ = try PlanApplier.apply(plan, to: &mesh, symmetry: symmetry, projector: projector) }
            selection.clear()
        }
        if ok { onEvent?(.facesGenerated) }
        clearMessage()
        rebuildOverlay()
        notify()
    }

    /// Takes out the picked line, quads or pencil mark.
    public func deletePick() {
        if let index = pickedMark, sketches.indices.contains(index) {
            let before = currentSnapshot
            sketches.remove(at: index)
            sketchRevision &+= 1
            pickedMark = nil
            recordEdit(before: before, label: "Erase mark")
        } else if selection.mode == .face {
            deleteSelection()
            clearMessage()
        } else {
            let before = currentSnapshot
            let points = selection.vertices, lines = selection.edges
            for v in points where mesh.isVertexAlive(v) { erasePoint(v) }
            if !lines.isEmpty { eraseLines(lines) }
            selection.clear()
            recordEdit(before: before, label: "Delete")
        }
        rebuildOverlay()
        notify()
    }

    /// Whether a press landed on what's picked, which picks it up rather than drawing from it.
    private func startsOnPick(_ screen: Vec2) -> Bool {
        guard !selection.isEmpty else { return false }
        var picker = MeshPicker(camera: camera, mesh: mesh, projector: projector)
        picker.ignoresOcclusion = ignoresOcclusionForPicking
        return picker.pick(at: screen, mode: selection.mode, radius: pickRadius).map(isSelected) ?? false
    }

    /// How close to a point a tap has to be to pick it rather than a line running through it.
    private static let pointPickReach: Float = 14
    /// How close to a line between two shapes a tap has to be to pick it rather than a shape, which is
    /// closer than for other lines since the shapes have to stay easy to tap.
    private static let sharedLinePickReach: Float = 8

    /// An edge and whatever carries it on through bends, up to the real point at each end.
    private func lineBetweenPoints(through edge: EdgeID) -> Set<EdgeID> {
        var line: Set<EdgeID> = [edge]
        let (a, b) = mesh.ends(edge)
        for start in [a, b] {
            var current = start
            while mesh.isBendVertex(current), let next = mesh.edgesOf(current).first(where: { !line.contains($0) }) {
                line.insert(next)
                current = mesh.otherEnd(next, from: current)
            }
        }
        return line
    }

    /// Puts a dot wherever the stroke so far has crossed a line, which is where it's making a point.
    private func showPointsAhead(of capture: StrokeCapture) {
        let path = capture.screenPath
        var picker = MeshPicker(camera: camera, mesh: mesh, projector: projector)
        picker.ignoresOcclusion = ignoresOcclusionForPicking
        func add(_ p: Vec3) {
            let plane = symmetry.activePlane
            for dot in [p] + (plane.map { [$0.reflect(p)] } ?? []) where !overlay.previewPoints.contains(where: { simd_length($0 - dot) < 1e-4 }) {
                overlay.previewPoints.append(dot)
            }
        }
        while strokeLinesChecked + 1 < path.count {
            let p = path[strokeLinesChecked], stroke = path[strokeLinesChecked + 1] - p
            strokeLinesChecked += 1
            for line in strokeLines {
                let span = line.b - line.a
                let denominator = stroke.x * span.y - stroke.y * span.x
                guard abs(denominator) > 1e-6 else { continue }
                let gap = line.a - p
                let s = (gap.x * span.y - gap.y * span.x) / denominator
                let t = (gap.x * stroke.y - gap.y * stroke.x) / denominator
                guard s >= 0, s <= 1, t >= 0, t <= 1 else { continue }
                let onLine = simd_mix(line.pa, line.pb, Vec3(repeating: t))
                guard picker.isVisible(onLine, normal: nil) else { continue }
                // A crossing right beside a point uses that point.
                let here = p + stroke * s
                let reach = tools.stroke.snapRadiusPoints * 0.75
                let beside = (t < 0.5 ? [line.pa, line.pb] : [line.pb, line.pa]).first { end in
                    guard let there = camera.project(end)?.screen, simd_length(there - here) <= reach else { return false }
                    return mesh.aliveVertices.contains { !mesh.isBendVertex($0) && mesh.position($0) == end }
                }
                add(beside ?? onLine)
            }
        }
        if strokeReachedMiddle, let plane = symmetry.activePlane, let end = capture.runs.last?.last { add(plane.snap(end.position)) }
    }

    /// With mirror on, a pencil line belongs to the side it starts on, so it stops once it gets past the middle.
    private func noteSide(of capture: StrokeCapture) {
        guard let plane = symmetry.activePlane, let point = capture.runs.last?.last else { return }
        let d = plane.signedDistance(point.position)
        if strokeSide == 0 {
            if abs(d) > tools.stroke.snapRadiusPoints * camera.worldPerPoint(at: point.position) { strokeSide = d < 0 ? -1 : 1 }
        } else if d * strokeSide < 0 {
            strokeReachedMiddle = true
        }
    }

    /// Keeps a line to one side of the mirror, up to the middle and no further. An end that stops short
    /// of the middle reaches it, unless it's already beside a point of its own to land on.
    private func keptToOneSide(_ path: ProcessedPath, plane: MirrorPlane, reach: Float) -> (path: ProcessedPath, reachedMiddle: Bool) {
        let points = path.points
        let distances = points.map { plane.signedDistance($0.position) }
        guard let first = distances.first(where: { abs($0) > reach }) else { return (path, false) }
        let side: Float = first < 0 ? -1 : 1
        func onPlane(_ i: Int) -> StrokePoint {
            let t = distances[i - 1] / (distances[i - 1] - distances[i])
            var crossing = points[i - 1]
            crossing.position = plane.snap(simd_mix(points[i - 1].position, points[i].position, Vec3(repeating: t)))
            crossing.normal = GeometryMath.safeNormalize(simd_mix(points[i - 1].normal, points[i].normal, Vec3(repeating: t)), fallback: points[i].normal)
            return crossing
        }
        var kept: [StrokePoint] = []
        var crossed = false
        for i in points.indices {
            if distances[i] * side >= 0 {
                if kept.isEmpty, i > 0 { kept.append(onPlane(i)) }
                kept.append(points[i])
            } else if !kept.isEmpty {
                kept.append(onPlane(i))
                crossed = true
                break
            }
        }
        var out = path
        if crossed || kept.count != points.count {
            out.canClose = false
            out.isClosed = false
        }
        guard !out.canClose else { return (out, crossed) }
        func reaches(_ p: StrokePoint) -> Bool {
            let d = abs(plane.signedDistance(p.position))
            guard d > 0, d <= reach else { return false }
            return !mesh.aliveVertices.contains { !mesh.isBendVertex($0) && simd_length(mesh.position($0) - p.position) <= reach }
        }
        func extended(_ p: StrokePoint) -> StrokePoint {
            var end = p
            end.position = plane.snap(p.position)
            return end
        }
        if let start = kept.first, reaches(start) { kept.insert(extended(start), at: 0) }
        if !crossed, let end = kept.last, reaches(end) { kept.append(extended(end)) }
        // Points right beside the one on the middle would count as on it too, and make two.
        let beside = symmetry.centerTolerance * 2
        func isBeside(_ p: StrokePoint) -> Bool { abs(plane.signedDistance(p.position)) <= beside }
        if plane.signedDistance(kept[0].position) == 0 { while kept.count > 2, isBeside(kept[1]) { kept.remove(at: 1) } }
        if plane.signedDistance(kept[kept.count - 1].position) == 0 { while kept.count > 2, isBeside(kept[kept.count - 2]) { kept.remove(at: kept.count - 2) } }
        out.points = kept
        out.length = StrokeProcessor.polylineLength(kept)
        out.endGap = kept.count > 1 ? simd_length(kept[0].position - kept[kept.count - 1].position) : 0
        return (out, crossed)
    }

    /// A tap picks what's under it: a point, a whole line, or a quad, with further quads adding to the pick.
    private func pencilTap(at screen: Vec2) {
        var picker = MeshPicker(camera: camera, mesh: mesh, projector: projector)
        picker.ignoresOcclusion = ignoresOcclusionForPicking
        pickedMark = showsSketch ? sketches.lastIndex { touches($0, at: screen) } : nil
        if pickedMark != nil {
            selection.clear()
            sketchRevision &+= 1
            return
        }
        if let vertex = picker.pickVertex(at: screen, radius: Self.pointPickReach) {
            let wasPicked = selection.mode == .vertex && selection.vertices == [vertex]
            selection.clear()
            selection.mode = .vertex
            if !wasPicked { selection.vertices = [vertex] }
        } else if let (edge, _) = picker.pickEdge(at: screen, radius: pickRadius, where: { mesh.faceCountOf(edge: $0) < 2 }),
                  let chain = ChainFinder.chain(through: edge, in: mesh) {
            selection.clear()
            selection.mode = .edge
            selection.edges = Set(chain.edges)
        } else if let (edge, _) = picker.pickEdge(at: screen, radius: Self.sharedLinePickReach) {
            selection.clear()
            selection.mode = .edge
            selection.edges = lineBetweenPoints(through: edge)
        } else if let face = picker.pickFace(at: screen) {
            if selection.mode != .face { selection.clear() }
            selection.mode = .face
            if selection.faces.contains(face) {
                selection.faces.remove(face)
            } else {
                selection.faces.insert(face)
            }
        } else {
            selection.clear()
        }
    }

    /// Says what a stroke did to the lines it met, when that's more than adding edges.
    private func report(_ plans: [StrokePlan], result: PlanResult?) {
        guard let result else { return }
        if let chain = drawnChain(result), chain.isClosed, !plans.contains(where: \.isClosed) {
            say("Closed the line into a loop.", kind: .success)
            onEvent?(.loopClosed)
        } else if let connected = plans.map(\.connectedLines).max(), connected >= 2 {
            say("Connected \(connected) lines.", kind: .success)
            onEvent?(.strokeSnapped)
        } else if plans.contains(where: \.extendsLine) {
            say("Extended the line.", kind: .success)
            onEvent?(.strokeSnapped)
        } else if plans.contains(where: { $0.snappedEnds > 0 }) {
            onEvent?(.strokeSnapped)
        }
    }

    private func hasFreeEdge(at screen: Vec2) -> Bool {
        var picker = MeshPicker(camera: camera, mesh: mesh, projector: projector)
        picker.ignoresOcclusion = ignoresOcclusionForPicking
        guard let (edge, _) = picker.pickEdge(at: screen, radius: pickRadius) else { return false }
        return mesh.faceCountOf(edge: edge) < 2
    }

    private func closedPlan(_ path: ProcessedPath, options: StrokePlanOptions) -> StrokePlan {
        StrokePlanner.plan(path: prepared(StrokeProcessor.closed(path, spacing: tools.stroke.edgeLength, projector: projector)), mesh: mesh, options: options)
    }

    /// The whole of what a stroke just drew, as one chain when it can be, even where it crossed other
    /// lines, and along with any line it carried on from. Otherwise the free run through its first edge.
    private func drawnChain(_ result: PlanResult, in other: Mesh? = nil) -> BoundaryChain? {
        let mesh = other ?? self.mesh
        if let chain = ChainFinder.chain(from: Set(result.edges), in: mesh), chain.edges.allSatisfy({ mesh.faceCountOf(edge: $0) < 2 }) {
            if !chain.isClosed, let whole = ChainFinder.chain(through: chain.edges[0], in: mesh), whole.edges.count > chain.edges.count,
               Set(chain.edges).isSubset(of: whole.edges) {
                return whole
            }
            return chain
        }
        return result.edges.first.flatMap { ChainFinder.chain(through: $0, in: mesh) }
    }

    /// Undoes the loop a stroke closed into, and adds that stroke as it was drawn.
    public func keepLoopOpen() {
        guard let plans = reopenablePlans else { return }
        undo()
        clearMessage()
        apply(plans: plans, label: "Draw edges", event: .strokeCommitted)
    }

    private func offerFill(after result: PlanResult?) {
        guard suggestsFills, let result, let chain = drawnChain(result),
              let other = NeighborChains.neighbor(of: chain, in: mesh, projector: projector, mirror: symmetry.activePlane),
              let preview = try? QuadPatchBuilder.plan(chains: [other, chain], parameters: tools.patch, mesh: mesh, projector: projector, linesYieldToFaces: true)
        else { return }
        fillSuggestion = FillSuggestion(chains: [other, chain], preview: preview)
        rebuildOverlay()
    }

    public func commitFillSuggestion() {
        guard let suggestion = fillSuggestion else { return }
        fillSuggestion = nil
        let plan = suggestion.preview.plan
        let ok = perform("Quad patch") { mesh, selection in
            _ = try PlanApplier.apply(plan, to: &mesh, symmetry: symmetry, projector: projector)
            selection.clear()
        }
        if ok {
            if !plan.notes.isEmpty { say(plan.notes.joined(separator: " ")) }
            onEvent?(.facesGenerated)
        }
        rebuildOverlay()
        notify()
    }

    public func dismissFillSuggestion() {
        fillSuggestion = nil
        rebuildOverlay()
        notify()
    }

    private func strokeOptions(scale: Float) -> StrokePlanOptions {
        var options = StrokePlanOptions(snapRadius: tools.stroke.snapRadiusPoints * scale, crossingTolerance: max(5 * scale, tools.stroke.edgeLength * 0.15), projector: projector)
        options.lineEndRadius = tools.stroke.closeRadiusPoints * scale
        options.surfaceOffset = projector?.surfaceOffset ?? 0
        return options
    }

    /// Under symmetry, gives the path an exact vertex where it crosses the plane: the mirrored stroke
    /// then shares it, with no doubled center vertices.
    private func prepared(_ path: ProcessedPath) -> ProcessedPath {
        guard let plane = symmetry.activePlane else { return path }
        var points: [StrokePoint] = []
        let n = path.points.count
        let tolerance = symmetry.centerTolerance
        let count = path.isClosed ? n : n - 1
        for i in 0..<count {
            let a = path.points[i], b = path.points[(i + 1) % n]
            points.append(a)
            let da = plane.signedDistance(a.position), db = plane.signedDistance(b.position)
            if da * db < 0 && abs(da) > tolerance && abs(db) > tolerance {
                let t = da / (da - db)
                var crossing = a
                crossing.position = plane.snap(simd_mix(a.position, b.position, Vec3(repeating: t)))
                crossing.normal = GeometryMath.safeNormalize(simd_mix(a.normal, b.normal, Vec3(repeating: t)), fallback: a.normal)
                points.append(crossing)
            }
        }
        if !path.isClosed { points.append(path.points[n - 1]) }
        var out = path
        out.points = points
        return out
    }

    @discardableResult
    private func apply(plans: [StrokePlan], label: String, event: EngineEvent) -> PlanResult? {
        let usable = plans.filter { !$0.plan.isEmpty }
        guard !usable.isEmpty else {
            say("Nothing to add: that stroke lay entirely over existing faces.", kind: .warning)
            return nil
        }
        var total = PlanResult()
        let ok = perform(label) { mesh, selection in
            for plan in usable {
                let result = try PlanApplier.apply(plan.plan, to: &mesh, symmetry: symmetry, projector: projector)
                total.edges += result.edges
                total.faces += result.faces
                total.vertices += result.vertices
            }
            selection.clear()
        }
        guard ok else { return nil }
        let notes = usable.flatMap(\.plan.notes)
        if !notes.isEmpty { say(notes.joined(separator: " ")) }
        onEvent?(event)
        return total
    }

    public func commitPendingStroke(close: Bool) {
        guard let pending = pendingStroke else { return }
        pendingStroke = nil
        if close, let closed = pending.closedPlan {
            offerFill(after: apply(plans: [closed], label: "Draw loop", event: .loopClosed))
        } else {
            apply(plans: pending.plans, label: "Draw edges", event: .strokeCommitted)
        }
        rebuildOverlay()
        notify()
    }

    public func cancelPending() {
        pendingStroke = nil
        pendingStrip = nil
        rebuildOverlay()
        notify()
    }

    // MARK: Quad strip

    private func startStrip(path: ProcessedPath, broken: Bool, closes: Bool = true) {
        var working = path
        var openPath: ProcessedPath?
        if closes, closesLoopsAutomatically, !broken, path.canClose {
            working = StrokeProcessor.closed(path, spacing: tools.stroke.edgeLength, projector: projector)
            openPath = path
        }
        var clipped = false
        if let plane = symmetry.activePlane {
            let clippedPath = clipToStartSide(working, plane: plane)
            clipped = clippedPath.points.count != working.points.count
            working = clippedPath
            if clipped { openPath = nil }
        }
        pendingStrip = PendingStrip(path: working, clippedAtCenterline: clipped, openPath: openPath)
        rebuildStripPlan()
        if broken { say("The stroke crossed a gap in the surface, so this uses its longest part.", kind: .warning) }
    }

    /// Turns a strip that closed into a ring back into the stroke as drawn.
    public func keepStripOpen() {
        guard let open = pendingStrip?.openPath else { return }
        startStrip(path: open, broken: false, closes: false)
    }

    /// Keeps the part of a path before it first crosses the plane, ending exactly on the plane.
    private func clipToStartSide(_ path: ProcessedPath, plane: MirrorPlane) -> ProcessedPath {
        guard path.points.count >= 2 else { return path }
        let startSign = plane.signedDistance(path.points[0].position)
        var points = [path.points[0]]
        for i in 1..<path.points.count {
            let p = path.points[i]
            let d = plane.signedDistance(p.position)
            if d * startSign < 0 {
                let prev = path.points[i - 1]
                let dPrev = plane.signedDistance(prev.position)
                let t = dPrev / (dPrev - d)
                var crossing = prev
                crossing.position = plane.snap(simd_mix(prev.position, p.position, Vec3(repeating: t)))
                points.append(crossing)
                var out = path
                out.points = points
                out.length = StrokeProcessor.polylineLength(points)
                out.canClose = false
                out.isClosed = false
                return out
            }
            points.append(p)
        }
        return path
    }

    /// Re-evaluates the pending strip with the current parameters, so sliders preview live.
    public func rebuildStripPlan() {
        guard var pending = pendingStrip else { return }
        let scale = camera.worldPerPoint(at: pending.path.points[pending.path.points.count / 2].position)
        do {
            var plan = try QuadStripBuilder.plan(path: pending.path, parameters: tools.strip, mesh: mesh, projector: projector, snapRadius: tools.stroke.snapRadiusPoints * scale)
            if pending.clippedAtCenterline, let plane = symmetry.activePlane {
                // The final cross-section lies on the plane so that the mirrored half meets it there.
                let stride = max(1, tools.strip.crossSegments) + 1
                let columns = plan.nodes.count / stride
                for k in 0..<stride {
                    let index = (columns - 1) * stride + k
                    if case .new(let p, let n) = plan.nodes[index] {
                        plan.nodes[index] = .new(position: plane.snap(p), normal: n)
                    }
                }
                plan.notes.append("The strip stops at the symmetry plane, and its mirror image completes it.")
            }
            pending.plan = plan
            pending.error = nil
        } catch {
            pending.plan = nil
            pending.error = error.localizedDescription
        }
        pendingStrip = pending
        rebuildOverlay()
        notify()
    }

    public func commitPendingStrip() {
        guard let pending = pendingStrip else { return }
        pendingStrip = nil
        guard let plan = pending.plan else {
            if let error = pending.error { say(error, kind: .error) }
            rebuildOverlay()
            notify()
            return
        }
        // Nothing stays selected, so the next drag in Select moves one vertex rather than all of this.
        let ok = perform("Quad strip") { mesh, selection in
            _ = try PlanApplier.apply(plan, to: &mesh, symmetry: symmetry, projector: projector)
            selection.clear()
        }
        if ok {
            if !plan.notes.isEmpty { say(plan.notes.joined(separator: " ")) }
            onEvent?(.facesGenerated)
        }
    }

    // MARK: Quad patch

    /// Picks the chain under the Pencil, or unpicks it when it's already picked.
    public func patchTap(at screen: Vec2) {
        var picker = MeshPicker(camera: camera, mesh: mesh, projector: projector)
        picker.ignoresOcclusion = ignoresOcclusionForPicking
        guard let (edge, _) = picker.pickEdge(at: screen, radius: pickRadius) else {
            say("Tap an edge to use its chain as a side of the patch, or draw a new one.")
            return
        }
        if let i = patchChains.firstIndex(where: { $0.edges.contains(edge) }) {
            patchChains.remove(at: i)
            updatePatchPreview()
            return
        }
        guard let chain = ChainFinder.chain(through: edge, in: mesh) else {
            say("This edge already has a face on both sides, so a patch can't attach to it.", kind: .warning)
            return
        }
        addPatchChain(chain)
    }

    public func addPatchChain(_ chain: BoundaryChain) {
        guard patchChains.count < 4 else {
            say("A patch has at most four sides. Tap a chain to remove it first.", kind: .warning)
            return
        }
        if patchChains.contains(where: { !Set($0.edges).isDisjoint(with: chain.edges) }) { return }
        patchChains.append(chain)
        updatePatchPreview()
    }

    /// Uses the selected edges as one patch side.
    public func addPatchChainFromSelection() {
        guard let chain = ChainFinder.chain(from: selection.edges, in: mesh) else {
            say("The selected edges don't form a single connected chain.", kind: .warning)
            return
        }
        addPatchChain(chain)
    }

    public func clearPatchPicks() {
        patchChains = []
        patchPreview = nil
        patchError = nil
        rebuildOverlay()
        notify()
    }

    public func updatePatchPreview() {
        patchPreview = nil
        patchError = nil
        if patchChains.isEmpty {
            rebuildOverlay()
            notify()
            return
        }
        if patchChains.count == 1 && !patchChains[0].isClosed {
            patchError = nil
            rebuildOverlay()
            notify()
            return
        }
        do {
            patchPreview = try QuadPatchBuilder.plan(chains: patchChains, parameters: tools.patch, mesh: mesh, projector: projector)
        } catch {
            patchError = error.localizedDescription
        }
        rebuildOverlay()
        notify()
    }

    public func commitPatch() {
        guard let preview = patchPreview else {
            if let patchError { say(patchError, kind: .error) }
            return
        }
        // Nothing stays selected, so the next drag in Select moves one vertex rather than all of this.
        let ok = perform("Quad patch") { mesh, selection in
            _ = try PlanApplier.apply(preview.plan, to: &mesh, symmetry: symmetry, projector: projector)
            selection.clear()
        }
        guard ok else { return }
        if !preview.plan.notes.isEmpty { say(preview.plan.notes.joined(separator: " ")) }
        patchChains = []
        patchPreview = nil
        patchError = nil
        rebuildOverlay()
        onEvent?(.facesGenerated)
        onEvent?(.patchCreated)
        notify()
    }

    private func refreshPatchChains() {
        guard !patchChains.isEmpty else { return }
        var refreshed: [BoundaryChain] = []
        for chain in patchChains {
            if let edge = chain.edges.first(where: mesh.isEdgeAlive), let updated = ChainFinder.chain(through: edge, in: mesh) {
                refreshed.append(updated)
            }
        }
        patchChains = refreshed
        updatePatchPreview()
    }

    // MARK: Manual faces

    /// Pencil taps build a face: on an existing vertex, an edge, or empty surface.
    public func faceToolTap(at screen: Vec2) {
        var picker = MeshPicker(camera: camera, mesh: mesh, projector: projector)
        picker.ignoresOcclusion = ignoresOcclusionForPicking
        let corner: FaceCorner
        if let v = picker.pickVertex(at: screen, radius: tools.stroke.snapRadiusPoints) {
            if faceCorners.first == .vertex(v), faceCorners.count >= 3 {
                commitFaceBuilder()
                return
            }
            guard !faceCorners.contains(.vertex(v)) else {
                say("That vertex is already part of this face.", kind: .warning)
                return
            }
            corner = .vertex(v)
        } else if let (e, t) = picker.pickEdge(at: screen, radius: tools.stroke.snapRadiusPoints * 0.6), t > 0.1, t < 0.9, mesh.faceCountOf(edge: e) < 2 {
            let (a, b) = mesh.ends(e)
            corner = .edgePoint(e, t: t, position: simd_mix(mesh.position(a), mesh.position(b), Vec3(repeating: t)))
        } else if let hit = projector?.raycast(camera.ray(through: screen)) {
            // Close to the first corner counts as closing the face, even if it's a new vertex.
            if faceCorners.count >= 3, let first = cornerPosition(faceCorners[0]),
               let projected = camera.project(first), simd_length(projected.screen - screen) < tools.stroke.snapRadiusPoints {
                commitFaceBuilder()
                return
            }
            corner = .surface(position: hit.offsetPosition(tools.surfaceOffset), normal: hit.normal)
        } else {
            say("Tap on the model or on existing vertices to build a face.")
            return
        }
        faceCorners.append(corner)
        if faceCorners.count == 4 {
            commitFaceBuilder()
        } else {
            rebuildOverlay()
            notify()
        }
    }

    private func cornerPosition(_ corner: FaceCorner) -> Vec3? {
        switch corner {
        case .vertex(let v): return mesh.isVertexAlive(v) ? mesh.position(v) : nil
        case .edgePoint(_, _, let p): return p
        case .surface(let p, _): return p
        }
    }

    public func commitFaceBuilder() {
        guard faceCorners.count >= 3 else {
            say("A face needs at least three corners.", kind: .warning)
            return
        }
        var plan = TopologyPlan()
        var points: [Vec3] = []
        for corner in faceCorners {
            switch corner {
            case .vertex(let v):
                plan.nodes.append(.existing(v))
                points.append(mesh.position(v))
            case .edgePoint(let e, let t, let p):
                plan.nodes.append(.split(edge: e, t: t, position: p))
                points.append(p)
            case .surface(let p, let n):
                plan.nodes.append(.new(position: p, normal: n))
                points.append(p)
            }
        }
        var loop = Array(0..<Int32(faceCorners.count))
        loop = orient(loop, points: points)
        plan.faces = [loop]
        faceCorners = []
        let ok = perform("Add face") { mesh, selection in
            let result = try PlanApplier.apply(plan, to: &mesh, symmetry: symmetry, projector: projector)
            selection.clear()
            selection.mode = .face
            selection.faces = Set(result.faces)
        }
        if ok { onEvent?(.facesGenerated) }
    }

    /// Winds a loop to face out of the surface when there's a surface to ask.
    private func orient(_ loop: [Int32], points: [Vec3]) -> [Int32] {
        guard let projector, !projector.isEmpty else { return loop }
        let center = points.reduce(Vec3(repeating: 0), +) / Float(points.count)
        guard let hit = projector.closest(to: center) else { return loop }
        return simd_dot(GeometryMath.newellNormal(points), hit.normal) < 0 ? loop.reversed() : loop
    }

    public func cancelFaceBuilder() {
        guard !faceCorners.isEmpty else { return }
        faceCorners = []
        rebuildOverlay()
        notify()
    }

    public func undoFaceCorner() {
        guard !faceCorners.isEmpty else { return }
        faceCorners.removeLast()
        rebuildOverlay()
        notify()
    }

    // MARK: Selection gestures

    private func beginSelectGesture(at screen: Vec2) {
        var picker = MeshPicker(camera: camera, mesh: mesh, projector: projector)
        picker.ignoresOcclusion = ignoresOcclusionForPicking
        let hit = picker.pick(at: screen, mode: selection.mode, radius: pickRadius)
        guard let hit else {
            gesture = .lasso([screen])
            lassoPath = [screen]
            return
        }
        var grab = Vec3(repeating: 0)
        switch hit {
        case .vertex(let v): grab = mesh.position(v)
        case .edge(let e, let t):
            let (a, b) = mesh.ends(e)
            grab = simd_mix(mesh.position(a), mesh.position(b), Vec3(repeating: t))
        case .face(let f): grab = mesh.faceCenter(f)
        }
        // Held by the spot under the Pencil, so that doesn't jump to it when the drag starts.
        if case .vertex = hit {} else if let projector = activeProjector, let there = projector.raycast(camera.ray(through: screen)) {
            grab = there.offsetPosition(projector.surfaceOffset)
        }
        gesture = .select(SelectDrag(
            start: screen,
            startedOn: hit,
            before: currentSnapshot,
            basePositions: [:],
            grabPoint: grab,
            grabPlaneNormal: camera.forward,
            targets: []
        ))
    }

    private func isSelected(_ element: PickedElement) -> Bool {
        switch element {
        case .vertex(let v): return selection.vertices.contains(v)
        case .edge(let e, _): return selection.edges.contains(e)
        case .face(let f): return selection.faces.contains(f)
        }
    }

    private func applyPick(_ element: PickedElement) {
        var next = selection
        func change<T: Hashable>(_ set: inout Set<T>, _ item: T) {
            switch selectionOperation {
            case .replace:
                set = [item]
            case .add:
                set.insert(item)
            case .remove:
                set.remove(item)
            }
        }
        if selectionOperation == .replace {
            next.vertices.removeAll()
            next.edges.removeAll()
            next.faces.removeAll()
        }
        switch element {
        case .vertex(let v): change(&next.vertices, v)
        case .edge(let e, _): change(&next.edges, e)
        case .face(let f): change(&next.faces, f)
        }
        selection = next
    }

    private func updateSelectDrag(_ drag: inout SelectDrag, to screen: Vec2) {
        guard let startedOn = drag.startedOn else { return }
        if !drag.moved {
            guard simd_length(screen - drag.start) > tapSlop else { return }
            // Dragging something unselected selects it first, then moves it.
            if !isSelected(startedOn) {
                let saved = selectionOperation
                if selectionOperation == .remove { selectionOperation = .replace }
                applyPick(startedOn)
                selectionOperation = saved
            }
            let touched = selection.touchedVertices(in: mesh)
            let expanded = symmetry.isEnabled ? Symmetry.expanded(vertices: touched, in: mesh) : touched
            drag.targets = expanded.sorted()
            drag.basePositions = Dictionary(uniqueKeysWithValues: drag.targets.map { ($0, mesh.position($0)) })
            drag.moved = true
        }
        switch dragBehavior {
        case .move:
            dragMove(drag, to: screen)
        case .slide:
            dragSlide(drag, to: screen)
        }
    }

    private func dragMove(_ drag: SelectDrag, to screen: Vec2) {
        let ray = camera.ray(through: screen)
        var delta: Vec3
        var surfaceHit: SurfaceHit?
        if let projector = activeProjector, let hit = projector.raycast(ray) {
            surfaceHit = hit
            delta = hit.offsetPosition(projector.surfaceOffset) - drag.grabPoint
        } else {
            // Off the model, or snapping is off: move in the plane facing the camera.
            let denom = simd_dot(ray.direction, drag.grabPlaneNormal)
            guard abs(denom) > 1e-5 else { return }
            let t = simd_dot(drag.grabPoint - ray.origin, drag.grabPlaneNormal) / denom
            delta = ray.at(t) - drag.grabPoint
            if activeProjector != nil { return }
        }
        // Only the side being dragged is driven directly; the other side mirrors it.
        var primary = drag.targets
        if symmetry.isEnabled {
            let grabbed = selection.touchedVertices(in: mesh)
            primary = drag.targets.filter { grabbed.contains($0) }
        }
        var updates: [(VertexID, Vec3)] = []
        updates.reserveCapacity(primary.count)
        let single = primary.count == 1
        for v in primary {
            guard let base = drag.basePositions[v] else { continue }
            var target = base + delta
            if let projector = activeProjector {
                if single, let surfaceHit {
                    target = surfaceHit.offsetPosition(projector.surfaceOffset)
                } else {
                    let hint = mesh.vertexNormal(v)
                    target = projector.project(target, normalHint: simd_length_squared(hint) > 0 ? hint : surfaceHit?.normal)?.position ?? target
                }
            }
            updates.append((v, target))
        }
        Brushes.apply(updates, to: &mesh, projector: activeProjector, symmetry: symmetry, radius: max(sceneBounds.diagonal * 0.05, 1e-3))
    }

    /// Each vertex follows whichever connected edge best matches the drag on screen, so a selected
    /// edge loop slides as a loop, with its neighbours' spacing changing but not their connectivity.
    private func dragSlide(_ drag: SelectDrag, to screen: Vec2) {
        let dragVector = screen - drag.start
        let length = simd_length(dragVector)
        guard length > 0.5 else { return }
        let direction = dragVector / length
        let grabbed = selection.touchedVertices(in: mesh)
        var updates: [(VertexID, Vec3)] = []
        for v in grabbed.sorted() {
            guard let base = drag.basePositions[v], let baseScreen = camera.project(base)?.screen else { continue }
            var bestTarget: Vec3?
            var bestScore: Float = 0.2
            var bestScreenLength: Float = 1
            for e in mesh.edgesOf(v) {
                let other = mesh.otherEnd(e, from: v)
                if grabbed.contains(other) { continue }
                let p = drag.basePositions[other] ?? mesh.position(other)
                guard let s = camera.project(p)?.screen else { continue }
                let toOther = s - baseScreen
                let screenLength = simd_length(toOther)
                guard screenLength > 1e-3 else { continue }
                let score = simd_dot(toOther / screenLength, direction)
                if score > bestScore {
                    bestScore = score
                    bestTarget = p
                    bestScreenLength = screenLength
                }
            }
            guard let bestTarget else {
                updates.append((v, base))
                continue
            }
            let t = simd_clamp(length * bestScore / bestScreenLength, 0, 0.98)
            let moved = simd_mix(base, bestTarget, Vec3(repeating: t))
            updates.append((v, mesh.reprojected(moved, near: v, projector: activeProjector)))
        }
        Brushes.apply(updates, to: &mesh, projector: activeProjector, symmetry: symmetry, radius: max(sceneBounds.diagonal * 0.05, 1e-3))
    }

    private func finishSelectDrag(_ drag: SelectDrag, at screen: Vec2) {
        if drag.moved {
            if activeTool == .pencil {
                // A side moved short enough to go straight now does, as it would have when it was drawn.
                mesh.straightenQuads(mirrored: symmetry.isEnabled)
                selection.prune(in: mesh)
            }
            recordEdit(before: drag.before, label: dragBehavior == .slide ? "Slide" : "Move")
            onEvent?(.vertexMoved)
            return
        }
        if let element = drag.startedOn { applyPick(element) }
    }

    private func finishLasso(_ points: [Vec2], tapPoint: Vec2) {
        var total: Float = 0
        if points.count > 1 {
            for i in 1..<points.count { total += simd_length(points[i] - points[i - 1]) }
        }
        if total < tapSlop {
            if selectionOperation == .replace { selection.clear() }
            return
        }
        var picker = MeshPicker(camera: camera, mesh: mesh, projector: projector)
        picker.ignoresOcclusion = ignoresOcclusionForPicking
        let found = picker.select(inside: points, mode: selection.mode)
        switch selectionOperation {
        case .replace:
            selection.clear()
            selection.vertices = found.vertices
            selection.edges = found.edges
            selection.faces = found.faces
        case .add:
            selection.vertices.formUnion(found.vertices)
            selection.edges.formUnion(found.edges)
            selection.faces.formUnion(found.faces)
        case .remove:
            selection.vertices.subtract(found.vertices)
            selection.edges.subtract(found.edges)
            selection.faces.subtract(found.faces)
        }
    }

    // MARK: Brushes

    private func applyBrush(at screen: Vec2, pressure: Float) {
        guard case .brush(let before, let lastHit, let label) = gesture else { return }
        guard let projector, let hit = projector.raycast(camera.ray(through: screen)) else {
            gesture = .brush(before: before, lastHit: nil, label: label)
            return
        }
        let settings = tools.brush
        let worldRadius = settings.radiusPoints * camera.worldPerPoint(at: hit.position)
        // Moving keeps up with the Pencil, so whatever's under it goes where it's put.
        let strength = activeTool == .moveBrush ? 1 : settings.strength * (settings.usesPressure ? simd_clamp(pressure, 0.1, 1) : 1)
        let stamp = BrushStamp(center: hit.position, worldRadius: worldRadius, strength: strength, normal: hit.normal)
        if activeTool == .relaxBrush {
            Brushes.relax(&mesh, stamp: stamp, projector: projector, snap: tools.surfaceSnapping, symmetry: symmetry)
        } else if let lastHit {
            Brushes.move(&mesh, stamp: stamp, delta: hit.position - lastHit.position, projector: projector, snap: tools.surfaceSnapping, symmetry: symmetry)
        }
        gesture = .brush(before: before, lastHit: hit, label: label)
    }

    /// Marks the whole lines and the marks the eraser has reached since it last moved. They go when it lifts.
    private func rub(to screen: Vec2) {
        var picker = MeshPicker(camera: camera, mesh: mesh, projector: projector)
        picker.ignoresOcclusion = ignoresOcclusionForPicking
        let radius = brushReach
        let start = lastRub ?? screen
        lastRub = screen
        let steps = max(Int((simd_length(screen - start) / max(radius, 1)).rounded(.up)), 1)
        let spots = (0...steps).map { simd_mix(start, screen, Vec2(repeating: Float($0) / Float(steps))) }

        for (index, mark) in sketches.enumerated() where !rubbedMarks.contains(index) {
            if spots.contains(where: { touches(mark, at: $0, radius: radius) }) { rubbedMarks.insert(index) }
        }
        for e in mesh.aliveEdges where !rubbedLines.contains(e) {
            let (a, b) = mesh.ends(e)
            let pa = mesh.position(a), pb = mesh.position(b)
            guard let sa = camera.project(pa)?.screen, let sb = camera.project(pb)?.screen else { continue }
            let span = sb - sa
            let isReached = spots.contains { spot in
                let t = simd_clamp(simd_dot(spot - sa, span) / max(simd_length_squared(span), 1e-6), 0, 1)
                return simd_length(sa + span * t - spot) <= radius && picker.isVisible(simd_mix(pa, pb, Vec3(repeating: t)), normal: nil)
            }
            if isReached { rubbedLines.formUnion(lineBetweenPoints(through: e)) }
        }
        rebuildOverlay()
    }

    /// Takes out what the rub went over, as one step.
    private func finishRub() {
        let lines = rubbedLines, marks = rubbedMarks
        clearRub()
        guard !lines.isEmpty || !marks.isEmpty else { return }
        let before = currentSnapshot
        if !marks.isEmpty {
            sketches = sketches.enumerated().filter { !marks.contains($0.offset) }.map(\.element)
            sketchRevision &+= 1
        }
        if !lines.isEmpty { eraseLines(lines) }
        selection.prune(in: mesh)
        recordEdit(before: before, label: "Erase")
    }

    private func clearRub() {
        rubbedLines = []
        rubbedMarks = []
        lastRub = nil
    }

    /// A point in the middle of a line stops being one, and the line carries on through. Anywhere else,
    /// it goes along with the lines that meet there.
    private func erasePoint(_ v: VertexID) {
        var points = [v]
        let partner = mesh.mirrorPartner[Int(v)]
        if symmetry.isEnabled, partner >= 0, partner != v, mesh.isVertexAlive(VertexID(partner)) { points.append(VertexID(partner)) }
        var lines = Set<EdgeID>()
        for point in points {
            if mesh.edgesOf(point).count == 2 {
                mesh.setBend(point, true)
            } else {
                lines.formUnion(mesh.edgesOf(point))
            }
        }
        if lines.isEmpty {
            mesh.straightenQuads(mirrored: symmetry.isEnabled)
        } else {
            eraseLines(lines)
        }
    }

    /// Takes out lines, and whatever they fenced in becomes one face with what's next to it if lines still go all the way round.
    private func eraseLines(_ lines: Set<EdgeID>) {
        let gone = symmetry.isEnabled ? Symmetry.expanded(edges: lines, in: mesh) : lines
        var around: [EdgeID] = []
        for f in mesh.aliveFaces where !mesh.edgeLoop(f).allSatisfy({ !gone.contains($0) }) {
            around += mesh.edgeLoop(f).filter { !gone.contains($0) }
        }
        mesh.deleteEdges(gone)
        try? DrawnFaces.update(after: PlanResult(), met: [], around: around, in: &mesh, projector: projector, symmetry: symmetry)
    }

    // MARK: Selection commands

    public func selectAll() {
        var next = Selection()
        next.mode = selection.mode
        switch selection.mode {
        case .vertex: next.vertices = Set(mesh.aliveVertices)
        case .edge: next.edges = Set(mesh.aliveEdges)
        case .face: next.faces = Set(mesh.aliveFaces)
        }
        selection = next
        notify()
    }

    public func clearSelection() {
        selection.clear()
        notify()
    }

    public func selectEdgeLoop() {
        guard !selection.edges.isEmpty else {
            say("Select an edge first to extend it along its loop.")
            return
        }
        var out = selection.edges
        for e in selection.edges { out.formUnion(SelectionTools.edgeLoop(from: e, in: mesh)) }
        selection.edges = out
        notify()
    }

    public func selectEdgeRing() {
        guard !selection.edges.isEmpty else {
            say("Select an edge first to extend it across its ring.")
            return
        }
        var out = selection.edges
        for e in selection.edges { out.formUnion(SelectionTools.edgeRing(from: e, in: mesh)) }
        selection.edges = out
        notify()
    }

    public func selectConnected() {
        let touched = selection.touchedVertices(in: mesh)
        guard !touched.isEmpty else {
            say("Select something first to grow it to its connected region.")
            return
        }
        let connected = SelectionTools.connectedVertices(from: touched, in: mesh)
        SelectionTools.select(vertices: connected, in: mesh, mode: selection.mode, into: &selection, additive: false)
        notify()
    }

    public func selectBoundary() {
        var next = Selection()
        next.mode = .edge
        next.edges = SelectionTools.boundaryEdges(in: mesh)
        selection = next
        notify()
    }

    // MARK: Edit commands

    /// Under symmetry a command sees the selection on both sides.
    private var workingVertices: Set<VertexID> {
        symmetry.isEnabled ? Symmetry.expanded(vertices: selection.vertices, in: mesh) : selection.vertices
    }
    private var workingEdges: Set<EdgeID> {
        symmetry.isEnabled ? Symmetry.expanded(edges: selection.edges, in: mesh) : selection.edges
    }
    private var workingFaces: Set<FaceID> {
        symmetry.isEnabled ? Symmetry.expanded(faces: selection.faces, in: mesh) : selection.faces
    }

    public func deleteSelection() {
        guard !selection.isEmpty else {
            say("Select something to delete first.")
            return
        }
        let vertices = workingVertices, edges = workingEdges, faces = workingFaces
        perform("Delete") { mesh, selection in
            mesh.deleteFaces(faces)
            mesh.deleteEdges(edges)
            mesh.deleteVertices(vertices)
            selection.clear()
        }
    }

    public func dissolveSelection() {
        guard !selection.vertices.isEmpty || !selection.edges.isEmpty else {
            say("Select vertices or edges to dissolve.")
            return
        }
        let vertices = workingVertices, edges = workingEdges
        perform("Dissolve") { mesh, selection in
            for e in edges.sorted() where mesh.isEdgeAlive(e) { try mesh.dissolveEdge(e) }
            for v in vertices.sorted() where mesh.isVertexAlive(v) { try mesh.dissolveVertex(v) }
            selection.clear()
        }
    }

    public func splitSelectedEdges(cuts: Int = 1) {
        if selection.mode == .vertex, !selection.vertices.isEmpty { setSelectionMode(.edge) }
        guard !selection.edges.isEmpty else {
            say("Select edges to split.")
            return
        }
        let edges = workingEdges
        let projector = activeProjector
        let wasNgon = statistics.ngons
        let ok = perform("Split edges") { mesh, selection in
            let created = try mesh.subdivideEdges(edges, cuts: cuts)
            project(created, in: &mesh, projector: projector)
            selection.clear()
            selection.mode = .vertex
            selection.vertices = Set(created)
        }
        if ok {
            let grown = statistics.ngons - wasNgon
            if grown > 0 { say(grown == 1 ? "1 neighbouring face became an n-gon." : "\(grown) neighbouring faces became n-gons.") }
        }
    }

    private func project(_ vertices: [VertexID], in mesh: inout Mesh, projector: SurfaceProjector?) {
        guard let projector, !projector.isEmpty else { return }
        var updates: [(VertexID, Vec3)] = []
        for v in vertices where mesh.isVertexAlive(v) {
            updates.append((v, mesh.reprojected(mesh.position(v), near: v, projector: projector)))
        }
        mesh.setPositions(updates)
    }

    public func connectSelectedVertices() {
        let list = selection.vertices.sorted()
        guard list.count == 2 else {
            say("Select exactly two vertices to connect them.")
            return
        }
        let a = list[0], b = list[1]
        let pa = mesh.mirrorPartner[Int(a)], pb = mesh.mirrorPartner[Int(b)]
        let mirrored = symmetry.isEnabled && pa >= 0 && pb >= 0 && !(pa == a && pb == b) && !(pa == b && pb == a)
        perform("Connect") { mesh, selection in
            let e = try mesh.connectVertices(a, b)
            if mirrored && mesh.edge(between: pa, pb) == nil {
                try mesh.connectVertices(pa, pb)
            }
            selection.clear()
            selection.mode = .edge
            selection.edges = [e]
        }
    }

    public func extrudeSelectedEdges() {
        if selection.mode == .vertex, !selection.vertices.isEmpty { setSelectionMode(.edge) }
        guard !selection.edges.isEmpty else {
            say("Select boundary edges to extrude.")
            return
        }
        let edges = workingEdges
        let distance = tools.extrudeDistance
        let projector = activeProjector
        perform("Extrude") { mesh, selection in
            let top = try mesh.extrudeEdges(edges, distance: distance, projector: projector)
            selection.clear()
            selection.mode = .edge
            selection.edges = top
        }
    }

    /// Fills the holes touched by the selected edges, or every closed boundary if nothing is selected.
    public func fillHoles() {
        var loops: [BoundaryChain] = []
        if selection.edges.isEmpty {
            loops = ChainFinder.boundaryLoops(in: mesh)
            // A sheet's outer boundary is a loop too. Filling it would cap the whole sheet.
            if loops.count == 1, selection.vertices.isEmpty {
                say("This mesh has one open boundary, which might be its outline rather than a hole. Select one of its edges and fill again to confirm.")
                return
            }
            // With several, the longest is taken for the outline and left open unless it's picked by hand.
            if loops.count > 1, selection.vertices.isEmpty, let outline = loops.indices.max(by: { loops[$0].edges.count < loops[$1].edges.count }) {
                loops.remove(at: outline)
            }
        } else {
            var seen = Set<EdgeID>()
            for e in workingEdges.sorted() where !seen.contains(e) {
                if let chain = ChainFinder.chain(through: e, in: mesh), chain.isClosed {
                    loops.append(chain)
                    seen.formUnion(chain.edges)
                }
            }
        }
        guard !loops.isEmpty else {
            say("No closed loop to fill. A hole needs a complete ring of boundary edges.", kind: .warning)
            return
        }
        let projector = self.projector
        let ok = perform("Fill") { mesh, selection in
            var faces = Set<FaceID>()
            for loop in loops {
                let center = loop.vertices.map { mesh.position($0) }.reduce(Vec3(repeating: 0), +) / Float(loop.vertices.count)
                let normal = projector?.closest(to: center)?.normal
                faces.insert(try mesh.fill(loop: loop, surfaceNormal: normal))
            }
            selection.clear()
            selection.mode = .face
            selection.faces = faces
        }
        if ok {
            onEvent?(.facesGenerated)
            if loops.contains(where: { $0.vertices.count > 4 }) {
                say("Filled with one n-gon. Use Quad Patch for a loop you'd rather fill with quads.")
            }
        }
    }

    public func weldSelected() {
        guard selection.vertices.count >= 2 else {
            say("Select at least two vertices to weld.")
            return
        }
        let group = selection.vertices
        var mirror = Set<VertexID>()
        if symmetry.isEnabled {
            mirror = Symmetry.expanded(vertices: group, in: mesh).subtracting(group)
        }
        let plane = symmetry.activePlane
        perform("Weld") { mesh, selection in
            // Partners within the selection mean a weld across the plane: that lands on the plane.
            var center: Vec3? = nil
            if let plane, group.contains(where: { group.contains(mesh.mirrorPartner[Int($0)]) && mesh.mirrorPartner[Int($0)] != $0 }) {
                var sum = Vec3(repeating: 0)
                for v in group { sum += mesh.position(v) }
                center = plane.snap(sum / Float(group.count))
            }
            let kept = try mesh.weld(group, position: center)
            if center != nil { mesh.setMirrorPartner(kept, kept) }
            if mirror.count >= 2 {
                let other = try mesh.weld(mirror)
                mesh.setMirrorPartner(kept, other)
                mesh.setMirrorPartner(other, kept)
            }
            selection.clear()
            selection.mode = .vertex
            selection.vertices = [kept]
        }
    }

    public func weldByDistance(_ threshold: Float) {
        var merged = 0
        let ok = perform("Weld by distance") { mesh, selection in
            merged = try mesh.weldByDistance(threshold)
            selection.prune(in: mesh)
        }
        if ok { say(merged == 1 ? "Merged 1 vertex." : "Merged \(merged) vertices.") }
    }

    public func flipSelectedEdges() {
        if selection.mode == .vertex, !selection.vertices.isEmpty { setSelectionMode(.edge) }
        guard !selection.edges.isEmpty else {
            say("Select an edge between two faces to flip it.")
            return
        }
        let edges = workingEdges
        perform("Flip edge") { mesh, selection in
            for e in edges.sorted() where mesh.isEdgeAlive(e) { try mesh.flipEdge(e) }
            selection.clear()
        }
    }

    public func subdivideSelection() {
        if selection.mode == .vertex, !selection.vertices.isEmpty { setSelectionMode(.face) }
        let projector = activeProjector
        if !selection.faces.isEmpty {
            let faces = workingFaces
            let wasNgon = statistics.ngons
            let ok = perform("Subdivide") { mesh, selection in
                let result = try mesh.subdivideFaces(faces)
                project(result.vertices, in: &mesh, projector: projector)
                selection.clear()
                selection.mode = .face
                selection.faces = Set(result.faces)
            }
            if ok {
                let grown = statistics.ngons - wasNgon
                if grown > 0 { say(grown == 1 ? "1 neighbouring face gained a corner and became an n-gon." : "\(grown) neighbouring faces gained corners and became n-gons.") }
            }
        } else if !selection.edges.isEmpty {
            splitSelectedEdges()
        } else {
            say("Select faces or edges to subdivide.")
        }
    }

    public func applySubdivision() {
        let projector = activeProjector
        perform("Apply subdivision") { mesh, selection in
            try mesh.applyCatmullClark(projector: projector)
            selection.clear()
        }
    }

    public func relaxSelection(iterations: Int = 4) {
        let touched = selection.touchedVertices(in: mesh)
        guard !touched.isEmpty else {
            say("Select something to relax.")
            return
        }
        let targets = symmetry.isEnabled ? Symmetry.expanded(vertices: touched, in: mesh) : touched
        let projector = activeProjector
        let strength = max(tools.brush.strength, 0.3)
        let plane = symmetry.activePlane
        perform("Relax") { mesh, _ in
            mesh.relax(vertices: targets, iterations: iterations, strength: strength, pinBoundary: false, projector: projector)
            if let plane {
                // Relaxing isn't exactly mirror-preserving, so centerline vertices return to the plane.
                for v in targets where mesh.mirrorPartner[Int(v)] == v {
                    mesh.setPosition(v, plane.snap(mesh.position(v)))
                }
            }
        }
    }

    public func reverseNormals() {
        let faces = selection.faces.isEmpty ? Set(mesh.aliveFaces) : workingFaces
        guard !faces.isEmpty else {
            say("There are no faces to reverse.")
            return
        }
        perform("Reverse normals") { mesh, _ in mesh.reverseFaces(faces) }
    }

    public func recalculateNormals() {
        guard mesh.faceCount > 0 else {
            say("There are no faces to fix.")
            return
        }
        var flipped = 0
        let projector = self.projector
        let ok = perform("Recalculate normals") { mesh, _ in flipped = mesh.recalculateNormals(projector: projector) }
        if ok { say(flipped == 0 ? "Normals were already consistent." : (flipped == 1 ? "Flipped 1 face." : "Flipped \(flipped) faces."), kind: .success) }
    }

    /// Makes a face from selected vertices, or a quad bridging two selected edges.
    public func makeFaceFromSelection() {
        var loop: [VertexID] = []
        if selection.edges.count == 2 {
            let list = selection.edges.sorted()
            let (a0, a1) = mesh.ends(list[0])
            var (b0, b1) = mesh.ends(list[1])
            // Connect ends so the two new sides don't cross.
            let straight = simd_length(mesh.position(a1) - mesh.position(b0)) + simd_length(mesh.position(b1) - mesh.position(a0))
            let crossed = simd_length(mesh.position(a1) - mesh.position(b1)) + simd_length(mesh.position(b0) - mesh.position(a0))
            if crossed < straight { swap(&b0, &b1) }
            var seen = Set<VertexID>()
            loop = [a0, a1, b0, b1].filter { seen.insert($0).inserted }
        } else if selection.vertices.count >= 3 {
            loop = orderedAroundCenter(selection.vertices)
        } else {
            say("Select three or more vertices, or two edges, to make a face.")
            return
        }
        guard loop.count >= 3 else {
            say("Those don't enclose an area, so no face was made.", kind: .warning)
            return
        }
        var plan = TopologyPlan()
        plan.nodes = loop.map { .existing($0) }
        plan.faces = [orient(Array(0..<Int32(loop.count)), points: loop.map { mesh.position($0) })]
        let ok = perform("Make face") { mesh, selection in
            let result = try PlanApplier.apply(plan, to: &mesh, symmetry: symmetry, projector: projector)
            selection.clear()
            selection.mode = .face
            selection.faces = Set(result.faces)
        }
        if ok { onEvent?(.facesGenerated) }
    }

    private func orderedAroundCenter(_ vertices: Set<VertexID>) -> [VertexID] {
        let list = vertices.sorted()
        let points = list.map { mesh.position($0) }
        let center = points.reduce(Vec3(repeating: 0), +) / Float(points.count)
        // Best-fit normal from the loop of points as given is unreliable, so ask the surface first.
        var normal = projector?.closest(to: center)?.normal ?? Vec3(repeating: 0)
        if simd_length_squared(normal) == 0 {
            normal = GeometryMath.safeNormalize(simd_cross(points[1] - points[0], points[2] - points[0]))
        }
        let u = GeometryMath.perpendicular(to: normal)
        let v = simd_cross(normal, u)
        return list.sorted { a, b in
            let pa = mesh.position(a) - center, pb = mesh.position(b) - center
            return atan2(simd_dot(pa, v), simd_dot(pa, u)) < atan2(simd_dot(pb, v), simd_dot(pb, u))
        }
    }

    /// Puts vertices back on the surface. Applies to the selection, or to everything without one.
    public func reproject() {
        guard let projector else {
            say("There's no surface to project onto.")
            return
        }
        let touched = selection.touchedVertices(in: mesh)
        let targets = touched.isEmpty ? Set(mesh.aliveVertices) : touched
        perform("Reproject") { mesh, _ in
            var updates: [(VertexID, Vec3)] = []
            for v in targets {
                updates.append((v, mesh.reprojected(mesh.position(v), near: v, projector: projector)))
            }
            mesh.setPositions(updates)
        }
    }

    // MARK: Symmetry

    /// Pairing can snap vertices onto the plane. That isn't an edit to undo, but the replay still shows it.
    private func adoptRepairedPairs(_ repaired: Mesh) {
        let moved = repaired.positions != mesh.positions
        mesh = repaired
        if moved { timelapse.record(mesh: mesh, sketches: sketches, orientation: camera.orientation) }
    }

    public func setSymmetryEnabled(_ enabled: Bool) {
        symmetry.isEnabled = enabled
        if enabled, let plane = symmetry.activePlane {
            var work = mesh
            repairPairs(&work, plane: plane)
            adoptRepairedPairs(work)
        }
        editGeneration &+= 1
        rebuildOverlay()
        notify()
    }

    public func setSymmetryPlane(axis: MirrorAxis? = nil, offset: Float? = nil) {
        let changed = (axis != nil && axis != symmetry.plane.axis) || (offset != nil && offset != symmetry.plane.offset)
        if let axis {
            symmetry.plane.axis = axis
            if offset == nil {
                let box = sourceBounds
                if !box.isEmpty {
                    let c = box.center[axis.rawValue]
                    symmetry.plane.offset = abs(c) < box.diagonal * 0.01 ? 0 : c
                }
            }
        }
        if let offset { symmetry.plane.offset = offset }
        guard changed else { return }
        // Old partner links described the old plane.
        var work = mesh
        for v in work.aliveVertices { work.setMirrorPartner(v, invalidID) }
        if let plane = symmetry.activePlane { repairPairs(&work, plane: plane) }
        adoptRepairedPairs(work)
        editGeneration &+= 1
        notify()
    }

    public func setCenterTolerance(_ tolerance: Float) {
        symmetry.centerTolerance = tolerance
        editGeneration &+= 1
        notify()
    }

    /// Merges vertices across the centerline: those near the plane are snapped and pairs merged.
    public func mergeCenterline() {
        let plane = symmetry.plane
        let tolerance = symmetry.centerTolerance
        var merged = 0
        let ok = perform("Merge centerline") { mesh, selection in
            var near: [VertexID] = []
            for v in mesh.aliveVertices where abs(plane.signedDistance(mesh.position(v))) <= tolerance {
                near.append(v)
                mesh.setPosition(v, plane.snap(mesh.position(v)))
                mesh.setMirrorPartner(v, v)
            }
            merged = try mesh.weldByDistance(tolerance, among: Set(near))
            selection.prune(in: mesh)
        }
        if ok { say(merged == 1 ? "Merged 1 centerline vertex." : "Merged \(merged) centerline vertices.", kind: .success) }
    }

    /// Bakes symmetry into the mesh, copying the side with more faces over the other.
    public func applySymmetry() {
        let plane = symmetry.plane
        let tolerance = symmetry.centerTolerance
        var positive = 0, negative = 0
        for f in mesh.aliveFaces {
            if plane.signedDistance(mesh.faceCenter(f)) >= 0 { positive += 1 } else { negative += 1 }
        }
        if positive == 0 && negative == 0 {
            for v in mesh.aliveVertices {
                if plane.signedDistance(mesh.position(v)) >= 0 { positive += 1 } else { negative += 1 }
            }
        }
        let keepPositive = positive >= negative
        let projector = self.projector
        let ok = perform("Apply symmetry") { mesh, selection in
            try Symmetry.apply(to: &mesh, plane: plane, centerTolerance: tolerance, keepPositive: keepPositive, projector: projector)
            selection.clear()
        }
        if ok { say("Symmetry applied to the mesh. Each side sits on its own part of the surface.", kind: .success) }
    }

    // MARK: Overlay

    private func updateLiveMirrorOverlay(_ capture: StrokeCapture) {
        guard let plane = symmetry.activePlane, let run = capture.runs.last, run.count >= 2 else {
            overlay.mirrorEdges = []
            return
        }
        // Mirrored points are only shown, not yet projected: this runs at Pencil rate.
        let start = max(run.count - 512, 1)
        var lines: [Vec3] = []
        lines.reserveCapacity((run.count - start) * 2)
        for i in start..<run.count {
            lines.append(plane.reflect(run[i - 1].position))
            lines.append(plane.reflect(run[i].position))
        }
        overlay.mirrorEdges = lines
    }

    public func rebuildOverlay() {
        var out = OverlayGeometry()
        func addPlan(_ plan: TopologyPlan) {
            let positions = plan.positions(in: mesh)
            for e in plan.edges {
                out.previewEdges.append(positions[Int(e.x)])
                out.previewEdges.append(positions[Int(e.y)])
            }
            for face in plan.faces {
                let corners = face.map { positions[Int($0)] }
                for i in 0..<corners.count {
                    out.previewEdges.append(corners[i])
                    out.previewEdges.append(corners[(i + 1) % corners.count])
                }
                for t in Triangulation.triangulate(corners) {
                    out.previewTriangles.append(corners[Int(t.x)])
                    out.previewTriangles.append(corners[Int(t.y)])
                    out.previewTriangles.append(corners[Int(t.z)])
                }
            }
            if activeTool != .pencil { out.previewPoints.append(contentsOf: positions) }
            if let plane = symmetry.activePlane {
                for i in stride(from: 0, to: out.previewEdges.count - 1, by: 2) {
                    out.mirrorEdges.append(plane.reflect(out.previewEdges[i]))
                    out.mirrorEdges.append(plane.reflect(out.previewEdges[i + 1]))
                }
            }
        }
        if let pending = pendingStroke {
            for plan in pending.plans { addPlan(plan.plan) }
            if pending.canClose, let path = pending.paths.first, let a = path.points.first, let b = path.points.last {
                out.warningEdges.append(a.position)
                out.warningEdges.append(b.position)
            }
        }
        if let plan = pendingStrip?.plan { addPlan(plan) }
        if let preview = patchPreview { addPlan(preview.plan) }
        if let suggestion = fillSuggestion { addPlan(suggestion.preview.plan) }
        for chain in patchChains + (fillSuggestion?.chains ?? []) {
            var lines: [Vec3] = []
            for e in chain.edges where mesh.isEdgeAlive(e) {
                let (a, b) = mesh.ends(e)
                lines.append(mesh.position(a))
                lines.append(mesh.position(b))
            }
            out.chains.append(lines)
        }
        // A picked shape shows the points it's counting.
        if pickNote != nil, let face = selection.faces.first {
            out.previewPoints.append(contentsOf: mesh.loop(face).filter { !mesh.isBendVertex($0) }.map { mesh.position($0) })
        }
        if !faceCorners.isEmpty {
            let points = faceCorners.compactMap(cornerPosition)
            out.previewPoints.append(contentsOf: points)
            if points.count >= 2 {
                for i in 0..<(points.count - 1) {
                    out.previewEdges.append(points[i])
                    out.previewEdges.append(points[i + 1])
                }
            }
            if points.count >= 3 {
                out.warningEdges.append(points[points.count - 1])
                out.warningEdges.append(points[0])
            }
        }
        for e in symmetry.isEnabled ? Symmetry.expanded(edges: rubbedLines, in: mesh) : rubbedLines where mesh.isEdgeAlive(e) {
            let (a, b) = mesh.ends(e)
            out.erasingEdges += [mesh.position(a), mesh.position(b)]
        }
        for index in rubbedMarks where sketches.indices.contains(index) {
            let points = sketches[index].points
            for (a, b) in zip(points, points.dropFirst()) { out.erasingEdges += [a, b] }
        }
        overlay = out
    }

    // MARK: Project state

    public func makeSnapshot() -> ProjectSnapshot {
        var snapshot = ProjectSnapshot(name: name)
        snapshot.createdAt = createdAt
        snapshot.modifiedAt = Date()
        snapshot.sources = sources
        snapshot.mesh = mesh
        snapshot.selection = selection
        snapshot.camera = CameraState(camera)
        snapshot.symmetry = symmetry
        snapshot.viewport = viewport
        snapshot.tools = tools
        snapshot.activeTool = activeTool
        snapshot.patchChains = patchChains
        snapshot.polyBudget = polyBudget
        snapshot.sketches = sketches
        snapshot.timelapse = timelapse.frames
        snapshot.sketchColorIndex = sketchColorIndex
        snapshot.showsSketch = showsSketch
        snapshot.faceBuilderVertices = faceCorners.compactMap { corner in
            if case .vertex(let v) = corner { return v }
            return nil
        }
        return snapshot
    }

    /// Opens a saved project. The surface isn't ready until `installLoadedBVHs` runs, because BVHs are
    /// rebuilt in the background rather than stored.
    public convenience init(snapshot: ProjectSnapshot) {
        self.init(name: snapshot.name)
        createdAt = snapshot.createdAt
        sources = snapshot.sources
        mesh = snapshot.mesh
        selection = snapshot.selection
        camera = snapshot.camera.applied(to: camera)
        symmetry = snapshot.symmetry
        viewport = snapshot.viewport
        tools = snapshot.tools
        activeTool = snapshot.activeTool
        patchChains = snapshot.patchChains.filter { $0.isAlive(in: mesh) }
        polyBudget = snapshot.polyBudget
        sketches = snapshot.sketches
        sketchColorIndex = snapshot.sketchColorIndex
        showsSketch = snapshot.showsSketch
        timelapse.load(snapshot.timelapse, mesh: mesh, sketches: sketches, orientation: camera.orientation)
        faceCorners = snapshot.faceBuilderVertices.filter(mesh.isVertexAlive).map { .vertex($0) }
        rebuildOverlay()
    }

    public func exportData(format: ExportFormat, options: ExportOptions) -> Data {
        onEvent?(.exported)
        switch format {
        case .obj: return OBJExporter.export(mesh: mesh, name: name, sources: sources, options: options)
        case .glb: return GLBExporter.export(mesh: mesh, name: name, sources: sources, options: options)
        }
    }
}

/// The things worth finding on a mesh before calling it done.
public enum TopologyCheck: String, CaseIterable, Identifiable, Hashable {
    case triangles, ngons, poles, badGeometry

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .triangles: return MeshIssueKind.triangles.title
        case .ngons: return MeshIssueKind.ngons.title
        case .poles: return MeshIssueKind.poles.title
        case .badGeometry: return "Bad geometry"
        }
    }
}

public enum TopologySpot: Equatable {
    case face(FaceID)
    case edge(EdgeID)
    case vertex(VertexID)
}

public enum ExportFormat: String, CaseIterable, Identifiable, Codable {
    case obj, glb

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }
    public var label: String { rawValue.uppercased() }
}
