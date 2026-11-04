import LittleSurfaceCore
import SwiftUI

/// The collapsible panel on the right. It only ever shows what the active tool can use.
struct ContextPanel: View {
    let model: EditorModel
    @Binding var collapsed: Bool

    var body: some View {
        let engine = model.state
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if !collapsed {
                    Text(engine.activeTool.label).font(.subheadline.weight(.semibold)).padding(.leading, 6)
                    Spacer()
                }
                IconButton(symbol: collapsed ? "sidebar.left" : "sidebar.right", label: collapsed ? "Show Options" : "Hide Options", identifier: "Toggle Options") {
                    collapsed.toggle()
                }
            }
            if !collapsed {
                let content = VStack(alignment: .leading, spacing: 12) {
                    toolControls(engine)
                    Divider()
                    SurfaceControls(model: model)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
                // Only as tall as it needs to be, so it leaves the model visible.
                ViewThatFits(in: .vertical) {
                    content
                    ScrollView(.vertical, showsIndicators: false) { content }
                }
            }
        }
        .padding(4)
        .frame(width: collapsed ? nil : 268)
        .panel()
    }

    @ViewBuilder
    private func toolControls(_ engine: RetopoEngine) -> some View {
        switch engine.activeTool {
        case .select: SelectionControls(model: model)
        case .drawEdges, .edgeLoop: StrokeControls(model: model)
        case .quadStrip: StripControls(model: model)
        case .quadPatch: PatchControls(model: model)
        case .face: FaceControls(model: model)
        case .moveBrush, .relaxBrush, .erase: BrushControls(model: model)
        }
    }
}

/// A scale for sliders measured in scene units, which vary hugely between models.
private func sceneScale(_ engine: RetopoEngine) -> Float {
    let diagonal = engine.sceneBounds.diagonal
    return diagonal > 0 ? diagonal : 1
}

private struct SurfaceControls: View {
    let model: EditorModel

    var body: some View {
        let engine = model.state
        let scale = sceneScale(engine)
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Snap to surface", isOn: Binding(
                get: { model.state.tools.surfaceSnapping },
                set: { model.engine.tools.surfaceSnapping = $0; model.settingChanged() }
            ))
            .font(.footnote)
            .accessibilityIdentifier("Snap to Surface")
            ValueSlider(
                title: "Surface offset",
                value: Binding(get: { model.state.tools.surfaceOffset }, set: { model.engine.setSurfaceOffset($0) }),
                range: 0...(scale * 0.02),
                format: lengthText
            )
            Button("Reproject Selection") { model.engine.reproject() }
                .buttonStyle(PillButtonStyle())
                .accessibilityIdentifier("Reproject")
        }
    }
}

private struct StrokeControls: View {
    let model: EditorModel

    var body: some View {
        let scale = sceneScale(model.state)
        VStack(alignment: .leading, spacing: 10) {
            ValueSlider(
                title: "Edge length",
                value: Binding(get: { model.state.tools.stroke.edgeLength }, set: { model.engine.tools.stroke.edgeLength = $0; model.settingChanged() }),
                range: (scale * 0.002)...(scale * 0.15),
                format: lengthText
            )
            ValueSlider(
                title: "Smoothing",
                value: Binding(get: { model.state.tools.stroke.smoothing }, set: { model.engine.tools.stroke.smoothing = $0; model.settingChanged() }),
                range: 0...1
            )
            ValueSlider(
                title: "Snap distance",
                value: Binding(get: { model.state.tools.stroke.snapRadiusPoints }, set: { model.engine.tools.stroke.snapRadiusPoints = $0; model.settingChanged() }),
                range: 4...60,
                format: { "\(Int($0)) pt" }
            )
            ValueSlider(
                title: "Close distance",
                value: Binding(get: { model.state.tools.stroke.closeRadiusPoints }, set: { model.engine.tools.stroke.closeRadiusPoints = $0; model.settingChanged() }),
                range: 8...120,
                format: { "\(Int($0)) pt" }
            )
        }
    }
}

