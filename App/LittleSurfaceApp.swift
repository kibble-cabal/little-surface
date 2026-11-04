import LittleSurfaceCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct LittleSurfaceApp: App {
    @State private var app = AppModel()
    @State private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .tint(Color.accentColor)
                .preferredColorScheme(settings.appearance == .system ? nil : (settings.appearance == .dark ? .dark : .light))
                .onOpenURL { app.open(externalURL: $0) }
        }
    }
}

/// Which project is open, and how projects get opened and created.
@Observable
final class AppModel {
    private(set) var editor: EditorModel?
    var alert: String?
    private(set) var isOpening = false
    @ObservationIgnored private var scopedURL: URL?

    init() {
        ViewportRenderer.warmUp()
    }

    enum Start {
        case empty
        case model(URL)
        case example
    }

    func newProject(name: String = "Untitled", start: Start = .empty) {
        guard editor == nil, !isOpening else { return }
        isOpening = true
        let library = ProjectLibrary.shared
        let url = library.uniqueURL(named: name)
        let snapshot = ProjectSnapshot(name: url.deletingPathExtension().lastPathComponent)
        let document = ProjectDocument(fileURL: url)
        document.snapshotProvider = { snapshot }
        document.save(to: url, for: .forCreating) { [weak self] ok in
            guard let self else { return }
            self.isOpening = false
            guard ok else {
                self.alert = "A new project couldn't be created. \(document.lastSaveError?.localizedDescription ?? "")"
                return
            }
            let editor = EditorModel(document: document, snapshot: snapshot)
            self.editor = editor
            library.refresh()
            switch start {
            case .empty: break
            case .model(let modelURL): editor.importModel(from: modelURL)
            case .example: editor.importExample()
            }
            if !AppSettings.shared.hasSeenTutorial {
                editor.startTutorial()
                if case .empty = start {} else { editor.tutorialStep = .importModel }
            }
        }
    }

    func open(_ url: URL) {
        guard editor == nil, !isOpening else { return }
        isOpening = true
        let scoped = url.startAccessingSecurityScopedResource()
        let document = ProjectDocument(fileURL: url)
        document.open { [weak self] ok in
            guard let self else { return }
            self.isOpening = false
            guard ok, let snapshot = document.loaded else {
                if scoped { url.stopAccessingSecurityScopedResource() }
                let reason = document.lastSaveError?.localizedDescription ?? "The file may be damaged, or saved by a newer version."
                self.alert = "\(url.lastPathComponent) couldn't be opened. \(reason)"
                return
            }
            if scoped { self.scopedURL = url }
            ProjectLibrary.shared.rememberExternal(url)
            self.editor = EditorModel(document: document, snapshot: snapshot)
        }
    }

    /// Files handed over from the Files app, the share sheet or another app.
    func open(externalURL url: URL) {
        switch url.pathExtension.lowercased() {
        case "littlesurface":
            closeThen { self.open(url) }
        case "obj", "glb", "gltf":
            if let editor {
                editor.importModel(from: url)
            } else {
                newProject(name: url.deletingPathExtension().lastPathComponent, start: .model(url))
            }
        default:
            alert = ImportError.unsupportedFormat(url.pathExtension).localizedDescription
        }
    }

    private func closeThen(_ action: @escaping () -> Void) {
        if editor != nil {
            closeEditor(then: action)
        } else {
            action()
        }
    }

    func closeEditor(then action: (() -> Void)? = nil) {
        guard let editor else { return }
        editor.close { [weak self] in
            guard let self else { return }
            self.editor = nil
            self.scopedURL?.stopAccessingSecurityScopedResource()
            self.scopedURL = nil
            ProjectLibrary.shared.refresh()
            action?()
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            if let editor = app.editor {
                EditorView(model: editor)
                    .id(ObjectIdentifier(editor))
            } else {
                WelcomeView()
            }
        }
        .alert("Couldn't do that", isPresented: Binding(get: { app.alert != nil }, set: { if !$0 { app.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.alert ?? "")
        }
    }
}
