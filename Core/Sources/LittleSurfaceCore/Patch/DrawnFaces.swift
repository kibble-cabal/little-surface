import Foundation
import simd

/// Keeps the faces in step with the lines: every area that lines fence in is one face, however many
/// corners it has, until more lines divide it.
public enum DrawnFaces {
    /// After a stroke: `result` is what it added, and `met` holds the points it used that were already there.
    static func update(after result: PlanResult, met: [VertexID], in mesh: inout Mesh, projector: SurfaceProjector?, mirrored: Bool) throws {
        mesh.settleBends()

        // A line reaches as far as the lines it joins, so two strokes can cut a face between them.
        var reached = Set(met + result.edges.flatMap { edge -> [VertexID] in
            let (a, b) = mesh.ends(edge)
            return [a, b]
        })
        for v in reached where mesh.mirrorPartner[Int(v)] >= 0 { reached.insert(mesh.mirrorPartner[Int(v)]) }
        var frontier = Array(reached)
        var border = result.edges
        while let v = frontier.popLast() {
            for e in mesh.edgesOf(v) where mesh.isWire(e) {
                border.append(e)
                let other = mesh.otherEnd(e, from: v)
                if reached.insert(other).inserted { frontier.append(other) }
            }
        }

        // Any face with two of those on it may now be divided. If it isn't, the same outline remakes it.
        var taken: [[VertexID]] = []
        for f in mesh.aliveFaces where mesh.loop(f).filter(reached.contains).count >= 2 {
            taken.append(mesh.loop(f))
            border += mesh.edgeLoop(f)
            mesh.removeFace(f)
        }

        var added: [FaceID] = []
        for outline in EnclosedRegions.regions(bordering: border, in: mesh, projector: projector) where mesh.canAddFace(outline.vertices) {
            added.append(try mesh.addFace(outline.vertices, autoOrient: false))
        }
        // A shape drawn entirely inside another leaves a hole that one face can't have, so the outer
        // one waits for lines that join them.
        for f in mesh.aliveFaces where !added.contains(f) && added.contains(where: { encloses(mesh.loop(f), $0, in: mesh) }) {
            mesh.removeFace(f)
        }
        // Whatever no outline remade, and nothing new has taken the place of, stays as it was.
        for loop in taken where mesh.findFace(withVertices: loop) == nil && mesh.canAddFace(loop) && !added.contains(where: { encloses(loop, $0, in: mesh) }) {
            try mesh.addFace(loop, autoOrient: false)
        }
        mesh.straightenQuads(mirrored: mirrored)
    }

    private static func encloses(_ loop: [VertexID], _ face: FaceID, in mesh: Mesh) -> Bool {
        guard mesh.isFaceAlive(face), !mesh.loop(face).allSatisfy(loop.contains) else { return false }
        let points = loop.map { mesh.position($0) }
        let facing = GeometryMath.newellNormal(points)
        guard simd_length_squared(facing) > 0, simd_dot(facing, mesh.faceNormal(face)) > 0 else { return false }
        let center = mesh.faceCenter(face)
        let middle = points.reduce(.zero, +) / Float(points.count)
        guard simd_length(center - middle) <= points.map({ simd_length($0 - middle) }).max() ?? 0 else { return false }
        return EnclosedRegions.contains(center, outline: points, axis: simd_normalize(facing))
    }
}
