import Foundation

public struct ImportedModel {
    public var objects: [SourceObject]
    public var warnings: [String] = []
    public var name: String

    public init(objects: [SourceObject], warnings: [String] = [], name: String) {
        self.objects = objects
        self.warnings = warnings
        self.name = name
    }

    public var triangleCount: Int { objects.reduce(0) { $0 + $1.triangleCount } }
}

/// Each message tells the artist what to do next, not just what went wrong.
public enum ImportError: LocalizedError, Equatable {
    case unsupportedFormat(String)
    case noGeometry
    case malformed(String)
    case unsupportedFeature(String)
    case missingExternalFile(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return ext.isEmpty
                ? "This file has no extension, so its format can't be identified. Little Surface opens OBJ, GLB and glTF files."
                : "Little Surface can't open .\(ext) files. It opens OBJ, GLB and glTF."
        case .noGeometry:
            return "This file doesn't contain any triangles or polygons to work on."
        case .malformed(let detail):
            return "This file looks damaged: \(detail)."
        case .unsupportedFeature(let detail):
            return detail
        case .missingExternalFile(let name):
            return "This glTF needs a companion file, \(name), that couldn't be opened. Try exporting the model as a single .glb file."
        case .cancelled:
            return "Import cancelled."
        }
    }
}

public enum ModelImporter {
    /// Reads a model from disk. Runs on the caller's thread, so call it off the main thread.
    public static func load(url: URL, isCancelled: @escaping () -> Bool = { false }) throws -> ImportedModel {
        let ext = url.pathExtension.lowercased()
        let name = url.deletingPathExtension().lastPathComponent
        var model: ImportedModel
        switch ext {
        case "obj":
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            model = try OBJImporter.load(data: data, name: name, isCancelled: isCancelled)
        case "glb":
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            model = try GLTFImporter.loadGLB(data: data, name: name)
        case "gltf":
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            model = try GLTFImporter.loadGLTF(json: data, name: name, baseURL: url.deletingLastPathComponent())
        default:
            throw ImportError.unsupportedFormat(ext)
        }
        guard !model.objects.isEmpty, model.triangleCount > 0 else { throw ImportError.noGeometry }
        for i in 0..<model.objects.count { model.objects[i].normalizeOrientation() }
        return model
    }
}