private struct StripControls: View {
    let model: EditorModel

    private func change(_ body: (inout QuadStripParameters) -> Void) {
        body(&model.engine.tools.strip)
        model.engine.rebuildStripPlan()
        model.settingChanged()
    }

    var body: some View {
        let strip = model.state.tools.strip
        let scale = sceneScale(model.state)
        VStack(alignment: .leading, spacing: 10) {
            ValueSlider(title: "Width", value: Binding(get: { strip.width }, set: { v in change { $0.width = v } }), range: (scale * 0.002)...(scale * 0.3), format: lengthText)
            IntStepper(title: "Segments", value: Binding(get: { strip.segments }, set: { v in change { $0.segments = v } }), range: 0...400, zeroLabel: "From spacing")
            if strip.segments == 0 {
                ValueSlider(title: "Vertex spacing", value: Binding(get: { strip.vertexSpacing }, set: { v in change { $0.vertexSpacing = v } }), range: (scale * 0.002)...(scale * 0.15), format: lengthText)
            }
            IntStepper(title: "Quads across", value: Binding(get: { strip.crossSegments }, set: { v in change { $0.crossSegments = v } }), range: 1...12)
            VStack(alignment: .leading, spacing: 4) {
                Text("Direction").font(.footnote)
                Picker("Direction", selection: Binding(get: { strip.direction }, set: { v in change { $0.direction = v } })) {
                    Text("Left").tag(StripDirection.left)
                    Text("Center").tag(StripDirection.centered)
                    Text("Right").tag(StripDirection.right)
                }
                .pickerStyle(.segmented)
            }
        }
    }
}

private struct PatchControls: View {
    let model: EditorModel

    private func change(_ body: (inout QuadPatchParameters) -> Void) {
        body(&model.engine.tools.patch)
        model.engine.updatePatchPreview()
        model.settingChanged()
    }

    var body: some View {
        let engine = model.state
        let patch = engine.tools.patch
        VStack(alignment: .leading, spacing: 10) {
            Text(engine.patchChains.isEmpty ? "Tap two lines, four sides, or one closed loop." : "\(engine.patchChains.count) picked")
                .font(.footnote).foregroundStyle(Theme.quiet)
            Button("Use Selected Edges") { engine.addPatchChainFromSelection() }
                .buttonStyle(PillButtonStyle())
            IntStepper(title: "Rows", value: Binding(get: { patch.rows }, set: { v in change { $0.rows = v } }), range: 0...100, zeroLabel: "Auto")
            IntStepper(title: "Column density", value: Binding(get: { patch.columnDensity }, set: { v in change { $0.columnDensity = v } }), range: 1...8)
            IntStepper(title: "Row density", value: Binding(get: { patch.rowDensity }, set: { v in change { $0.rowDensity = v } }), range: 1...8)
            IntStepper(title: "Relax passes", value: Binding(get: { patch.relaxIterations }, set: { v in change { $0.relaxIterations = v } }), range: 0...30)
            Toggle("Match vertex counts", isOn: Binding(get: { patch.matchVertexCounts }, set: { v in change { $0.matchVertexCounts = v } })).font(.footnote)
            Toggle("Swap line ends", isOn: Binding(get: { patch.flipPairing }, set: { v in change { $0.flipPairing = v } })).font(.footnote)
        }
    }
}

private struct FaceControls: View {
    let model: EditorModel
    var body: some View {
        Text("Tap vertices or edges with the Pencil. Four corners complete a quad right away. To make a triangle or an n-gon, tap Create Face.")
            .font(.footnote).foregroundStyle(Theme.quiet)
    }
}

