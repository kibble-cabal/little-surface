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
    @State private var panelCollapsed = false
    @State private var importsModel = false
    @State private var sizedPanel = false

    var body: some View {
        ZStack {
            if model.renderer != nil {
                ViewportRepresentable(model: model).ignoresSafeArea()
            } else {
                Text("This device can't run the viewport because Metal isn't available.")
            }

            VStack(spacing: 8) {
                TopBar(model: model, importsModel: $importsModel)
                HStack(alignment: .top, spacing: 8) {
                    ToolBar(model: model)
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 8) {
                        OrientationGizmo(model: model)
                        ContextPanel(model: model, collapsed: $panelCollapsed)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                VStack(spacing: 8) {
                    MessageToast(model: model)
                    DecisionChips(model: model)
                    if let step = model.tutorialStep { TutorialCard(model: model, step: step) }
                    if settings.showsStatusBar { StatusBar(model: model) }
                }
            }
            .padding(10)

            if model.state.sources.isEmpty, model.busy == nil {
                EmptyViewportPrompt(model: model, importsModel: $importsModel)
            }
            if let busy = model.busy {
                BusyBanner(task: busy) { model.cancelBusyTask() }
            }
        }
        .background(Theme.page)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            // Portrait is narrow enough that the panel starts out of the way.
            if !sizedPanel {
                sizedPanel = true
                panelCollapsed = width < 1000
            }
        }
        .fileImporter(isPresented: $importsModel, allowedContentTypes: [.objModel, .glbModel, .gltfModel, .data]) { result in
            switch result {
            case .success(let url): model.importModel(from: url)
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
            if phase == .background || phase == .inactive, model.saveState == .unsaved { model.save() }
        }
    }
}

private struct EmptyViewportPrompt: View {
    let model: EditorModel
    @Binding var importsModel: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "cube.transparent").font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
            Text("Nothing to draw on yet").font(.headline)
            Text("Import a model. It stays separate from the topology you draw on it.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
            HStack {
                Button("Import Model") { importsModel = true }.buttonStyle(PillButtonStyle(prominent: true)).accessibilityIdentifier("Empty Import")
                Button("Use the Example") { model.importExample() }.buttonStyle(PillButtonStyle()).accessibilityIdentifier("Use Example")
            }
        }
        .padding(24)
        .panel()
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
                Button("Cancel", action: onCancel).buttonStyle(PillButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .panel()
        .accessibilityIdentifier("busy")
    }
}

// MARK: Top bar

private struct TopBar: View {
    let model: EditorModel
    @Binding var importsModel: Bool
    @Environment(AppModel.self) private var app
    @State private var renames = false
    @State private var draftName = ""
    @State private var showsDisplay = false
    @State private var showsExport = false
    @State private var showsObjects = false

    var body: some View {
        let engine = model.state
        HStack(spacing: 2) {
            IconButton(symbol: "chevron.left", label: "Projects", identifier: "Projects") {
                app.closeEditor()
            }
            Button {
                draftName = engine.name
                renames = true
            } label: {
                HStack(spacing: 6) {
                    Text(engine.name).font(.callout.weight(.medium)).lineLimit(1)
                    SaveIndicator(state: model.saveState)
                }
                .frame(minHeight: Theme.touchTarget)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Project name, \(engine.name)")
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
            Spacer(minLength: 8)
            IconButton(symbol: "square.and.arrow.down", label: "Import", identifier: "Import") { importsModel = true }
            IconButton(symbol: "square.stack.3d.up", label: "Objects", identifier: "Objects") { showsObjects = true }
                .popover(isPresented: $showsObjects) { ObjectsPopover(model: model) }
            IconButton(symbol: "internaldrive", label: "Save", identifier: "Save") { model.save() }
            IconButton(symbol: "square.and.arrow.up", label: "Export", identifier: "Export") { showsExport = true }
                .popover(isPresented: $showsExport) { ExportPopover(model: model, isPresented: $showsExport) }
            Divider().frame(height: 22).padding(.horizontal, 4)
            IconButton(symbol: "arrow.uturn.backward", label: "Undo", isEnabled: engine.canUndo, identifier: "Undo") { model.undo() }
            IconButton(symbol: "arrow.uturn.forward", label: "Redo", isEnabled: engine.canRedo, identifier: "Redo") { model.redo() }
            Divider().frame(height: 22).padding(.horizontal, 4)
            IconButton(symbol: "eye", label: "Display", identifier: "Display") { showsDisplay = true }
                .popover(isPresented: $showsDisplay) { DisplayPopover(model: model) }
            IconButton(symbol: "checkmark.seal", label: "Check Mesh", identifier: "Check Mesh") { model.showsValidation = true }
            IconButton(symbol: "gearshape", label: "Settings", identifier: "Settings") { model.showsSettings = true }
        }
        .padding(.horizontal, 4)
        .panel()
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
        }
    }

