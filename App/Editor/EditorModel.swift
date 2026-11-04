import LittleSurfaceCore
import MetalKit
import Observation
import UIKit

struct BusyTask: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var cancellable: Bool
}

/// Connects one open project to the interface. The engine holds the document and its behavior; this
/// runs what's slow in the background, saves, and tells SwiftUI when to look again.
@Observable
final class EditorModel {
    @ObservationIgnored let engine: RetopoEngine
    @ObservationIgnored let renderer: ViewportRenderer?
    @ObservationIgnored private(set) var viewport: ViewportView?
    let document: ProjectDocument

    /// Bumped whenever panels should re-read the engine. Coalesced, and held back during a stroke.
    private(set) var revision = 0
    /// Bumped as the camera moves, for just the orientation gizmo.
    private(set) var cameraRevision = 0

    var busy: BusyTask?
    var surfaceIsReady = false
    var report: ValidationReport?
    var isValidating = false
    var subdivisionNote: String?
    var saveState = SaveState.saved
    var showsValidation = false
    var showsSettings = false
    var tutorialStep: TutorialStep?
    var exportedFile: ExportedFile?

    enum SaveState: Equatable { case saved, unsaved, saving, failed(String) }

    @ObservationIgnored private var updateScheduled = false
    @ObservationIgnored private var gestureDepth = 0
    @ObservationIgnored private var knownGeneration: UInt64 = 0
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var surfaceTask: Task<Void, Never>?
    @ObservationIgnored private var subdivisionTask: Task<Void, Never>?
    @ObservationIgnored private var validationTask: Task<Void, Never>?
    @ObservationIgnored private var previousTool: Tool?
    @ObservationIgnored private var subdivisionKey: SubdivisionKey?

    private struct SubdivisionKey: Equatable {
        var topology: UInt64
        var positions: UInt64
        var levels: Int
    }

    init(document: ProjectDocument, snapshot: ProjectSnapshot) {
        self.document = document
        engine = RetopoEngine(snapshot: snapshot)
        let device = MTLCreateSystemDefaultDevice()
        renderer = device.flatMap { ViewportRenderer(device: $0) }
        renderer?.engine = engine
        knownGeneration = engine.editGeneration
        document.snapshotProvider = { [weak self] in
            guard let self else { return ProjectSnapshot(name: "Untitled") }
            return self.engine.makeSnapshot()
        }
        document.releaseLoaded()
        engine.onChange = { [weak self] in self?.engineChanged() }
        engine.onEvent = { [weak self] event in self?.handle(event) }
        rebuildSurface(for: snapshot.sources)
        refreshSubdivisionPreview()
    }

    func attach(viewport: ViewportView) {
        self.viewport = viewport
        viewport.model = self
        viewport.delegate = renderer
    }

    // MARK: Change tracking