private struct BrushControls: View {
    let model: EditorModel
    var body: some View {
        let brush = model.state.tools.brush
        VStack(alignment: .leading, spacing: 10) {
            ValueSlider(title: "Radius", value: Binding(get: { brush.radiusPoints }, set: { model.engine.tools.brush.radiusPoints = $0; model.settingChanged() }), range: 8...240, format: { "\(Int($0)) pt" })
            if model.state.activeTool != .erase {
                ValueSlider(title: "Strength", value: Binding(get: { brush.strength }, set: { model.engine.tools.brush.strength = $0; model.settingChanged() }), range: 0.05...1)
                Toggle("Pressure sets strength", isOn: Binding(get: { brush.usesPressure }, set: { model.engine.tools.brush.usesPressure = $0; model.settingChanged() })).font(.footnote)
            } else {
                Picker("Erases", selection: Binding(get: { model.state.selection.mode }, set: { model.engine.setSelectionMode($0) })) {
                    Text("Vertices").tag(SelectionMode.vertex)
                    Text("Edges").tag(SelectionMode.edge)
                    Text("Faces").tag(SelectionMode.face)
                }
                .pickerStyle(.segmented)
            }
        }
    }
}

private struct SelectionControls: View {
    let model: EditorModel

    private let grid = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    private func action(_ title: String, _ symbol: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.footnote)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .padding(.horizontal, 8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(title)
    }

