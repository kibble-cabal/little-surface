import CryptoKit
import LittleSurfaceCore
import Observation
import UIKit

struct ProjectItem: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let name: String
    let modified: Date
    /// Lives somewhere the artist chose, reached through a bookmark, rather than in the app's folder.
    let isExternal: Bool
    let bookmark: Data?
}

/// What the welcome screen lists: everything in the app's folder, which also shows up in the Files app,
/// plus projects opened from elsewhere.
@Observable
final class ProjectLibrary {
    static let shared = ProjectLibrary()

    private(set) var items: [ProjectItem] = []
    private(set) var thumbnailStamp = 0

    private let files = FileManager.default
    private var bookmarks: [Data] {
        get { UserDefaults.standard.array(forKey: "recentBookmarks") as? [Data] ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "recentBookmarks") }
    }

    var projectsFolder: URL { files.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    private var thumbnailsFolder: URL {
        let folder = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Thumbnails", isDirectory: true)
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private init() {
        refresh()
    }

    func refresh() {
        var found: [ProjectItem] = []
        let contents = (try? files.contentsOfDirectory(at: projectsFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in contents where url.pathExtension == "littlesurface" {
            found.append(ProjectItem(url: url, name: url.deletingPathExtension().lastPathComponent, modified: Self.modified(url), isExternal: false, bookmark: nil))
        }
        var liveBookmarks: [Data] = []
        for data in bookmarks {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale), !found.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { continue }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard files.fileExists(atPath: url.path) else { continue }
            liveBookmarks.append(data)
            found.append(ProjectItem(url: url, name: url.deletingPathExtension().lastPathComponent, modified: Self.modified(url), isExternal: true, bookmark: data))
        }
        bookmarks = liveBookmarks
        items = found.sorted { $0.modified > $1.modified }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // MARK: Names

    static func safeFileName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(80))
    }

    /// A file name in the app's folder that isn't taken: "Name", then "Name 2", and so on.
    func uniqueURL(named name: String) -> URL {
        let base = Self.safeFileName(name)
        var candidate = projectsFolder.appendingPathComponent(base).appendingPathExtension("littlesurface")
        var n = 2
        while files.fileExists(atPath: candidate.path) {
            candidate = projectsFolder.appendingPathComponent("\(base) \(n)").appendingPathExtension("littlesurface")
            n += 1
        }
        return candidate
    }

    // MARK: Actions

    func rememberExternal(_ url: URL) {
        guard !url.standardizedFileURL.path.hasPrefix(projectsFolder.standardizedFileURL.path),
              let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        var list = bookmarks
        list.removeAll { $0 == data }
        list.insert(data, at: 0)
        bookmarks = Array(list.prefix(24))
        refresh()
    }

    func delete(_ item: ProjectItem) {
        if item.isExternal {
            // Only forgets it. The file belongs to wherever the artist keeps it.
            bookmarks.removeAll { $0 == item.bookmark }
        } else {
            try? files.removeItem(at: item.url)
        }
        try? files.removeItem(at: thumbnailURL(for: item.url))
        refresh()
    }

    func duplicate(_ item: ProjectItem) {
        let target = uniqueURL(named: item.name)
        let scoped = item.url.startAccessingSecurityScopedResource()
        defer { if scoped { item.url.stopAccessingSecurityScopedResource() } }
        try? files.copyItem(at: item.url, to: target)
        try? files.copyItem(at: thumbnailURL(for: item.url), to: thumbnailURL(for: target))
        refresh()
    }

    /// Renames the open project's file, which UIDocument follows through file coordination.
    func rename(_ document: ProjectDocument, to name: String) {
        let source = document.fileURL
        guard source.standardizedFileURL.path.hasPrefix(projectsFolder.standardizedFileURL.path) else { return }
        guard Self.safeFileName(name) != source.deletingPathExtension().lastPathComponent else { return }
        let target = uniqueURL(named: name)
        let oldThumb = thumbnailURL(for: source), newThumb = thumbnailURL(for: target)
        DispatchQueue.global(qos: .userInitiated).async {
            let coordinator = NSFileCoordinator(filePresenter: document)
            var error: NSError?
            coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: target, options: .forReplacing, error: &error) { from, to in
                coordinator.item(at: from, willMoveTo: to)
                if (try? FileManager.default.moveItem(at: from, to: to)) != nil {
                    coordinator.item(at: from, didMoveTo: to)
                    try? FileManager.default.moveItem(at: oldThumb, to: newThumb)
                }
            }
            DispatchQueue.main.async { self.refresh() }
        }
    }

    // MARK: Thumbnails

    private func thumbnailURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return thumbnailsFolder.appendingPathComponent(digest).appendingPathExtension("png")
    }

    func thumbnail(for url: URL) -> UIImage? {
        UIImage(contentsOfFile: thumbnailURL(for: url).path)
    }

    func storeThumbnail(_ image: UIImage, for url: URL) {
        let target = thumbnailURL(for: url)
        DispatchQueue.global(qos: .utility).async {
            if let data = image.pngData() { try? data.write(to: target, options: .atomic) }
            DispatchQueue.main.async { self.thumbnailStamp &+= 1 }
        }
    }
}