    private func engineChanged() {
        viewport?.setNeedsDisplay()
        if engine.editGeneration != knownGeneration {
            knownGeneration = engine.editGeneration
            documentChanged()
        }
        if gestureDepth == 0 { scheduleUpdate() }
    }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            self.revision &+= 1
        }
    }

    /// Reads the current state on behalf of a view, and subscribes it to changes.
    var state: RetopoEngine {
        _ = revision
        return engine
    }

    func gestureBegan() {
        gestureDepth = 1
    }

    func gestureEnded() {
        gestureDepth = 0
        scheduleUpdate()
        refreshSubdivisionPreview()
    }

    func cameraDidChange() {
        cameraRevision &+= 1
        viewport?.setNeedsDisplay()
    }

    private func documentChanged() {
        report = nil
        saveState = .unsaved
        document.updateChangeCount(.done)
        if gestureDepth == 0 { refreshSubdivisionPreview() }
    }

    /// For settings that the engine lets panels set directly.
    func settingChanged() {
        document.updateChangeCount(.done)
        saveState = .unsaved
        viewport?.setNeedsDisplay()
        scheduleUpdate()
    }

    // MARK: Undo

    func undo() {
        engine.undo()
        refreshSubdivisionPreview()
    }

    func redo() {
        engine.redo()
        refreshSubdivisionPreview()
    }

    // MARK: Tools

    func select(tool: Tool) {
        if tool != engine.activeTool { previousTool = engine.activeTool }
        engine.setTool(tool)
        settingChanged()
    }

    func pencilDoubleTapped() {
        switch AppSettings.shared.pencilDoubleTap {
        case .none:
            break
        case .eraser:
            if engine.activeTool == .erase {
                select(tool: previousTool ?? .drawEdges)
            } else {
                select(tool: .erase)
            }
        case .previousTool:
            if let previousTool { select(tool: previousTool) }
        }
    }

    // MARK: Background work: importing

    var isBusyImporting: Bool { importTask != nil }

    func importModel(from url: URL) {
        guard importTask == nil else { return }
        busy = BusyTask(title: "Reading \(url.lastPathComponent)…", cancellable: true)
        importTask = Task.detached(priority: .userInitiated) { [weak self] in
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            do {
                let model = try ModelImporter.load(url: url, isCancelled: { Task.isCancelled })
                await MainActor.run { self?.busy?.title = "Preparing the surface…" }
                let bvhs = RetopoEngine.buildBVHs(for: model.objects, isCancelled: { Task.isCancelled })
                try Task.checkCancellation()
                await MainActor.run { self?.finishImport(model, bvhs: bvhs) }
            } catch is CancellationError {
                await MainActor.run { self?.endImport() }
            } catch ImportError.cancelled {
                await MainActor.run { self?.endImport() }
            } catch {
                await MainActor.run {
                    self?.endImport()
                    self?.engine.say(error.localizedDescription, kind: .error)
                }
            }
        }
    }

    func importExample() {
        guard let url = Bundle.main.url(forResource: "Example", withExtension: "glb") else {
            engine.say("The example model is missing from this build.", kind: .error)
            return
        }
        importModel(from: url)
    }

    private func finishImport(_ model: ImportedModel, bvhs: [UUID: TriangleBVH]) {
        endImport()
        engine.addSources(model.objects, bvhs: bvhs)
        surfaceIsReady = true
        if engine.name == "Untitled" || engine.name.isEmpty { engine.name = model.name }
        let triangles = model.objects.reduce(0) { $0 + $1.triangleCount }
        var text = "Imported \(model.objects.count == 1 ? model.objects[0].name : "\(model.objects.count) objects"), \(triangles.formatted()) triangles."
        if let warning = model.warnings.first { text += " " + warning }
        engine.say(text, kind: model.warnings.isEmpty ? .success : .warning)
        // An import is expensive to repeat, so don't leave it to wait for autosave.
        save()
        viewport?.setNeedsDisplay()
    }

    private func endImport() {
        importTask = nil
        busy = nil
    }

    func cancelBusyTask() {
        importTask?.cancel()
    }

    private func rebuildSurface(for sources: [SourceObject]) {
        guard !sources.isEmpty else {
            surfaceIsReady = true
            return
        }
        surfaceTask = Task.detached(priority: .userInitiated) { [weak self] in
            let bvhs = RetopoEngine.buildBVHs(for: sources, isCancelled: { Task.isCancelled })
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.engine.installLoadedBVHs(bvhs)
                self.surfaceIsReady = true
            }
        }
    }

    // MARK: Background work: subdivision preview

    func refreshSubdivisionPreview() {
        let settings = engine.viewport
        guard settings.subdivisionPreview, settings.subdivisionDisplay != .cage else {
            subdivisionTask?.cancel()
            subdivisionTask = nil
            subdivisionKey = nil
            renderer?.subdivision = nil
            subdivisionNote = nil
            return
        }
        let mesh = engine.mesh
        let key = SubdivisionKey(topology: mesh.topologyVersion, positions: mesh.positionVersion, levels: settings.subdivisionLevels)
        guard key != subdivisionKey else { return }
        subdivisionKey = key
        subdivisionTask?.cancel()
        let device = renderer?.device
        subdivisionTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try CatmullClark.preview(mesh, levels: settings.subdivisionLevels, isCancelled: { Task.isCancelled })
                let buffers = device.flatMap { SubdivisionBuffers(device: $0, data: result.mesh.triangulated()) }
                try Task.checkCancellation()
                await MainActor.run {
                    guard let self else { return }
                    self.renderer?.subdivision = buffers
                    self.subdivisionNote = result.levels < settings.subdivisionLevels
                        ? "Stopped at level \(result.levels) to stay under the \(CatmullClark.maxPreviewFaces.formatted()) face limit."
                        : "\(result.mesh.faceCount.formatted()) faces at level \(result.levels). Real geometry is unchanged."
                    self.viewport?.setNeedsDisplay()
                }
            } catch {
                // Cancelled by a newer edit, whose own task will finish the job.
            }
        }
    }

    // MARK: Background work: validation

    func runValidation() {
        validationTask?.cancel()
        let mesh = engine.mesh
        isValidating = true
        validationTask = Task.detached(priority: .userInitiated) { [weak self] in
            let report = MeshValidator.analyze(mesh, isCancelled: { Task.isCancelled })
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.report = report
                self?.isValidating = false
            }
        }
    }

    // MARK: Saving

    func save(completion: ((Bool) -> Void)? = nil) {
        guard document.documentState.contains(.closed) == false else {
            completion?(false)
            return
        }
        saveState = .saving
        document.updateChangeCount(.done)
        document.save(to: document.fileURL, for: .forOverwriting) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.saveState = .saved
                self.storeThumbnail()
            } else {
                self.saveState = .failed(self.document.lastSaveError?.localizedDescription ?? "The project couldn't be saved.")
                self.engine.say("Couldn't save. \(self.document.lastSaveError?.localizedDescription ?? "")", kind: .error)
            }
            completion?(ok)
        }
    }

    func close(completion: @escaping () -> Void) {
        importTask?.cancel()
        surfaceTask?.cancel()
        subdivisionTask?.cancel()
        validationTask?.cancel()
        storeThumbnail()
        document.updateChangeCount(.done)
        document.close { [weak self] _ in
            self?.document.snapshotProvider = nil
            completion()
        }
    }

    private func storeThumbnail() {
        guard let image = renderer?.thumbnail(engine: engine, size: CGSize(width: 480, height: 320)) else { return }
        ProjectLibrary.shared.storeThumbnail(image, for: document.fileURL)
    }

    // MARK: Exporting

    func export(format: ExportFormat, options: ExportOptions, name: String) {
        guard busy == nil else { return }
        // Encoding big models with their source takes a moment, so it stays off the main thread.
        let snapshot = engine.makeSnapshot()
        busy = BusyTask(title: "Exporting…", cancellable: false)
        Task.detached(priority: .userInitiated) { [weak self] in
            let data: Data
            switch format {
            case .obj: data = OBJExporter.export(mesh: snapshot.mesh, name: name, sources: snapshot.sources, options: options)
            case .glb: data = GLBExporter.export(mesh: snapshot.mesh, name: name, sources: snapshot.sources, options: options)
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(ProjectLibrary.safeFileName(name)).appendingPathExtension(format.rawValue)
            do {
                try data.write(to: url, options: .atomic)
                await MainActor.run {
                    self?.busy = nil
                    self?.exportedFile = ExportedFile(url: url, format: format, byteCount: data.count)
                    self?.engine.onEvent?(.exported)
                }
            } catch {
                await MainActor.run {
                    self?.busy = nil
                    self?.engine.say("The export couldn't be written. \(error.localizedDescription)", kind: .error)
                }
            }
        }
    }

    // MARK: Tutorial

    private func handle(_ event: RetopoEngine.EngineEvent) {
        guard let step = tutorialStep else { return }
        if step.completes(on: event) { tutorialStep = step.next }
    }

    func startTutorial() {
        tutorialStep = engine.sources.isEmpty ? .importModel : .drawLoop
        engine.setTool(.drawEdges)
    }

    func endTutorial() {
        tutorialStep = nil
        AppSettings.shared.hasSeenTutorial = true
    }
}

