import LittleSurfaceCore
import MetalKit
import SwiftUI
import UniformTypeIdentifiers

struct ViewportRepresentable: UIViewRepresentable {
    let model: EditorModel
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> ViewportView {
        let view = ViewportView(frame: .zero, device: model.renderer?.device)
        model.attach(viewport: view)
        return view
    }

    func updateUIView(_ view: ViewportView, context: Context) {
        model.renderer?.isDark = colorScheme == .dark
        view.setNeedsDisplay()
    }
}

struct EditorView: View {
    let model: EditorModel
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings = AppSettings.shared
    @State private var showsInspector = false
    @State private var importsModel = false
    @State private var importsAsMesh = false
    @State private var sizedPanel = false

    private func applyDrawingSettings() {
        model.engine.closesLoopsAutomatically = settings.closesLoopsAutomatically
        model.engine.suggestsFills = settings.suggestsFills
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if model.renderer != nil {
                    ViewportRepresentable(model: model).ignoresSafeArea()
                } else {
                    Text("This device can't run the viewport because Metal isn't available.")
                }

                VStack(spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        ToolBar(model: model)
                        Spacer(minLength: 0)
                        OrientationGizmo(model: model)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    VStack(spacing: 8) {
                        MessageToast(model: model)
                        if model.state.activeTool == .sketch {
                            SketchBar(model: model).padding(8).panel()
                        }
                        DecisionChips(model: model)
                        if let step = model.tutorialStep { TutorialCard(model: model, step: step) }
                    }
                }
                .padding(10)

                if model.state.sources.isEmpty, model.busy == nil {
                    EmptyViewportPrompt(model: model, importsModel: $importsModel, importsAsMesh: $importsAsMesh)
                }
                if let busy = model.busy {
                    BusyBanner(task: busy) { model.cancelBusyTask() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if settings.showsStatusBar { StatusBar(model: model) }
            }
            .toolbar { EditorToolbar(model: model, importsModel: $importsModel, importsAsMesh: $importsAsMesh, showsInspector: $showsInspector) }
            .navigationBarTitleDisplayMode(.inline)
            .inspector(isPresented: $showsInspector) {
                ContextPanel(model: model)
                    .inspectorColumnWidth(min: 280, ideal: 310, max: 380)
            }
        }
        .background(Theme.page)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            // Portrait is narrow enough that the inspector starts out of the way.
            if !sizedPanel {
                sizedPanel = true
                showsInspector = width >= 1000
            }
        }
        .onAppear(perform: applyDrawingSettings)
        .onChange(of: settings.closesLoopsAutomatically) { applyDrawingSettings() }
        .onChange(of: settings.suggestsFills) { applyDrawingSettings() }
        .fileImporter(isPresented: $importsModel, allowedContentTypes: [.objModel, .glbModel, .gltfModel, .data]) { result in
            switch result {
            case .success(let url):
                if importsAsMesh { model.openMeshForEditing(from: url) } else { model.importModel(from: url) }
            case .failure(let error): model.engine.say(error.localizedDescription, kind: .error)
            }
        }
        .sheet(isPresented: Binding(get: { model.showsSettings }, set: { model.showsSettings = $0 })) {
            SettingsView(onReplayTutorial: { model.startTutorial() })
        }
        .sheet(isPresented: Binding(get: { model.showsValidation }, set: { model.showsValidation = $0 })) {
            ValidationView(model: model).presentationDetents([.medium, .large]).presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .sheet(item: Binding(get: { model.exportedFile }, set: { model.exportedFile = $0 })) { file in
            ShareSheet(url: file.url).ignoresSafeArea()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive { model.saveForBackground() }
            if phase == .background { model.blenderLinkSceneChanged(isActive: false) }
            if phase == .active { model.blenderLinkSceneChanged(isActive: true) }
        }
    }
}

private struct EmptyViewportPrompt: View {
    let model: EditorModel
    @Binding var importsModel: Bool
    @Binding var importsAsMesh: Bool