    var hint: String {
        switch self {
        case .select: return "Tap to select, drag a selected element to move it, drag elsewhere to lasso."
        case .drawEdges: return "Draw on the surface to add edges."
        case .edgeLoop: return "Draw around a form to make a closed loop."
        case .quadStrip: return "Draw a path to preview a band of quads."
        case .quadPatch: return "Tap or draw the lines to bridge, then create the patch."
        case .face: return "Tap three or four corners to make a face."
        case .moveBrush: return "Drag to push vertices along the surface."
        case .relaxBrush: return "Drag to even out vertices."
        case .erase: return "Drag over faces or edges to remove them."
        }
    }
}

private struct ToolBar: View {
    let model: EditorModel
    @State private var showsSymmetry = false

    private let groups: [[Tool]] = [[.select], [.drawEdges, .edgeLoop, .quadStrip, .quadPatch, .face], [.moveBrush, .relaxBrush, .erase]]

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
            Text(engine.activeTool.hint).lineLimit(1).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if !engine.selection.isEmpty {
                Text(selectionText(engine.selection)).foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("selection-status")
            }
            Text(statsText(stats)).monospacedDigit().accessibilityIdentifier("mesh-stats")
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .frame(minHeight: 30)
        .panel(corner: 10)
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
                .panel(corner: 12)
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
        case .warning: return .orange
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
                        .buttonStyle(PillButtonStyle(prominent: true)).accessibilityIdentifier("Close Loop")
                }
                Button(pending.canClose ? "Keep Open" : "Add Edges") { engine.commitPendingStroke(close: false) }
                    .buttonStyle(PillButtonStyle(prominent: !pending.canClose)).accessibilityIdentifier("Commit Stroke")
                Button("Cancel") { engine.cancelPending() }.buttonStyle(PillButtonStyle()).accessibilityIdentifier("Cancel Stroke")
            }
        } else if let strip = engine.pendingStrip {
            chipRow(note: strip.error ?? (strip.clippedAtCenterline ? "Stopped at the mirror plane." : nil)) {
                Button("Create Strip") { engine.commitPendingStrip() }
                    .buttonStyle(PillButtonStyle(prominent: true)).disabled(strip.plan == nil).accessibilityIdentifier("Create Strip")
                Button("Cancel") { engine.cancelPending() }.buttonStyle(PillButtonStyle())
            }
        } else if engine.activeTool == .quadPatch, !engine.patchChains.isEmpty {
            chipRow(note: engine.patchError ?? patchNote(engine)) {
                Button("Create Patch") { engine.commitPatch() }
                    .buttonStyle(PillButtonStyle(prominent: true)).disabled(engine.patchPreview == nil).accessibilityIdentifier("Create Patch")
                Button("Clear") { engine.clearPatchPicks() }.buttonStyle(PillButtonStyle()).accessibilityIdentifier("Clear Patch")
            }
        } else if engine.activeTool == .face, !engine.faceCorners.isEmpty {
            chipRow(note: "\(engine.faceCorners.count) corner\(engine.faceCorners.count == 1 ? "" : "s"). Tap more, or finish.") {
                Button("Create Face") { engine.commitFaceBuilder() }
                    .buttonStyle(PillButtonStyle(prominent: true)).disabled(engine.faceCorners.count < 3).accessibilityIdentifier("Create Face")
                Button("Undo Corner") { engine.undoFaceCorner() }.buttonStyle(PillButtonStyle())
                Button("Cancel") { engine.cancelFaceBuilder() }.buttonStyle(PillButtonStyle())
            }
        }
    }

    private func patchNote(_ engine: RetopoEngine) -> String {
        if let p = engine.patchPreview {
            var text = "\(p.columns) × \(p.rows) quads"
            if p.boundarySplits > 0 { text += ", splitting \(p.boundarySplits) boundary edge\(p.boundarySplits == 1 ? "" : "s")" }
            return text + "."
        }
        return "\(engine.patchChains.count) line picked. Pick another."
    }

    @ViewBuilder
    private func chipRow<Buttons: View>(note: String?, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 8) {
            if let note {
                Text(note).font(.footnote).foregroundStyle(.secondary).padding(.leading, 6).frame(maxWidth: 420, alignment: .leading)
                    .accessibilityIdentifier("decision-note")
            }
            buttons()
        }
        .padding(7)
        .panel(corner: 26)
    }
}

private struct TutorialCard: View {
    let model: EditorModel
    let step: TutorialStep

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(step.rawValue + 1) of \(TutorialStep.allCases.count)  ·  \(step.title)").font(.footnote.weight(.semibold))
                Text(step.detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Skip") { model.endTutorial() }.buttonStyle(PillButtonStyle()).accessibilityIdentifier("Skip Tutorial")
            if step.next != nil {
                Button("Next") { model.tutorialStep = step.next }.buttonStyle(PillButtonStyle()).accessibilityIdentifier("Next Tutorial")
            } else {
                Button("Done") { model.endTutorial() }.buttonStyle(PillButtonStyle(prominent: true))
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