struct ExportedFile: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let format: ExportFormat
    let byteCount: Int
}

/// The first-use walkthrough, advanced by what the artist actually does.
enum TutorialStep: Int, CaseIterable {
    case importModel, drawLoop, drawAnother, generate, editVertices, export

    var title: String {
        switch self {
        case .importModel: return "Bring in a model"
        case .drawLoop: return "Draw a loop"
        case .drawAnother: return "Draw another line"
        case .generate: return "Make quads"
        case .editVertices: return "Adjust a vertex"
        case .export: return "Take it to Blender"
        }
    }

    var detail: String {
        switch self {
        case .importModel: return "Tap Import in the top bar, or load the example, to get a model to draw on."
        case .drawLoop: return "With Draw Edges active, draw around a form with Apple Pencil. When the ends meet, tap Close Loop."
        case .drawAnother: return "Draw a second line beside the first. The line lands on the surface as real edges."
        case .generate: return "Choose Quad Patch, then tap each of your two lines. Review the preview and tap Create."
        case .editVertices: return "Choose Select, then drag a vertex. It stays on the surface as it moves."
        case .export: return "Tap Export and choose OBJ. Quads stay quads in Blender."
        }
    }

    var next: TutorialStep? { TutorialStep(rawValue: rawValue + 1) }

    func completes(on event: RetopoEngine.EngineEvent) -> Bool {
        switch self {
        case .importModel: return event == .modelImported
        case .drawLoop: return event == .loopClosed || event == .strokeCommitted
        case .drawAnother: return event == .strokeCommitted || event == .loopClosed
        case .generate: return event == .facesGenerated
        case .editVertices: return event == .vertexMoved
        case .export: return event == .exported
        }
    }
}