    var body: some View {
        ContentUnavailableView {
            Label("Nothing to Draw On Yet", systemImage: "cube.transparent")
        } description: {
            Text("Import a model. It stays separate from the topology you draw on it.")
        } actions: {
            Button("Import Model") {
                importsAsMesh = false
                importsModel = true
            }
            .pillButton(prominent: true).accessibilityIdentifier("Empty Import")
            Button("Open a Mesh to Edit") {
                importsAsMesh = true
                importsModel = true
            }
            .pillButton()
            .accessibilityIdentifier("Empty Open Mesh")
            Button("Use the Example") { model.importExample() }.pillButton().accessibilityIdentifier("Use Example")
        }
    }
}

private struct BusyBanner: View {
    let task: BusyTask
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(task.title).font(.callout)
            if task.cancellable {
                Button("Cancel", action: onCancel).pillButton()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .panel()
        .accessibilityIdentifier("busy")
    }
}

// MARK: Navigation bar

private struct EditorToolbar: ToolbarContent {
    let model: EditorModel
    @Binding var importsModel: Bool
    @Binding var importsAsMesh: Bool
    @Binding var showsInspector: Bool
    @Environment(AppModel.self) private var app
    @State private var renames = false
    @State private var draftName = ""
    @State private var showsDisplay = false
    @State private var showsExport = false
    @State private var showsObjects = false
    @State private var showsBlenderLink = false

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { app.closeEditor() } label: { Label("Projects", systemImage: "chevron.backward") }
                .accessibilityIdentifier("Projects")
        }
        ToolbarItem(placement: .topBarLeading) { projectName }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button {
                    importsAsMesh = false
                    importsModel = true
                } label: { Label("Model to Draw On…", systemImage: "cube") }
                .accessibilityIdentifier("Import Model to Draw On")
                Button {
                    importsAsMesh = true
                    importsModel = true
                } label: { Label("Mesh to Keep Editing…", systemImage: "square.and.pencil") }
                .accessibilityIdentifier("Import Mesh to Edit")
                Button { showsBlenderLink = true } label: { Label("Blender Link…", systemImage: "link") }
                    .accessibilityIdentifier("Blender Link")
            } label: { Label("Import", systemImage: "square.and.arrow.down") }
                .accessibilityIdentifier("Import")
                .sheet(isPresented: $showsBlenderLink) { BlenderLinkView(model: model) }
            Button { showsObjects = true } label: { Label("Objects", systemImage: "square.stack.3d.up") }
                .accessibilityIdentifier("Objects")
                .popover(isPresented: $showsObjects) { ObjectsPopover(model: model) }
            Button { model.save() } label: { Label("Save", systemImage: "internaldrive") }
                .accessibilityIdentifier("Save")
            Button { showsExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .accessibilityIdentifier("Export")
                .popover(isPresented: $showsExport) { ExportPopover(model: model, isPresented: $showsExport) }
            Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!model.state.canUndo)
                .accessibilityIdentifier("Undo")
            Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!model.state.canRedo)
                .accessibilityIdentifier("Redo")
            Button { showsDisplay = true } label: { Label("Display", systemImage: "eye") }
                .accessibilityIdentifier("Display")
                .popover(isPresented: $showsDisplay) { DisplayPopover(model: model) }
            Button { model.showsValidation = true } label: { Label("Check Mesh", systemImage: "checkmark.seal") }
                .accessibilityIdentifier("Check Mesh")
            Button { model.showsSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                .accessibilityIdentifier("Settings")
            Button { showsInspector.toggle() } label: { Label(showsInspector ? "Hide Options" : "Show Options", systemImage: "sidebar.trailing") }
                .accessibilityIdentifier("Toggle Options")
        }
    }

    private var projectName: some View {
        let name = model.state.name
        return Button {
            draftName = name
            renames = true
        } label: {
            HStack(spacing: 6) {
                Text(name).font(.headline).lineLimit(1)
                SaveIndicator(state: model.saveState)
            }
        }
        .tint(.primary)
        .accessibilityLabel("Project name, \(name)")
        .accessibilityHint("Rename")
        .accessibilityIdentifier("Project Name")
        .popover(isPresented: $renames) {
            TextField("Project name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .padding()
                .onSubmit {
                    let name = draftName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        model.engine.name = name
                        ProjectLibrary.shared.rename(model.document, to: name)
                        model.settingChanged()
                    }
                    renames = false
                }
        }
    }
}

