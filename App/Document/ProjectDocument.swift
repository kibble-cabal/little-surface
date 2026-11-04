import LittleSurfaceCore
import UIKit
import UniformTypeIdentifiers

extension UTType {
    static let littleSurfaceProject = UTType(exportedAs: "com.audreyserene.littlesurface.project")
    static let objModel = UTType(importedAs: "public.wavefront-obj-model")
    static let glbModel = UTType(importedAs: "org.khronos.gltf-binary")
    static let gltfModel = UTType(importedAs: "org.khronos.gltf")
}

/// The file behind an open project. UIDocument provides autosave, safe writing and file coordination;
/// encoding and decoding happen on its background queue, so big projects never block the interface.
final class ProjectDocument: UIDocument {
    /// What was read from disk, until the editor takes it.
    private(set) var loaded: ProjectSnapshot?
    /// Asks the editor for the current state. Runs on the main thread when a save begins.
    var snapshotProvider: (() -> ProjectSnapshot)?
    private(set) var lastSaveError: Error?

    override func contents(forType typeName: String) throws -> Any {
        guard let snapshot = snapshotProvider?() ?? loaded else {
            throw ProjectFileError.damaged("There's nothing to save yet.")
        }
        // A value copy, encoded later in writeContents off the main thread.
        return SnapshotBox(snapshot: snapshot)
    }

    override func writeContents(_ contents: Any, to url: URL, for saveOperation: UIDocument.SaveOperation, originalContentsURL: URL?) throws {
        guard let box = contents as? SnapshotBox else {
            throw ProjectFileError.damaged("Unexpected contents while saving.")
        }
        let data = try ProjectCodec.encode(box.snapshot)
        // The bytes must read back before they replace the last good copy. A failure here leaves that
        // copy untouched and shows up as a failed save.
        _ = try ProjectCodec.decode(data)
        try data.write(to: url, options: .atomic)
    }

    override func read(from url: URL) throws {
        loaded = try ProjectCodec.decode(try Data(contentsOf: url))
    }

    override func handleError(_ error: Error, userInteractionPermitted: Bool) {
        lastSaveError = error
        super.handleError(error, userInteractionPermitted: userInteractionPermitted)
    }

    func releaseLoaded() {
        loaded = nil
    }
}

private final class SnapshotBox {
    let snapshot: ProjectSnapshot
    init(snapshot: ProjectSnapshot) { self.snapshot = snapshot }
}
