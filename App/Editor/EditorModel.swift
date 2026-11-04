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
    @ObservationIgnored private var changeCount: UInt64 = 0
    @ObservationIgnored private var autosaveTimer: Timer?
    @ObservationIgnored private var isWriting = false
    @ObservationIgnored private var pendingSaves: [((Bool) -> Void)?] = []
    @ObservationIgnored private var memoryObserver: NSObjectProtocol?
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
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            self?.engine.releaseUndoMemory()
        }
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
        markUnsaved()
        if gestureDepth == 0 { refreshSubdivisionPreview() }
    }

    /// For settings that the engine lets panels set directly.
    func settingChanged() {
        markUnsaved()
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

    /// Replaces a source with a changed version from a file, and snaps the topology onto it. Until the
    /// new surface is ready nothing changes, so cancelling or a bad file leaves everything as it was.
    func updateSculpt(id: UUID, from url: URL) {
        guard importTask == nil, let name = engine.sources.first(where: { $0.id == id })?.name else { return }
        busy = BusyTask(title: "Reading \(url.lastPathComponent)…", cancellable: true)
        importTask = Task.detached(priority: .userInitiated) { [weak self] in
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            do {
                let model = try ModelImporter.load(url: url, isCancelled: { Task.isCancelled })
                let merged = SourceObject.merged(model.objects, id: id, name: name)
                await MainActor.run { self?.busy?.title = "Preparing the surface…" }
                let isCancelled: () -> Bool = { Task.isCancelled }
                let bvh = TriangleBVH(object: merged, isCancelled: isCancelled)
                try Task.checkCancellation()
                guard let bvh else { throw ImportError.noGeometry }
                await MainActor.run { self?.finishSculptUpdate(id: id, merged: merged, bvh: bvh) }
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

    private func finishSculptUpdate(id: UUID, merged: SourceObject, bvh: TriangleBVH) {
        endImport()
        guard let result = engine.updateSource(id: id, with: merged, bvh: bvh) else { return }
        engine.say(Self.describe(result, name: merged.name), kind: result.unreachableVertices > 0 || !result.snapped ? .warning : .success)
        refreshSubdivisionPreview()
        save()
        viewport?.setNeedsDisplay()
    }

    private static func describe(_ result: RetopoEngine.SculptUpdate, name: String) -> String {
        guard result.snapped else {
            return "Updated \(name). It isn't a surface to draw on right now, so your topology stayed where it was. Undo puts the old version back."
        }
        var text = "Updated \(name) and moved \(result.movedVertices.formatted()) vertices onto it."
        if result.unreachableVertices > 0 {
            text += " \(result.unreachableVertices.formatted()) were too far away to follow and are selected."
        }
        if result.sizeRatio > 2 || result.sizeRatio < 0.5 {
            text += " The new file is a very different size, so check its export scale. Undo puts the old version back."
        }
        return text
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

    /// Seconds without a change before saving, and before trying again after a failure.
    private static let autosaveDelay: TimeInterval = 2
    private static let retryDelay: TimeInterval = 15

    private func markUnsaved() {
        changeCount &+= 1
        saveState = .unsaved
        document.updateChangeCount(.done)
        scheduleAutosave(after: Self.autosaveDelay)
    }

    private func scheduleAutosave(after delay: TimeInterval) {
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.autosave()
        }
    }

    private func autosave() {
        // Writing can wait for a stroke to finish. Copying the state for it would be felt mid-stroke.
        if gestureDepth > 0 {
            scheduleAutosave(after: Self.autosaveDelay)
            return
        }
        save(storesThumbnail: false)
    }

    /// Saves what's there now. A save already running is left to finish, then followed by this one, so
    /// the last save always holds the latest state. Reports whether the file on disk is up to date.
    func save(storesThumbnail: Bool = true, completion: ((Bool) -> Void)? = nil) {
        guard document.documentState.contains(.closed) == false else {
            completion?(false)
            return
        }
        autosaveTimer?.invalidate()
        if isWriting {
            pendingSaves.append(completion)
            return
        }
        isWriting = true
        saveState = .saving
        let countAtStart = changeCount
        document.updateChangeCount(.done)
        document.save(to: document.fileURL, for: .forOverwriting) { [weak self] ok in
            guard let self else { return }
            self.isWriting = false
            if ok {
                // Anything changed while the save ran isn't in the file yet.
                let isCurrent = self.changeCount == countAtStart
                self.saveState = isCurrent ? .saved : .unsaved
                if storesThumbnail { self.storeThumbnail() }
                if !isCurrent { self.scheduleAutosave(after: Self.autosaveDelay) }
            } else {
                let reason = self.document.lastSaveError?.localizedDescription ?? "The project couldn't be saved."
                // One message per run of failures, while it keeps trying in the background.
                if case .failed = self.saveState {} else { self.engine.say("Couldn't save. \(reason)", kind: .error) }
                self.saveState = .failed(reason)
                self.scheduleAutosave(after: Self.retryDelay)
            }
            let waiting = self.pendingSaves
            self.pendingSaves = []
            if waiting.isEmpty {
                completion?(ok && self.saveState == .saved)
            } else {
                completion?(ok && self.saveState == .saved)
                self.save(storesThumbnail: storesThumbnail) { latest in waiting.forEach { $0?(latest) } }
            }
        }
    }

    /// Saves as the app leaves the screen, asking for enough time to finish the write.
    func saveForBackground() {
        guard saveState != .saved || isWriting else { return }
        let application = UIApplication.shared
        var task = UIBackgroundTaskIdentifier.invalid
        task = application.beginBackgroundTask(withName: "Save project") {
            application.endBackgroundTask(task)
            task = .invalid
        }
        save(storesThumbnail: false) { _ in
            guard task != .invalid else { return }
            application.endBackgroundTask(task)
            task = .invalid
        }
    }

    /// Saves, then closes only if that worked. On failure the project stays open, so nothing is lost
    /// without the person saying so.
    func close(discardingChanges: Bool = false, completion: @escaping (Bool) -> Void) {
        guard !discardingChanges else {
            finishClosing { completion(true) }
            return
        }
        storeThumbnail()
        save(storesThumbnail: false) { [weak self] ok in
            guard let self else { return }
            guard ok else {
                completion(false)
                return
            }
            self.finishClosing { completion(true) }
        }
    }

    private func finishClosing(_ completion: @escaping () -> Void) {
        importTask?.cancel()
        surfaceTask?.cancel()
        subdivisionTask?.cancel()
        validationTask?.cancel()
        autosaveTimer?.invalidate()
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
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
        if let step = tutorialStep, step.completes(on: event) { tutorialStep = step.next }
        switch event {
        case .patchCreated:
            if AppSettings.shared.selectsAfterPatch { select(tool: .select) }
        case .loopClosed:
            viewport?.playPathCompleted()
        case .strokeSnapped:
            viewport?.playAlignment()
        default:
            break
        }
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
        case .drawLoop: return "With Draw Edges active, draw around a form with Apple Pencil. When the ends land near each other, the line closes into a loop."
        case .drawAnother: return "Draw two lines side by side. They land on the surface as real edges."
        case .generate: return "Tap Fill with Quads to bridge your two lines. For more control, tap each line, then tap Create Patch."
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
