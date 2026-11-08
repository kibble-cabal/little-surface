import LittleSurfaceCore
import MetalKit
import SwiftUI
import simd
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var importsModel = false
    @State private var importsAsMesh = false

    var body: some View {
        NavigationStack {
            ZStack {
                if model.renderer != nil {
                    ViewportRepresentable(model: model).ignoresSafeArea()
                } else {
                    Text("This device can't run the viewport because Metal isn't available.")
                }

                BrushSizeSlider(model: model)

                VStack(spacing: 8) {
                    VStack(alignment: .trailing, spacing: 8) {
                        OrientationGizmo(model: model)
                        MirrorAxisPicker(model: model)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    // Moves over to the guide's left while it's open.
                    .padding(.trailing, model.showsGuide ? 370 : 0)
                    Spacer(minLength: 0)
                    MessageToast(model: model)
                    PickChips(model: model)
                    BudgetChip(model: model)
                }
                .padding(10)

                if model.showsGuide {
                    GuidePanel(model: model)
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                if model.state.sources.isEmpty, model.busy == nil {
                    EmptyViewportPrompt(model: model, importsModel: $importsModel, importsAsMesh: $importsAsMesh)
                }
                if let busy = model.busy {
                    BusyBanner(task: busy) { model.cancelBusyTask() }
                }
            }
            .toolbar { EditorToolbar(model: model, importsModel: $importsModel, importsAsMesh: $importsAsMesh) }
            .navigationBarTitleDisplayMode(.inline)
        }
        // On top of the bar, which swallows taps along its bottom edge rather than passing them down.
        .overlay { ToolButtonReach(model: model) }
        .tint(.primary)
        .background(Theme.page)
        .fileImporter(isPresented: $importsModel, allowedContentTypes: [.objModel, .glbModel, .gltfModel, .data]) { result in
            switch result {
            case .success(let url):
                if importsAsMesh { model.openMeshForEditing(from: url) } else { model.importModel(from: url) }
            case .failure(let error): model.engine.say(error.localizedDescription, kind: .error)
            }
        }
        .sheet(isPresented: Binding(get: { model.showsSettings }, set: { model.showsSettings = $0 })) {
            SettingsView()
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
        VStack(spacing: 10) {
            Button("Import Model") {
                importsAsMesh = false
                importsModel = true
            }
            .pillButton(prominent: true)
            .accessibilityIdentifier("Empty Import")
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

/// The bar stops taking taps just under its icons, which is easy to miss with a Pencil. This carries on
/// below each tool button, invisibly, so a tap that lands a little low still counts.
private struct ToolButtonReach: View {
    var model: EditorModel

    var body: some View {
        VStack {
            HStack(spacing: 0) {
                ForEach([Tool.pencil, .relaxBrush, .moveBrush, .erase], id: \.self) { tool in
                    Button { model.select(tool: tool) } label: {
                        Color.clear
                            .frame(width: Theme.touchTarget, height: Self.depth)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, Self.top)
            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }

    /// Starts level with the icons, above where the bar stops taking taps, and ends 30pt or so below them.
    private static let top: CGFloat = 30
    private static let depth: CGFloat = 42
}

private struct EditorToolbar: ToolbarContent {
    let model: EditorModel
    @Binding var importsModel: Bool
    @Binding var importsAsMesh: Bool
    @Environment(AppModel.self) private var app
    @State private var renames = false
    @State private var draftName = ""
    @State private var showsExport = false
    @State private var showsSculpts = false
    @State private var showsBudget = false
    @State private var showsBlenderLink = false

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { app.closeEditor() } label: { Label("Projects", systemImage: "chevron.backward") }
                .accessibilityIdentifier("Projects")
        }
        if case .failed = model.saveState {
            ToolbarItem(placement: .topBarLeading) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).accessibilityLabel("Save failed")
            }
        }
        ToolbarItem(placement: .principal) {
            // Side by side with no gap, or a tap between them lands on the drawing underneath.
            HStack(spacing: 0) {
                toolButton(.pencil, label: "Draw", symbol: "pencil.tip")
                toolButton(.relaxBrush, label: "Smooth", symbol: "wind")
                toolButton(.moveBrush, label: "Move", symbol: "hand.point.up.left")
                toolButton(.erase, label: "Erase", symbol: "eraser")
            }
            .labelStyle(.iconOnly)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!model.state.canUndo)
                .accessibilityIdentifier("Undo")
            Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!model.state.canRedo)
                .accessibilityIdentifier("Redo")
            Button { model.engine.setSymmetryEnabled(!model.state.symmetry.isEnabled) } label: {
                Label("Mirror", systemImage: model.state.symmetry.isEnabled ? "square.and.line.vertical.and.square.filled" : "square.and.line.vertical.and.square")
                    .foregroundStyle(model.state.symmetry.isEnabled ? Theme.selection : Color.primary)
            }
            .tint(model.state.symmetry.isEnabled ? Theme.selection : Color.primary)
            .accessibilityIdentifier("Symmetry")
            .accessibilityValue(model.state.symmetry.isEnabled ? "On" : "Off")
            Button { withAnimation(.snappy) { model.showsGuide.toggle() } } label: {
                Label("Guide", systemImage: model.showsGuide ? "book.fill" : "book")
                    .foregroundStyle(model.showsGuide ? Theme.selection : Color.primary)
            }
            .accessibilityIdentifier("Guide Button")
            .accessibilityValue(model.showsGuide ? "Open" : "Closed")
            menu
        }
    }

    private func toolButton(_ tool: Tool, label: String, symbol: String) -> some View {
        let isActive = model.state.activeTool == tool
        return Button { model.select(tool: tool) } label: {
            Label(label, systemImage: symbol)
                .foregroundStyle(isActive ? Theme.selection : Color.primary)
                .frame(width: Theme.touchTarget, height: Theme.touchTarget)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("tool-\(tool.rawValue)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var menu: some View {
        Menu {
            Button("Add Model…", systemImage: "cube") {
                importsAsMesh = false
                importsModel = true
            }
            .accessibilityIdentifier("Import Model to Draw On")
            Button("Open Mesh…", systemImage: "square.and.pencil") {
                importsAsMesh = true
                importsModel = true
            }
            .accessibilityIdentifier("Import Mesh to Edit")
            Button("Sculpts…", systemImage: "square.stack.3d.up") { showsSculpts = true }
                .accessibilityIdentifier("Sculpts")
            Button("Blender Link…", systemImage: "link") { showsBlenderLink = true }
                .accessibilityIdentifier("Blender Link")
            Button(model.state.viewport.showSource ? "Hide Model" : "Show Model", systemImage: model.state.viewport.showSource ? "eye.slash" : "eye") {
                model.engine.viewport.showSource.toggle()
                model.settingChanged()
            }
            .accessibilityIdentifier("Toggle Model")
            Divider()
            Button("Poly Budget…", systemImage: "gauge.with.dots.needle.33percent") { showsBudget = true }
                .accessibilityIdentifier("Poly Budget")
            Button("Export…", systemImage: "square.and.arrow.up") { showsExport = true }
                .accessibilityIdentifier("Export")
            Divider()
            Button("Rename…", systemImage: "pencil") {
                draftName = model.state.name
                renames = true
            }
            .accessibilityIdentifier("Rename")
            Button("Settings…", systemImage: "gearshape") { model.showsSettings = true }
                .accessibilityIdentifier("Settings")
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .accessibilityIdentifier("More")
        .sheet(isPresented: $showsBlenderLink) { BlenderLinkView(model: model) }
        .sheet(isPresented: $showsSculpts) { SculptsSheet(model: model).presentationDetents([.medium]) }
        .sheet(isPresented: $showsExport) { ExportSheet(model: model, isPresented: $showsExport).presentationDetents([.medium]) }
        .sheet(isPresented: $showsBudget) {
            BudgetSheet(model: model)
                .presentationDetents([.medium])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .alert("Rename", isPresented: $renames) {
            TextField("Project name", text: $draftName)
            Button("Rename") {
                let name = draftName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    model.engine.name = name
                    ProjectLibrary.shared.rename(model.document, to: name)
                    model.settingChanged()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: Over the viewport

/// How much the brush covers. The pencil has no size: the zoom sets that.
private struct BrushSizeSlider: View {
    let model: EditorModel

    var body: some View {
        if model.state.activeTool != .pencil {
            Slider(value: Binding(get: { model.state.tools.brush.radiusPoints }, set: { model.engine.tools.brush.radiusPoints = $0 }), in: 10...120)
                .frame(width: 220)
                .rotationEffect(.degrees(-90))
                .frame(width: 44, height: 220)
                .padding(.vertical, 8)
                .panel(corner: 22)
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Brush size")
                .accessibilityIdentifier("Brush Size")
        }
    }
}

/// Which way the model is facing. Tapping an axis looks along it, level.
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

/// Which way the model mirrors, while it does.
private struct MirrorAxisPicker: View {
    let model: EditorModel

    var body: some View {
        if model.state.symmetry.isEnabled {
            HStack(spacing: 2) {
                Text("Mirror").font(.footnote).foregroundStyle(Theme.quiet).padding(.horizontal, 8)
                ForEach(MirrorAxis.allCases, id: \.self) { axis in
                    let isActive = model.state.symmetry.plane.axis == axis
                    Button { model.engine.setSymmetryPlane(axis: axis) } label: {
                        Text(axis.label)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(isActive ? Color.white : Color.primary)
                            .frame(width: 34, height: 34)
                            .background(isActive ? Theme.selection : Color.clear, in: Circle())
                            .frame(width: 40, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("mirror-axis-\(axis.label)")
                    .accessibilityAddTraits(isActive ? .isSelected : [])
                }
            }
            .padding(4)
            .panel(corner: 22)
        }
    }
}

/// Only there while something is picked, since a tap is the only way to pick anything.
private struct PickChips: View {
    let model: EditorModel

    var body: some View {
        let engine = model.state
        if engine.hasPick {
            HStack(spacing: 8) {
                if let note = engine.pickNote {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(Theme.quiet)
                        .padding(.leading, 10)
                        .accessibilityIdentifier("Pick Note")
                }
                if engine.canFillPick {
                    Button("Fill") { model.engine.fillPick() }
                        .pillButton()
                        .accessibilityIdentifier("Fill")
                }
                Button("Delete", role: .destructive) { model.engine.deletePick() }
                    .pillButton()
                    .accessibilityIdentifier("Delete")
            }
            .padding(6)
            .panel(corner: 26)
        }
    }
}

/// The live count, once there's a target to count against.
private struct BudgetChip: View {
    let model: EditorModel
    @State private var showsBudget = false

    var body: some View {
        let engine = model.state
        if let budget = engine.polyBudget {
            let count = engine.statistics.triangleEquivalent
            Button { showsBudget = true } label: {
                Text("\(count.formatted()) / \(budget.formatted()) tris")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(count > budget ? Color.red : Theme.quiet)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityIdentifier("budget-status")
            .sheet(isPresented: $showsBudget) {
                BudgetSheet(model: model)
                    .presentationDetents([.medium])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
        }
    }
}

/// What went wrong, and nothing else: a stroke that couldn't become anything just stays as a mark.
private struct MessageToast: View {
    let model: EditorModel

    var body: some View {
        if let message = model.state.message, message.kind == .error || message.kind == .warning {
            Button { model.engine.clearMessage() } label: {
                HStack(spacing: 8) {
                    Image(systemName: message.kind == .error ? "xmark.octagon" : "exclamationmark.triangle")
                        .foregroundStyle(message.kind == .error ? Color.red : Color.yellow)
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
                try? await Task.sleep(for: .seconds(9))
                if !Task.isCancelled, model.engine.message?.id == message.id { model.engine.clearMessage() }
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
