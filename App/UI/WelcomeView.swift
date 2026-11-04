import LittleSurfaceCore
import SwiftUI
import UniformTypeIdentifiers

struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @State private var library = ProjectLibrary.shared
    @State private var importsModel = false
    @State private var opensProject = false
    @State private var showsSettings = false
    @State private var pendingDelete: ProjectItem?
    @Environment(\.scenePhase) private var scenePhase

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 18)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
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
                    .padding(.horizontal, 36)
                    .padding(.vertical, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.page.ignoresSafeArea())
        .onAppear { library.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.refresh() }
        }
        .fileImporter(isPresented: $importsModel, allowedContentTypes: [.objModel, .glbModel, .gltfModel, .data]) { result in
            if case .success(let url) = result {
                app.newProject(name: url.deletingPathExtension().lastPathComponent, start: .model(url))
            }
        }
        .fileImporter(isPresented: $opensProject, allowedContentTypes: [.littleSurfaceProject]) { result in
            if case .success(let url) = result { app.open(url) }
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

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Little Surface").font(.system(size: 30, weight: .semibold, design: .default)).lineLimit(1).fixedSize()
                Text("Retopology for iPad").font(.subheadline).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            Spacer()
            Button { app.newProject() } label: { Label("New", systemImage: "plus") }
                .buttonStyle(PillButtonStyle()).accessibilityIdentifier("New Project")
            Button { importsModel = true } label: { Label("Import Model", systemImage: "square.and.arrow.down") }
                .buttonStyle(PillButtonStyle(prominent: true)).accessibilityIdentifier("Import Model")
            Button { app.newProject(name: "Example", start: .example) } label: { Label("Example", systemImage: "cube") }
                .buttonStyle(PillButtonStyle()).accessibilityIdentifier("Open Example")
            Button { opensProject = true } label: { Label("Open", systemImage: "folder") }
                .buttonStyle(PillButtonStyle()).accessibilityIdentifier("Open Project")
            IconButton(symbol: "gearshape", label: "Settings") { showsSettings = true }
        }
        .padding(.horizontal, 36)
        .padding(.top, 28)
        .padding(.bottom, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "square.grid.3x3").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text("No projects yet").font(.title3)
            Text("Import an OBJ or GLB model to start drawing topology on it, or try the example.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
            Spacer()
        }
        .frame(maxWidth: .infinity)
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
                        Rectangle().fill(Color.primary.opacity(0.05))
                            .overlay(Image(systemName: "cube.transparent").font(.title).foregroundStyle(.secondary))
                    }
                }
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.callout.weight(.medium)).lineLimit(1)
                    HStack(spacing: 4) {
                        if item.isExternal { Image(systemName: "icloud").font(.caption2) }
                        Text(item.modified, format: .relative(presentation: .named)).font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
            .padding(8)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
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