private struct SaveIndicator: View {
    let state: EditorModel.SaveState
    var body: some View {
        switch state {
        case .saved: EmptyView()
        case .saving: ProgressView().controlSize(.mini)
        case .unsaved: Circle().fill(Color.secondary.opacity(0.5)).frame(width: 6, height: 6).accessibilityLabel("Unsaved changes")
        case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).accessibilityLabel("Save failed")
        }
    }
}

// MARK: Left toolbar

extension Tool {
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .drawEdges: return "pencil.tip"
        case .edgeLoop: return "lasso"
        case .quadStrip: return "rectangle.split.3x1"
        case .quadPatch: return "square.grid.2x2"
        case .face: return "skew"
        case .moveBrush: return "hand.draw"
        case .relaxBrush: return "wind"
        case .erase: return "eraser"
        case .sketch: return "scribble.variable"
        }
    }

    var label: String {
        switch self {
        case .select: return "Select and Edit"
        case .drawEdges: return "Draw Edges"
        case .edgeLoop: return "Edge Loop"
        case .quadStrip: return "Quad Strip"
        case .quadPatch: return "Quad Patch"
        case .face: return "Make Faces"
        case .moveBrush: return "Move Brush"
        case .relaxBrush: return "Relax Brush"
        case .erase: return "Erase"
        case .sketch: return "Sketch"
        }
    }

    var hint: String {
        switch self {
        case .select: return "Tap to select, drag a selected element to move it, drag elsewhere to lasso."
        case .drawEdges: return "Draw on the surface to add edges, or tap two lines to fill between them."
        case .edgeLoop: return "Draw around a form to make a closed loop."
        case .quadStrip: return "Draw a path to preview a band of quads."
        case .quadPatch: return "Tap or draw the lines to bridge, then create the patch."
        case .face: return "Tap three or four corners to make a face."
        case .moveBrush: return "Drag to push vertices along the surface."
        case .relaxBrush: return "Drag to even out vertices."
        case .erase: return "Drag over faces or edges to remove them."
        case .sketch: return "Doodle planning lines to trace over. They stay out of your mesh and exports."
        }
    }
}

private struct ToolBar: View {
    let model: EditorModel
    @State private var showsSymmetry = false

    private let groups: [[Tool]] = [[.select], [.sketch], [.drawEdges, .edgeLoop, .quadStrip, .quadPatch, .face], [.moveBrush, .relaxBrush, .erase]]

    var body: some View {
        let engine = model.state
        // Read here, so SwiftUI sees the change. ForEach content only reruns when what it captures differs.
        let activeTool = engine.activeTool
        let symmetryOn = engine.symmetry.isEnabled
        let tools = VStack(spacing: 2) {
                ForEach(groups.indices, id: \.self) { g in
                    if g > 0 { Divider().frame(width: 24).padding(.vertical, 3) }
                    ForEach(groups[g], id: \.self) { tool in
                        IconButton(symbol: tool.symbol, label: tool.label, isActive: activeTool == tool, identifier: "tool-\(tool.rawValue)") {
                            model.select(tool: tool)
                        }
                    }
                }
                Divider().frame(width: 24).padding(.vertical, 3)
                IconButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", label: "Symmetry", isActive: symmetryOn, identifier: "Symmetry") {
                    showsSymmetry = true
                }
                .popover(isPresented: $showsSymmetry, arrowEdge: .leading) { SymmetryPopover(model: model) }
            }
            .padding(4)
        ViewThatFits(in: .vertical) {
            tools
            ScrollView(.vertical, showsIndicators: false) { tools }
        }
        .fixedSize(horizontal: true, vertical: false)
        .panel()
    }
}