    var body: some View {
        let engine = model.state
        VStack(alignment: .leading, spacing: 10) {
            Picker("Select", selection: Binding(get: { engine.selection.mode }, set: { model.engine.setSelectionMode($0); model.settingChanged() })) {
                Text("Vertex").tag(SelectionMode.vertex)
                Text("Edge").tag(SelectionMode.edge)
                Text("Face").tag(SelectionMode.face)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("Selection Mode")
            Picker("Taps", selection: Binding(get: { engine.selectionOperation }, set: { model.engine.selectionOperation = $0; model.settingChanged() })) {
                Text("Replace").tag(SelectionOperation.replace)
                Text("Add").tag(SelectionOperation.add)
                Text("Remove").tag(SelectionOperation.remove)
            }
            .pickerStyle(.segmented)
            Picker("Dragging", selection: Binding(get: { engine.dragBehavior }, set: { model.engine.dragBehavior = $0; model.settingChanged() })) {
                Text("Free Move").tag(DragBehavior.move)
                Text("Slide on Edges").tag(DragBehavior.slide)
            }
            .pickerStyle(.segmented)

            sectionTitle("Select")
            LazyVGrid(columns: grid, spacing: 6) {
                action("All", "checkmark.square") { engine.selectAll() }
                action("None", "square") { engine.clearSelection() }
                action("Loop", "circle.dashed") { engine.selectEdgeLoop() }
                action("Ring", "circle.grid.cross") { engine.selectEdgeRing() }
                action("Connected", "point.3.connected.trianglepath.dotted") { engine.selectConnected() }
                action("Boundary", "square.dashed") { engine.selectBoundary() }
            }

            sectionTitle("Change Topology")
            LazyVGrid(columns: grid, spacing: 6) {
                action("Delete", "trash") { engine.deleteSelection() }
                action("Dissolve", "drop") { engine.dissolveSelection() }
                action("Split", "scissors") { engine.splitSelectedEdges() }
                action("Connect", "point.topleft.down.to.point.bottomright.curvepath") { engine.connectSelectedVertices() }
                action("Extrude", "arrow.up.square") { engine.extrudeSelectedEdges() }
                action("Fill", "square.fill") { engine.fillHoles() }
                action("Make Face", "skew") { engine.makeFaceFromSelection() }
                action("Weld", "arrow.right.and.line.vertical.and.arrow.left") { engine.weldSelected() }
                action("Flip", "arrow.triangle.2.circlepath") { engine.flipSelectedEdges() }
                action("Subdivide", "square.grid.2x2") { engine.subdivideSelection() }
            }

            sectionTitle("Shape")
            LazyVGrid(columns: grid, spacing: 6) {
                action("Relax", "wind") { engine.relaxSelection() }
                action("Reverse", "arrow.left.arrow.right") { engine.reverseNormals() }
                action("Fix Normals", "arrow.up.to.line") { engine.recalculateNormals() }
                action("Frame", "viewfinder") {
                    engine.frameSelection()
                    model.cameraDidChange()
                }
            }
            ValueSlider(
                title: "Extrude distance",
                value: Binding(get: { engine.tools.extrudeDistance }, set: { model.engine.tools.extrudeDistance = $0; model.settingChanged() }),
                range: (sceneScale(engine) * 0.001)...(sceneScale(engine) * 0.2),
                format: lengthText
            )
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(Theme.quiet).padding(.top, 2)
    }
}

// MARK: Popovers

struct SymmetryPopover: View {
    let model: EditorModel

    var body: some View {
        let engine = model.state
        let box = engine.sourceBounds
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Symmetry", isOn: Binding(get: { model.state.symmetry.isEnabled }, set: { model.engine.setSymmetryEnabled($0) }))
                .font(.headline)
                .accessibilityIdentifier("Symmetry Toggle")
            Picker("Axis", selection: Binding(get: { engine.symmetry.plane.axis }, set: { model.engine.setSymmetryPlane(axis: $0) })) {
                ForEach(MirrorAxis.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            let axis = engine.symmetry.plane.axis.rawValue
            let low = box.isEmpty ? -1 : box.minCorner[axis], high = box.isEmpty ? 1 : box.maxCorner[axis]
            ValueSlider(
                title: "Plane position",
                value: Binding(get: { model.state.symmetry.plane.offset }, set: { model.engine.setSymmetryPlane(offset: $0) }),
                range: min(low, high - 1e-3)...high,
                format: lengthText
            )
            ValueSlider(
                title: "Centerline snap",
                value: Binding(get: { model.state.symmetry.centerTolerance }, set: { model.engine.setCenterTolerance($0) }),
                range: 0...(max(box.diagonal, 1e-3) * 0.03),
                format: lengthText
            )
            HStack {
                Button("Merge Centerline") { model.engine.mergeCenterline() }.buttonStyle(PillButtonStyle())
                Button("Apply") { model.engine.applySymmetry() }.buttonStyle(PillButtonStyle()).help("Mirror the kept side into plain geometry")
            }
            Text("Apply replaces one side with a mirror of the other, then welds the center. It can be undone.")
                .font(.caption).foregroundStyle(Theme.quiet)
        }
        .padding()
        .frame(width: 300)
    }
}

struct DisplayPopover: View {
    let model: EditorModel

    private func viewport<T>(_ path: WritableKeyPath<ViewportSettings, T>, then: (() -> Void)? = nil) -> Binding<T> {
        Binding(get: { model.state.viewport[keyPath: path] }, set: {
            model.engine.viewport[keyPath: path] = $0
            model.settingChanged()
            then?()
        })
    }

    var body: some View {
        let engine = model.state
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Display", selection: viewport(\.displayMode)) {
                    ForEach(DisplayMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("Display Mode")
                Picker("Camera", selection: Binding(get: { engine.camera.projection }, set: { model.engine.setProjection($0); model.cameraDidChange() })) {
                    Text("Perspective").tag(ProjectionMode.perspective)
                    Text("Orthographic").tag(ProjectionMode.orthographic)
                }
                .pickerStyle(.segmented)
                HStack {
                    Button("Frame Model") { model.engine.frameAll(); model.cameraDidChange() }.buttonStyle(PillButtonStyle()).accessibilityIdentifier("Frame Model")
                    Button("Frame Selection") { model.engine.frameSelection(); model.cameraDidChange() }.buttonStyle(PillButtonStyle()).accessibilityIdentifier("Frame Selection")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 6) {
                    ForEach(ViewPreset.allCases, id: \.self) { preset in
                        Button(preset.rawValue.capitalized) {
                            model.engine.camera.setPreset(preset)
                            model.engine.cameraChanged()
                            model.cameraDidChange()
                        }
                        .buttonStyle(PillButtonStyle())
                    }
                }
                Divider()
                Toggle("Show source model", isOn: viewport(\.showSource)).accessibilityIdentifier("Show Source")
                Toggle("Show topology", isOn: viewport(\.showRetopology)).accessibilityIdentifier("Show Topology")
                ValueSlider(title: "Source opacity", value: viewport(\.sourceOpacity), range: 0.05...1)
                ValueSlider(title: "Face opacity", value: viewport(\.faceOpacity), range: 0...1)
                Divider()
                ValueSlider(title: "Light strength", value: viewport(\.lightIntensity), range: 0.2...1.6)
                ValueSlider(title: "Light direction", value: viewport(\.lightAzimuth), range: -1.5...1.5)
                ValueSlider(title: "Light height", value: viewport(\.lightElevation), range: -0.5...1.4)
                ValueSlider(
                    title: "Background",
                    value: Binding(get: { model.state.viewport.backgroundLevel ?? 0.93 }, set: { model.engine.viewport.backgroundLevel = $0; model.settingChanged() }),
                    range: 0.05...1
                )
                Divider()
                Toggle("Subdivision preview", isOn: viewport(\.subdivisionPreview) { model.refreshSubdivisionPreview() })
                    .accessibilityIdentifier("Subdivision Preview")
                if engine.viewport.subdivisionPreview {
                    IntStepper(title: "Levels", value: viewport(\.subdivisionLevels) { model.refreshSubdivisionPreview() }, range: 1...4)
                    Picker("Show", selection: viewport(\.subdivisionDisplay) { model.refreshSubdivisionPreview() }) {
                        ForEach(SubdivisionDisplay.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if let note = model.subdivisionNote {
                        Text(note).font(.caption).foregroundStyle(Theme.quiet).accessibilityIdentifier("subdivision-note")
                    }
                }
                Button("Subdivide Real Geometry") { model.engine.applySubdivision() }.buttonStyle(PillButtonStyle())
                Text("The preview never changes the mesh. This button does, and can be undone.")
                    .font(.caption).foregroundStyle(Theme.quiet)
            }
            .padding()
        }
        .frame(width: 330, height: 560)
    }
}

struct ObjectsPopover: View {
    let model: EditorModel
    @State private var pendingRemoval: SourceObject?

    var body: some View {
        let engine = model.state
        VStack(alignment: .leading, spacing: 8) {
            Text("Source Objects").font(.headline)
            if engine.sources.isEmpty {
                Text("No source models yet. Import one to draw on it.").font(.footnote).foregroundStyle(Theme.quiet)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(engine.sources) { object in
                        HStack(spacing: 2) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(object.name).font(.footnote).lineLimit(1)
                                Text("\(object.triangleCount.formatted()) triangles").font(.caption2).foregroundStyle(Theme.quiet)
                            }
                            Spacer()
                            IconButton(symbol: object.isVisible ? "eye" : "eye.slash", label: "Show \(object.name)", isActive: false) {
                                model.engine.setSourceVisible(id: object.id, !object.isVisible)
                                model.settingChanged()
                            }
                            IconButton(symbol: object.isSnapTarget ? "scope" : "circle.slash", label: "Draw on \(object.name)", isActive: false) {
                                model.engine.setSourceSnapTarget(id: object.id, !object.isSnapTarget)
                                model.settingChanged()
                            }
                            IconButton(symbol: "minus.circle", label: "Remove \(object.name)") { pendingRemoval = object }
                        }
                    }
                }
            }
            .frame(maxHeight: 380)
        }
        .padding()
        .frame(width: 340)
        .confirmationDialog("Remove \(pendingRemoval?.name ?? "") from this project?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let pendingRemoval { model.engine.removeSource(id: pendingRemoval.id) }
                pendingRemoval = nil
            }
        } message: {
            Text("This can't be undone. Your topology stays.")
        }
    }
}

