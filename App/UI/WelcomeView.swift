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
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Import Model…", systemImage: "square.and.arrow.down") { pick(.model) }
                    .accessibilityIdentifier("Import Model")
                Menu("Examples", systemImage: "cube") {
                    ForEach(ExampleModel.allCases) { example in
                        Button(example.title) { app.newProject(name: example.title, start: .example(example)) }
                            .accessibilityIdentifier("Open \(example.title)")
                    }
                }
                .accessibilityIdentifier("Examples")
                Button("Empty Project", systemImage: "doc") { app.newProject() }
                    .accessibilityIdentifier("New Project")
                Divider()
                Button("Open Project…", systemImage: "folder") { pick(.project) }
                    .accessibilityIdentifier("Open Project")
                Button("Open Mesh…", systemImage: "square.and.pencil") { pick(.mesh) }
                    .accessibilityIdentifier("Open Mesh")
                Divider()
                Button("Settings…", systemImage: "gearshape") { showsSettings = true }
                    .accessibilityIdentifier("Settings")
            } label: {
                Label("New", systemImage: "plus")
            }
            .accessibilityIdentifier("Add")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Button("Import Model") { pick(.model) }.pillButton(prominent: true)
            Button("Use the Example") { app.newProject(name: ExampleModel.bust.title, start: .example(.bust)) }.pillButton()
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

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Picker("One finger", selection: $settings.oneFingerAction) {
                    ForEach(OneFingerAction.allCases) { Text($0.label).tag($0) }
                }
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Steady lines") {
                    Slider(value: $settings.steadiness, in: 0...1)
                        .frame(maxWidth: 220)
                        .accessibilityLabel("Steady lines")
                        .accessibilityIdentifier("Steady Lines")
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