// MARK: Orientation gizmo

private struct OrientationGizmo: View {
    let model: EditorModel

    private struct Axis: Identifiable {
        let id: String
        let direction: Vec3Value
        let preset: ViewPreset
        let color: Color
        let positive: Bool
    }

    private struct Vec3Value { let x, y, z: Float }

    private let axes: [Axis] = [
        Axis(id: "X", direction: .init(x: 1, y: 0, z: 0), preset: .right, color: Color(red: 0.82, green: 0.30, blue: 0.27), positive: true),
        Axis(id: "-X", direction: .init(x: -1, y: 0, z: 0), preset: .left, color: Color(red: 0.82, green: 0.30, blue: 0.27), positive: false),
        Axis(id: "Y", direction: .init(x: 0, y: 1, z: 0), preset: .top, color: Color(red: 0.36, green: 0.62, blue: 0.27), positive: true),
        Axis(id: "-Y", direction: .init(x: 0, y: -1, z: 0), preset: .bottom, color: Color(red: 0.36, green: 0.62, blue: 0.27), positive: false),
        Axis(id: "Z", direction: .init(x: 0, y: 0, z: 1), preset: .front, color: Color(red: 0.25, green: 0.47, blue: 0.80), positive: true),
        Axis(id: "-Z", direction: .init(x: 0, y: 0, z: -1), preset: .back, color: Color(red: 0.25, green: 0.47, blue: 0.80), positive: false),
    ]

    var body: some View {
        _ = model.cameraRevision
        _ = model.revision
        let camera = model.engine.camera
        let right = camera.right, up = camera.up, back = -camera.forward
        let radius: CGFloat = 30
        func placed(_ a: Axis) -> (x: CGFloat, y: CGFloat, depth: Float) {
            let d = SIMD3<Float>(a.direction.x, a.direction.y, a.direction.z)
            return (CGFloat(simd_dot(d, right)) * radius, CGFloat(-simd_dot(d, up)) * radius, simd_dot(d, back))
        }
        let ordered = axes.sorted { placed($0).depth < placed($1).depth }
        return ZStack {
            ForEach(ordered) { axis in
                let p = placed(axis)
                Button {
                    model.engine.camera.setPreset(axis.preset)
                    model.engine.cameraChanged()
                    model.cameraDidChange()
                } label: {
                    ZStack {
                        Circle().fill(axis.positive ? axis.color : axis.color.opacity(0.28)).frame(width: 22, height: 22)
                        if axis.positive {
                            Text(axis.id).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        }
                    }
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .offset(x: p.x, y: p.y)
                .accessibilityLabel("\(axis.preset.rawValue.capitalized) view")
                .accessibilityIdentifier("view-\(axis.preset.rawValue)")
            }
        }
        .frame(width: 92, height: 92)
        .panel(corner: 46)
    }
}

// MARK: Status bar, messages and decisions

private struct StatusBar: View {
    let model: EditorModel