struct ExportPopover: View {
    let model: EditorModel
    @Binding var isPresented: Bool
    @State private var format = ExportFormat.obj
    @State private var includesSource = false
    @State private var name = ""

    var body: some View {
        let stats = model.state.statistics
        VStack(alignment: .leading, spacing: 12) {
            Text("Export").font(.headline)
            TextField("File name", text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier("Export Name")
            Picker("Format", selection: $format) {
                Text("OBJ").tag(ExportFormat.obj)
                Text("GLB").tag(ExportFormat.glb)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("Export Format")
            Text(format == .obj ? "Keeps quads as quads. Loose edges are written too. This is the best choice for Blender." : "Faces are triangulated, as glTF requires. Loose edges aren't included.")
                .font(.footnote).foregroundStyle(Theme.quiet)
            Toggle("Include source as a separate object", isOn: $includesSource).font(.footnote).accessibilityIdentifier("Include Source")
            Text("\(stats.vertices) vertices, \(stats.faces) faces").font(.footnote).foregroundStyle(Theme.quiet)
            Button("Export…") {
                var options = ExportOptions()
                options.includeSource = includesSource
                model.export(format: format, options: options, name: name.isEmpty ? model.engine.name : name)
                isPresented = false
            }
            .buttonStyle(PillButtonStyle(prominent: true))
            .disabled(stats.faces == 0 && stats.edges == 0 && !includesSource)
            .accessibilityIdentifier("Export Confirm")
        }
        .padding()
        .frame(width: 320)
        .onAppear { name = model.engine.name }
    }
}

struct ValidationView: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let report = model.report {
                    Section("Counts") {
                        let s = report.statistics
                        LabeledContent("Vertices", value: "\(s.vertices)")
                        LabeledContent("Edges", value: "\(s.edges)")
                        LabeledContent("Faces", value: "\(s.faces)")
                        LabeledContent("Quads", value: "\(s.quads)")
                        LabeledContent("Triangles", value: "\(s.triangles)")
                        LabeledContent("N-gons", value: "\(s.ngons)")
                        LabeledContent("Connected parts", value: "\(s.components)")
                    }
                    Section {
                        if report.issues.isEmpty {
                            Text("Nothing to report.").foregroundStyle(Theme.quiet)
                        }
                        ForEach(report.issues) { issue in
                            Button {
                                model.engine.selectIssue(issue)
                                dismiss()
                            } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    Image(systemName: issue.kind.isError ? "exclamationmark.triangle" : "info.circle")
                                        .foregroundStyle(issue.kind.isError ? .orange : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(issue.kind.title)
                                        Text(issue.kind.explanation).font(.caption).foregroundStyle(Theme.quiet)
                                    }
                                    Spacer()
                                    Text("\(issue.count)").monospacedDigit().foregroundStyle(Theme.quiet)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("issue-\(issue.kind.rawValue)")
                        }
                        if report.selfIntersectionCheckWasPartial {
                            Text("The self-intersection check stopped early on this large mesh, so it may be incomplete.").font(.caption).foregroundStyle(Theme.quiet)
                        }
                    } header: {
                        Text("Findings")
                    } footer: {
                        Text("Tap a finding to select it. These checks cover structure only. Whether a mesh deforms well depends on its edge flow, which is your call.")
                    }
                } else if model.isValidating {
                    HStack { ProgressView(); Text("Checking…") }
                } else {
                    Text("Tap Check to look for structural problems.").foregroundStyle(Theme.quiet)
                }
            }
            .navigationTitle("Check Mesh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Check") { model.runValidation() }.accessibilityIdentifier("Run Check") }
            }
            .onAppear { if model.report == nil { model.runValidation() } }
        }
    }
}
