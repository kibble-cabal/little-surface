import Foundation
import simd

/// Keeps the faces in step with the lines: every area that lines fence in is one face, however many
/// corners it has, until more lines divide it.
public enum DrawnFaces {
    static func update(after result: PlanResult, in mesh: inout Mesh, projector: SurfaceProjector?) throws {
        mesh.settleBends()
        for outline in EnclosedRegions.regions(bordering: result.edges, in: mesh, projector: projector) where mesh.canAddFace(outline.vertices) {
            try mesh.addFace(outline.vertices, autoOrient: false)
        }
        mesh.straightenQuads()
    }
}
