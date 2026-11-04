import LittleSurfaceCore
import SwiftUI
import UniformTypeIdentifiers

struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @State private var library = ProjectLibrary.shared
    @State private var filePick = FilePick.model
    @State private var picksFile = false
    @State private var showsSettings = false
    @State private var pendingDelete: ProjectItem?
    @Environment(\.scenePhase) private var scenePhase

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 18)]

    var body: some View {
        NavigationStack {
            Group {
                if library.items.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                            ForEach(library.items) { item in
                                ProjectCard(item: item, stamp: library.thumbnailStamp) {
                                    app.open(item.url)
                                } onDuplicate: {
                                    library.duplicate(item)
                                } onDelete: {
                                    pendingDelete = item
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.page.ignoresSafeArea())
            .navigationTitle("Little Surface")
            .toolbar { toolbarButtons }
        }
        .onAppear { library.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.refresh() }
        }
        // One importer for both jobs: SwiftUI only honors the last of several on the same view.
        .fileImporter(isPresented: $picksFile, allowedContentTypes: filePick.types) { result in
            switch result {
            case .success(let url):
                switch filePick {
                case .model: app.newProject(name: url.deletingPathExtension().lastPathComponent, start: .model(url))
                case .mesh: app.newProject(name: url.deletingPathExtension().lastPathComponent, start: .mesh(url))
                case .project: app.open(url)
                }
            case .failure(let error):
                app.alert = error.localizedDescription
            }
        }
        .sheet(isPresented: $showsSettings) { SettingsView() }
        .confirmationDialog(
            pendingDelete?.isExternal == true ? "Remove \(pendingDelete?.name ?? "") from this list?" : "Delete \(pendingDelete?.name ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(pendingDelete?.isExternal == true ? "Remove from List" : "Delete Project", role: .destructive) {
                if let pendingDelete { library.delete(pendingDelete) }
                pendingDelete = nil
            }
        } message: {
            Text(pendingDelete?.isExternal == true ? "The file itself stays where it is." : "This can't be undone.")
        }
    }

    private func pick(_ kind: FilePick) {
        filePick = kind
        picksFile = true
    }

    @ToolbarContentBuilder
    private var toolbarButtons: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { app.newProject() } label: { Label("New", systemImage: "plus") }
                .accessibilityIdentifier("New Project")
            Button { app.newProject(name: "Example", start: .example) } label: { Label("Example", systemImage: "cube") }
                .accessibilityIdentifier("Open Example")
            Button { pick(.project) } label: { Label("Open", systemImage: "folder") }
                .accessibilityIdentifier("Open Project")
            Button { pick(.mesh) } label: { Label("Open Mesh to Edit", systemImage: "square.and.pencil") }
                .accessibilityIdentifier("Open Mesh")
            Button { showsSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                .accessibilityIdentifier("Settings")
        }
        ToolbarItem(placement: .topBarTrailing) {
            let button = Button { pick(.model) } label: { Label("Import Model", systemImage: "square.and.arrow.down") }
                .accessibilityIdentifier("Import Model")
            if #available(iOS 26, *) {
                button.buttonStyle(.glassProminent)
            } else {
                button.buttonStyle(.borderedProminent)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Projects Yet", systemImage: "square.grid.3x3")
        } description: {
            Text("Import an OBJ or GLB model to start drawing topology on it, or try the example.")
        }
    }
}

private enum FilePick {
    case model, mesh, project

    var types: [UTType] {
        switch self {
        case .model, .mesh: return [.objModel, .glbModel, .gltfModel, .data]
        case .project: return [.littleSurfaceProject]
        }
    }
}

private struct ProjectCard: View {
    let item: ProjectItem
    let stamp: Int
    let onOpen: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if let image = ProjectLibrary.shared.thumbnail(for: item.url) {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Color(uiColor: .tertiarySystemGroupedBackground))
                            .overlay(Image(systemName: "cube.transparent").font(.title).foregroundStyle(Theme.quiet))
                    }
                }
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.headline).lineLimit(1)
                    HStack(spacing: 4) {
                        if item.isExternal { Image(systemName: "icloud").font(.caption2) }
                        Text(item.modified, format: .relative(presentation: .named)).font(.caption)
                    }
                    .foregroundStyle(Theme.quiet)
                }
                .padding(.horizontal, 4)
            }
            .padding(8)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect()
        .accessibilityLabel("Open \(item.name)")
        .accessibilityIdentifier("project-\(item.name)")
        .contextMenu {
            Button("Duplicate", systemImage: "plus.square.on.square", action: onDuplicate)
            Button(item.isExternal ? "Remove from List" : "Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}

struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    var onReplayTutorial: (() -> Void)?

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    Picker("One finger", selection: $settings.oneFingerAction) {
                        ForEach(OneFingerAction.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Two-finger tap undoes", isOn: $settings.twoFingerTapUndoes)
                    Toggle("Orbit keeps moving after a flick", isOn: $settings.orbitInertia)
                    Picker("Pencil double-tap", selection: $settings.pencilDoubleTap) {
                        ForEach(PencilDoubleTapAction.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Gestures")
                } footer: {
                    Text("Apple Pencil always uses the active tool. Two fingers always pan and pinch. Pencil double-tap needs a second-generation Apple Pencil or newer. With no Pencil, set One finger to Draw.")
                }
                Section {
                    Toggle("Close loops when the ends meet", isOn: $settings.closesLoopsAutomatically)
                    Toggle("Offer to fill between lines", isOn: $settings.suggestsFills)
                    Toggle("Switch to Select after Create Patch", isOn: $settings.selectsAfterPatch)
                    Toggle("Pencil haptics", isOn: $settings.pencilHaptics)
                } header: {
                    Text("Drawing")
                } footer: {
                    Text("A stroke whose ends land near each other becomes a loop, or a ring with Quad Strip, and Keep Open undoes that in one tap. A line or loop drawn beside another, or beside a finished patch, offers to fill the space with quads. Haptics need an Apple Pencil Pro.")
                }
                Section("Interface") {
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Status bar", isOn: $settings.showsStatusBar)
                }
                if let onReplayTutorial {
                    Section {
                        Button("Show the walkthrough again") {
                            dismiss()
                            onReplayTutorial()
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
