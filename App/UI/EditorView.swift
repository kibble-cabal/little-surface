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
                    Spacer(minLength: 0)
                    MessageToast(model: model)
                    PickChips(model: model)
                    BudgetChip(model: model)
                }
                .padding(10)

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
            HStack(spacing: 18) {
                toolButton(.pencil, label: "Draw", symbol: "pencil.tip")
                toolButton(.relaxBrush, label: "Smooth", symbol: "wind")
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
            Menu {
                Picker("Axis", selection: Binding(get: { model.state.symmetry.plane.axis }, set: { model.engine.setSymmetryPlane(axis: $0) })) {
                    ForEach(MirrorAxis.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } label: {
                Label("Symmetry", systemImage: "square.and.line.vertical.and.square")
                    .foregroundStyle(model.state.symmetry.isEnabled ? Theme.selection : Color.primary)
            } primaryAction: {
                model.engine.setSymmetryEnabled(!model.state.symmetry.isEnabled)
            }
            .accessibilityIdentifier("Symmetry")
            .accessibilityValue(model.state.symmetry.isEnabled ? "On" : "Off")
            menu
        }
    }

    private func toolButton(_ tool: Tool, label: String, symbol: String) -> some View {
        let isActive = model.state.activeTool == tool
        return Button { model.select(tool: tool) } label: {
            Label(label, systemImage: symbol).foregroundStyle(isActive ? Theme.selection : Color.primary)
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

/// Only there while something is picked, since a tap is the only way to pick anything.
private struct PickChips: View {
    let model: EditorModel

    var body: some View {
        let engine = model.state
        if engine.hasPick {
            HStack(spacing: 8) {
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
