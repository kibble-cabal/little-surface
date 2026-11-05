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
    var showsSettings = false
    var exportedFile: ExportedFile?

    enum SaveState: Equatable { case saved, unsaved, saving, failed(String) }

    @ObservationIgnored private var updateScheduled = false
    @ObservationIgnored private var gestureDepth = 0
    @ObservationIgnored private var knownGeneration: UInt64 = 0
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var timelapseTask: Task<Void, Never>?
    @ObservationIgnored private var linkServer: BlenderLinkServer?
    @ObservationIgnored private var outgoingMesh: (name: String, data: Data, faces: Int)?
    private(set) var linkIsOn = false
    private(set) var linkAddress: String?
    private(set) var linkStatus = ""
    let linkCode = BlenderLinkServer.savedCode()
    @ObservationIgnored private var surfaceTask: Task<Void, Never>?
    @ObservationIgnored private var subdivisionTask: Task<Void, Never>?
    @ObservationIgnored private var validationTask: Task<Void, Never>?
    @ObservationIgnored private var subdivisionKey: SubdivisionKey?

    private struct SubdivisionKey: Equatable {
        var topology: UInt64
        var positions: UInt64
        var levels: Int
    }

    init(document: ProjectDocument, snapshot: ProjectSnapshot) {
        self.document = document
        engine = RetopoEngine(snapshot: snapshot)
        // There's one pencil and one way of looking now, whatever an older project was left on.
        engine.setTool(.pencil)
        engine.viewport = ViewportSettings()
        engine.showsSketch = true
        for object in engine.sources {
            if !object.isVisible { engine.setSourceVisible(id: object.id, true) }
            if !object.isSnapTarget { engine.setSourceSnapTarget(id: object.id, true) }
        }
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
        guard tool != engine.activeTool else { return }
        engine.clearPick()
        engine.setTool(tool)
    }

    func pencilDoubleTapped() {
        select(tool: engine.activeTool == .erase ? .pencil : .erase)
    }

    // MARK: Background work: importing

    var isBusyImporting: Bool { importTask != nil }

    func importModel(from url: URL, mergedAs mergedName: String? = nil) {
        guard importTask == nil else { return }
        busy = BusyTask(title: "Reading \(url.lastPathComponent)…", cancellable: true)
        importTask = Task.detached(priority: .userInitiated) { [weak self] in
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            do {
                var model = try ModelImporter.load(url: url, isCancelled: { Task.isCancelled })
                if let mergedName {
                    model = ImportedModel(objects: [SourceObject.merged(model.objects, name: mergedName)], warnings: model.warnings, name: mergedName)
                }
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

    /// Opens a mesh from another app to keep editing, with its faces as they are in the file.
    func openMeshForEditing(from url: URL, replacing: Bool = false) {
        guard importTask == nil else { return }
        busy = BusyTask(title: "Reading \(url.lastPathComponent)…", cancellable: true)
        let needsSurface = engine.sources.isEmpty
        importTask = Task.detached(priority: .userInitiated) { [weak self] in
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            do {
                let imported = try MeshImporter.load(url: url, isCancelled: { Task.isCancelled })
                var surface: (object: SourceObject, bvh: TriangleBVH)?
                if needsSurface, imported.mesh.faceCount > 0 {
                    let object = imported.mesh.asSurface(named: "\(imported.name) (copy to draw on)")
                    let isCancelled: () -> Bool = { Task.isCancelled }
                    if let bvh = TriangleBVH(object: object, isCancelled: isCancelled) { surface = (object, bvh) }
                }
                try Task.checkCancellation()
                await MainActor.run { [surface] in self?.finishMeshImport(imported, surface: surface, replacing: replacing) }
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

    private func finishMeshImport(_ imported: ImportedMesh, surface: (object: SourceObject, bvh: TriangleBVH)?, replacing: Bool) {
        endImport()
        guard engine.addEditableMesh(imported, surface: surface, replacing: replacing) else { return }
        surfaceIsReady = true
        if engine.name == "Untitled" || engine.name.isEmpty { engine.name = imported.name }
        engine.say(Self.describe(imported, hasSurfaceCopy: surface != nil), kind: imported.skippedFaces > 0 ? .warning : .success)
        save()
        viewport?.setNeedsDisplay()
    }

    private static func describe(_ imported: ImportedMesh, hasSurfaceCopy: Bool) -> String {
        var text = "Opened \(imported.name) with \(imported.mesh.faceCount.formatted()) faces, ready to edit."
        if imported.skippedFaces > 0 {
            text += " \(imported.skippedFaces.formatted()) faces couldn't be kept, because they repeat a corner or give an edge more than two faces."
        }
        if imported.isTriangleFormat {
            text += " This format only stores triangles. Use OBJ to keep quads."
        }
        if hasSurfaceCopy {
            text += " A copy of it is the surface to draw on until you add your own."
        }
        return text
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
        timelapseTask?.cancel()
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
        timelapseTask?.cancel()
        setBlenderLink(false)
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
            case .obj: data = OBJExporter.export(mesh: snapshot.mesh.forExport(), name: name, sources: snapshot.sources, options: options)
            case .glb: data = GLBExporter.export(mesh: snapshot.mesh.forExport(), name: name, sources: snapshot.sources, options: options)
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

    func exportTimelapse() {
        guard busy == nil, let device = renderer?.device else { return }
        let snapshot = engine.makeSnapshot()
        let name = engine.name
        busy = BusyTask(title: "Making timelapse…", cancellable: true)
        timelapseTask = Task.detached(priority: .userInitiated) { [weak self] in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(ProjectLibrary.safeFileName("\(name) Timelapse")).appendingPathExtension("mp4")
            do {
                try TimelapseExporter.export(snapshot, device: device, to: url) { fraction in
                    Task { @MainActor in self?.busy?.title = "Making timelapse… \(Int(fraction * 100))%" }
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                await MainActor.run {
                    self?.busy = nil
                    self?.timelapseTask = nil
                    self?.exportedFile = ExportedFile(url: url, format: nil, byteCount: size)
                }
            } catch {
                await MainActor.run {
                    self?.busy = nil
                    self?.timelapseTask = nil
                    if !(error is CancellationError) {
                        self?.engine.say("The timelapse couldn't be made. \(error.localizedDescription)", kind: .error)
                    }
                }
            }
        }
    }

    // MARK: Blender link

    func setBlenderLink(_ on: Bool) {
        guard on != linkIsOn else { return }
        linkIsOn = on
        outgoingMesh = nil
        if on {
            startLinkServer()
        } else {
            linkServer?.stop()
            linkServer = nil
        }
    }

    /// The system won't keep a listener alive for an app that's left the screen.
    func blenderLinkSceneChanged(isActive: Bool) {
        guard linkIsOn else { return }
        if isActive {
            startLinkServer()
        } else {
            linkServer?.stop()
            linkServer = nil
        }
    }

    private func startLinkServer() {
        guard linkServer == nil else { return }
        linkAddress = BlenderLinkServer.localAddress()
        linkStatus = "Starting…"
        let server = BlenderLinkServer(code: linkCode) { [weak self] request in
            await self?.handleLinkRequest(request) ?? .message("The project has closed.", status: 409)
        }
        server.onStateChange = { [weak self] state in
            Task { @MainActor in self?.linkStateChanged(state, from: server) }
        }
        linkServer = server
        server.start()
    }

    private func linkStateChanged(_ state: BlenderLinkServer.State, from server: BlenderLinkServer) {
        guard server === linkServer else { return }
        switch state {
        case .listening: linkStatus = "Waiting for Blender."
        case .stopped: break
        case .failed(let reason):
            linkServer = nil
            linkIsOn = false
            linkStatus = ""
            engine.say("Blender Link stopped. \(reason)", kind: .error)
        }
    }

    /// Waits at the app for Blender's add-on to collect, since the iPad has no way to reach out to it.
    func sendMeshToBlender() {
        let snapshot = engine.makeSnapshot()
        let name = engine.name
        linkStatus = "Getting the mesh ready…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let data = OBJExporter.export(mesh: snapshot.mesh.forExport(), name: name, sources: [], options: ExportOptions())
            await MainActor.run {
                self?.outgoingMesh = (name, data, snapshot.mesh.faceCount)
                self?.linkStatus = "Waiting for Blender to collect it. Check Watch for Meshes is on there."
            }
        }
    }

    @MainActor
    func handleLinkRequest(_ request: LinkRequest) async -> LinkResponse {
        switch (request.method, request.path) {
        case ("GET", "/status"):
            let stats = engine.statistics
            linkStatus = "Connected to Blender."
            return .json(["project": engine.name, "vertices": stats.vertices, "faces": stats.faces, "sculpts": engine.sources.map(\.name)])
        case ("GET", "/mesh"):
            guard engine.mesh.faceCount > 0 else { return LinkResponse(status: 204) }
            let snapshot = engine.makeSnapshot()
            let name = engine.name
            let data = await Task.detached { OBJExporter.export(mesh: snapshot.mesh.forExport(), name: name, sources: [], options: ExportOptions()) }.value
            linkStatus = "Sent \(snapshot.mesh.faceCount.formatted()) faces to Blender."
            return Self.objResponse(data, name: name)
        case ("GET", "/outbox"):
            guard let outgoing = outgoingMesh else { return LinkResponse(status: 204) }
            outgoingMesh = nil
            linkStatus = "Blender collected \(outgoing.faces.formatted()) faces."
            engine.say("Sent \(outgoing.faces.formatted()) faces to Blender.", kind: .success)
            return Self.objResponse(outgoing.data, name: outgoing.name)
        case ("POST", "/mesh"):
            let replacing = request.query["replace"] == "1"
            return await receiveFromBlender(request) { model, url, _ in model.openMeshForEditing(from: url, replacing: replacing) }
        case ("POST", "/sculpt"):
            return await receiveFromBlender(request) { model, url, name in
                if let existing = model.engine.sources.first(where: { $0.name == name }) {
                    model.updateSculpt(id: existing.id, from: url)
                } else {
                    model.importModel(from: url, mergedAs: name)
                }
            }
        default:
            return .message("The app doesn't know that request. Check the add-on matches this version.", status: 404)
        }
    }

    private static func objResponse(_ data: Data, name: String) -> LinkResponse {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "Little%20Surface"
        return LinkResponse(status: 200, contentType: "text/plain", headers: ["X-Little-Surface-Name": encoded], body: data)
    }

    /// Runs the same import as a file picked here, so a mesh from Blender behaves like one from Files.
    @MainActor
    private func receiveFromBlender(_ request: LinkRequest, start: (EditorModel, URL, String) -> Void) async -> LinkResponse {
        guard busy == nil, importTask == nil else {
            return .message("Little Surface is busy with something else. Try again in a moment.", status: 409)
        }
        guard !request.body.isEmpty else { return .message("Nothing arrived to import.", status: 400) }
        let name = request.query["name"].flatMap { $0.isEmpty ? nil : $0 } ?? "From Blender"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Blender Link \(UUID().uuidString)", isDirectory: true)
        let url = folder.appendingPathComponent(ProjectLibrary.safeFileName(name)).appendingPathExtension("obj")
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try request.body.write(to: url)
        } catch {
            return .message("It couldn't be saved on the iPad. \(error.localizedDescription)", status: 422)
        }
        engine.clearMessage()
        start(self, url, name)
        await importTask?.value
        // The import reports its outcome the way it does for a file: as the message on screen.
        if let message = engine.message {
            linkStatus = message.text
            return .message(message.text, status: message.kind == .error ? 422 : 200)
        }
        return .message("It was stopped in Little Surface.", status: 409)
    }

    private func handle(_ event: RetopoEngine.EngineEvent) {
        switch event {
        case .loopClosed:
            viewport?.playPathCompleted()
        case .strokeSnapped:
            viewport?.playAlignment()
        default:
            break
        }
    }
}

struct ExportedFile: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    /// Nil for a timelapse video.
    let format: ExportFormat?
    let byteCount: Int
}
