import LittleSurfaceCore
import SwiftUI
import UniformTypeIdentifiers

/// The models being drawn on. Updating one from a file brings the topology along.
struct SculptsSheet: View {
    let model: EditorModel
    @State private var pendingRemoval: SourceObject?
    // Dismissing the picker clears its binding before the result arrives, so the target is kept apart.
    @State private var sculptToUpdate: UUID?
    @State private var picksSculpt = false

    var body: some View {
        List(model.state.sources) { object in
            HStack {
                Text(object.name).lineLimit(1)
                Spacer()
                Button("Update…") {
                    sculptToUpdate = object.id
                    picksSculpt = true
                }
                .pillButton()
                .accessibilityIdentifier("update-\(object.name)")
                Button("Remove", role: .destructive) { pendingRemoval = object }
                    .pillButton()
                    .accessibilityIdentifier("remove-\(object.name)")
            }
        }
        .fileImporter(isPresented: $picksSculpt, allowedContentTypes: [.objModel, .glbModel, .gltfModel, .data]) { result in
            switch result {
            case .success(let url):
                if let sculptToUpdate { model.updateSculpt(id: sculptToUpdate, from: url) }
            case .failure(let error):
                model.engine.say(error.localizedDescription, kind: .error)
            }
            sculptToUpdate = nil
        }
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

struct ExportSheet: View {
    let model: EditorModel
    @Binding var isPresented: Bool
    @State private var format = ExportFormat.obj
    @State private var includesSource = false
    @State private var name = ""

    var body: some View {
        let stats = model.state.statistics
        Form {
            TextField("File name", text: $name).accessibilityIdentifier("Export Name")
            Picker("Format", selection: $format) {
                Text("OBJ").tag(ExportFormat.obj)
                Text("GLB").tag(ExportFormat.glb)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("Export Format")
            Toggle("Include the sculpt", isOn: $includesSource).accessibilityIdentifier("Include Source")
            Button("Export…") {
                var options = ExportOptions()
                options.includeSource = includesSource
                model.export(format: format, options: options, name: name.isEmpty ? model.engine.name : name)
                isPresented = false
            }
            .disabled(stats.faces == 0 && !includesSource)
            .accessibilityIdentifier("Export Confirm")
            Button("Make Timelapse…") {
                model.exportTimelapse()
                isPresented = false
            }
            .disabled(!model.engine.timelapse.hasFrames)
            .accessibilityIdentifier("Make Timelapse")
        }
        .onAppear { name = model.engine.name }
    }
}

/// A target to count against, and the way to what needs a look.
struct BudgetSheet: View {
    let model: EditorModel
    @State private var draft = ""
    @State private var positions: [TopologyCheck: (position: Int, count: Int)] = [:]

    private let presets = [1_000, 5_000, 10_000, 25_000]

    var body: some View {
        let engine = model.state
        let count = engine.statistics.triangleEquivalent
        Form {
            Section {
                if let budget = engine.polyBudget {
                    ProgressView(value: min(Double(count) / Double(budget), 1))
                        .tint(count > budget ? Color.red : Color.accentColor)
                }
                Text(engine.polyBudget.map { "\(count.formatted()) of \($0.formatted()) triangles" } ?? "\(count.formatted()) triangles")
                    .foregroundStyle(engine.polyBudget.map { count > $0 } == true ? Color.red : Theme.quiet)
                    .accessibilityIdentifier("budget-summary")
                HStack(spacing: 6) {
                    ForEach(presets, id: \.self) { preset in
                        Button("\(preset / 1000)k") { set(preset) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityIdentifier("budget-preset-\(preset)")
                    }
                    TextField("Other", text: $draft)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: draft) { _, text in
                            if let value = Int(text.filter(\.isNumber)), value > 0 { set(value, fromField: true) }
                        }
                        .accessibilityIdentifier("budget-field")
                    if engine.polyBudget != nil {
                        Button("Clear") {
                            draft = ""
                            engine.setPolyBudget(nil)
                            model.settingChanged()
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .accessibilityIdentifier("budget-clear")
                    }
                }
            }
            Section {
                ForEach(TopologyCheck.allCases) { check in
                    row(check, engine: engine)
                }
            }
        }
        .onAppear {
            if model.report == nil { model.runValidation() }
        }
    }

    private func set(_ value: Int, fromField: Bool = false) {
        if !fromField { draft = "" }
        model.engine.setPolyBudget(value)
        model.settingChanged()
    }

    @ViewBuilder private func row(_ check: TopologyCheck, engine: RetopoEngine) -> some View {
        let waiting = check == .badGeometry && model.report == nil
        let total = waiting ? 0 : engine.spots(of: check, report: model.report).count
        Button {
            positions[check] = engine.jump(to: check, report: model.report)
            model.cameraDidChange()
        } label: {
            HStack {
                Text(check.title).foregroundStyle(total == 0 ? Theme.quiet : Color.primary)
                Spacer()
                if waiting {
                    ProgressView().controlSize(.mini)
                } else if let at = positions[check], at.count == total {
                    Text("\(at.position) of \(total)").monospacedDigit().foregroundStyle(Theme.quiet)
                } else {
                    Text("\(total)").monospacedDigit().foregroundStyle(Theme.quiet)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(total == 0)
        .accessibilityIdentifier("jump-\(check.rawValue)")
    }
}