    var body: some View {
        let engine = model.state
        let stats = engine.statistics
        HStack(spacing: 14) {
            Text(engine.activeTool.hint).lineLimit(1).foregroundStyle(Theme.quiet)
            Spacer(minLength: 8)
            if !engine.selection.isEmpty {
                Text(selectionText(engine.selection)).foregroundStyle(Theme.selection)
                    .lineLimit(1).fixedSize()
                    .accessibilityIdentifier("selection-status")
            }
            BudgetChip(model: model)
            // The hint gives way first: the counts are what people glance at.
            Text(statsText(stats)).monospacedDigit().lineLimit(1).fixedSize().accessibilityIdentifier("mesh-stats")
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .frame(minHeight: 30)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func selectionText(_ s: Selection) -> String {
        switch s.mode {
        case .vertex: return "\(s.vertices.count) selected"
        case .edge: return "\(s.edges.count) selected"
        case .face: return "\(s.faces.count) selected"
        }
    }

    private func statsText(_ s: MeshStatistics) -> String {
        var parts = ["V \(s.vertices)", "E \(s.edges)", "F \(s.faces)", "Quads \(s.quads)", "Tris \(s.triangles)"]
        if s.ngons > 0 { parts.append("N-gons \(s.ngons)") }
        parts.append("Parts \(s.components)")
        return parts.joined(separator: "   ")
    }
}

/// The live count against the target. Tapping it opens the budget and the jumps to what needs a look.
private struct BudgetChip: View {
    let model: EditorModel
    @State private var showsCheck = false

    var body: some View {
        let engine = model.state
        let count = engine.statistics.triangleEquivalent
        let budget = engine.polyBudget
        let isOver = budget.map { count > $0 } ?? false
        let isClose = budget.map { Double(count) >= Double($0) * 0.9 } ?? false
        Button { showsCheck = true } label: {
            HStack(spacing: 4) {
                Image(systemName: isOver ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.33percent")
                Text(budget.map { "\(count.formatted()) / \($0.formatted()) tris" } ?? "\(count.formatted()) tris")
                    .monospacedDigit()
                    .accessibilityIdentifier("budget-count")
            }
            .foregroundStyle(isOver ? Color.red : (isClose ? Color.orange : Color.accentColor))
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lineLimit(1)
        .fixedSize()
        .accessibilityIdentifier("budget-status")
        .accessibilityHint("Set a triangle budget and find what needs a look")
        .popover(isPresented: $showsCheck, arrowEdge: .bottom) { TopologyCheckPopover(model: model) }
    }
}

private struct MessageToast: View {
    let model: EditorModel

    var body: some View {
        if let message = model.state.message {
            Button { model.engine.clearMessage() } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon(message.kind)).foregroundStyle(color(message.kind))
                    Text(message.text).font(.footnote).multilineTextAlignment(.leading).foregroundStyle(.primary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: 560)
                .panel(corner: 16)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("message")
            .task(id: message.id) {
                try? await Task.sleep(for: .seconds(message.kind == .error ? 9 : 5))
                if !Task.isCancelled, model.engine.message?.id == message.id { model.engine.clearMessage() }
            }
        }
    }

    private func icon(_ kind: EngineMessage.Kind) -> String {
        switch kind {
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private func color(_ kind: EngineMessage.Kind) -> Color {
        switch kind {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .yellow
        case .error: return .red
        }
    }
}

/// Decisions the current tool is waiting on, near where the Pencil just was.
private struct DecisionChips: View {
    let model: EditorModel

    var body: some View {
        let engine = model.state
        if let pending = engine.pendingStroke {
            chipRow(note: pending.note ?? (pending.canClose ? "The ends are close together." : nil)) {
                if pending.canClose, pending.closedPlan != nil {
                    Button("Close Loop") { engine.commitPendingStroke(close: true) }
                        .pillButton(prominent: true).accessibilityIdentifier("Close Loop")
                }
                Button(pending.canClose ? "Keep Open" : "Add Edges") { engine.commitPendingStroke(close: false) }
                    .pillButton(prominent: !pending.canClose).accessibilityIdentifier("Commit Stroke")
                Button("Cancel") { engine.cancelPending() }.pillButton().accessibilityIdentifier("Cancel Stroke")
            }
        } else if let strip = engine.pendingStrip {
            chipRow(note: strip.error ?? (strip.clippedAtCenterline ? "Stopped at the mirror plane." : (strip.openPath != nil ? "The ends meet, so this makes a ring." : nil))) {
                Button("Create Strip") { engine.commitPendingStrip() }
                    .pillButton(prominent: true).disabled(strip.plan == nil).accessibilityIdentifier("Create Strip")
                if strip.openPath != nil {
                    Button("Keep Open") { engine.keepStripOpen() }.pillButton().accessibilityIdentifier("Keep Strip Open")
                }
                Button("Cancel") { engine.cancelPending() }.pillButton()
            }
        } else if engine.activeTool == .quadPatch || engine.activeTool == .drawEdges, !engine.patchChains.isEmpty {
            chipRow(note: engine.patchError ?? patchNote(engine)) {
                Button("Create Patch") { engine.commitPatch() }
                    .pillButton(prominent: true).disabled(engine.patchPreview == nil).accessibilityIdentifier("Create Patch")
                Button("Clear") { engine.clearPatchPicks() }.pillButton().accessibilityIdentifier("Clear Patch")
            }
        } else if let suggestion = engine.fillSuggestion {
            let shapes = suggestion.preview.kind == .ring ? "loops" : "lines"
            chipRow(note: "\(suggestion.preview.columns) × \(suggestion.preview.rows) quads would fill between these \(shapes).") {
                Button("Fill with Quads") { engine.commitFillSuggestion() }.pillButton(prominent: true).accessibilityIdentifier("Fill with Quads")
                if engine.reopenablePlans != nil {
                    Button("Keep Open") { engine.keepLoopOpen() }.pillButton().accessibilityIdentifier("Keep Open")
                }
                Button("Not Now") { engine.dismissFillSuggestion() }.pillButton().accessibilityIdentifier("Not Now")
            }
        } else if engine.reopenablePlans != nil {
            chipRow(note: "Closed into a loop.") {
                Button("Keep Open") { engine.keepLoopOpen() }.pillButton().accessibilityIdentifier("Keep Open")
            }
        } else if engine.activeTool == .face, !engine.faceCorners.isEmpty {
            chipRow(note: "\(engine.faceCorners.count) corner\(engine.faceCorners.count == 1 ? "" : "s"). Tap more, or finish.") {
                Button("Create Face") { engine.commitFaceBuilder() }
                    .pillButton(prominent: true).disabled(engine.faceCorners.count < 3).accessibilityIdentifier("Create Face")
                Button("Undo Corner") { engine.undoFaceCorner() }.pillButton()
                Button("Cancel") { engine.cancelFaceBuilder() }.pillButton()
            }
        }
    }

    private func patchNote(_ engine: RetopoEngine) -> String {
        if let p = engine.patchPreview {
            var text = "\(p.columns) × \(p.rows) quads"
            if p.boundarySplits > 0 { text += ", splitting \(p.boundarySplits) boundary edge\(p.boundarySplits == 1 ? "" : "s")" }
            return text + "."
        }
        return "One line picked. Draw or tap a second line, or draw a closed shape."
    }

    @ViewBuilder
    private func chipRow<Buttons: View>(note: String?, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 8) {
            if let note {
                Text(note).font(.subheadline).foregroundStyle(Theme.quiet).padding(.leading, 8).frame(maxWidth: 420, alignment: .leading)
                    .accessibilityIdentifier("decision-note")
            }
            buttons()
        }
        .padding(8)
        .panel(corner: 28)
    }
}

private struct TutorialCard: View {
    let model: EditorModel
    let step: TutorialStep

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(step.rawValue + 1) of \(TutorialStep.allCases.count)  ·  \(step.title)").font(.footnote.weight(.semibold))
                Text(step.detail).font(.footnote).foregroundStyle(Theme.quiet)
            }
            Spacer(minLength: 4)
            Button("Skip") { model.endTutorial() }.pillButton().accessibilityIdentifier("Skip Tutorial")
            if step.next != nil {
                Button("Next") { model.tutorialStep = step.next }.pillButton().accessibilityIdentifier("Next Tutorial")
            } else {
                Button("Done") { model.endTutorial() }.pillButton(prominent: true)
            }
        }
        .padding(12)
        .frame(maxWidth: 620)
        .panel()
        .accessibilityIdentifier("tutorial")
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
