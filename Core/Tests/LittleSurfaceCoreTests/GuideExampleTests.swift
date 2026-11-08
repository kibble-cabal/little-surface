import XCTest
@testable import LittleSurfaceCore

final class GuideExampleTests: XCTestCase {
    /// Every face made it in, so none was turned away as a duplicate or a bad fit.
    private let faceCounts: [GuideExample: Int] = [
        .loops: 96, .flow: 156, .bend: 96, .poles: 128, .sprout: 80, .opening: 380,
        .reductions: 28, .reducingTube: 69, .density: 72,
    ]

    func testExamplesAreAllQuadsWithEveryFaceInPlace() {
        for example in GuideExample.allCases {
            for i in 0..<6 {
                let frame = example.frame(at: example.duration * Double(i) / 6)
                let mesh = frame.mesh
                XCTAssertTrue(mesh.aliveFaces.allSatisfy(mesh.isQuad), "\(example) has a face that isn't a quad")
                XCTAssertTrue(mesh.aliveVertices.allSatisfy { !mesh.edgesOf($0).isEmpty }, "\(example) has a loose point")
                if let expected = faceCounts[example] {
                    XCTAssertEqual(mesh.aliveFaces.count, expected, "\(example)")
                }
            }
        }
    }

    func testSilhouetteSteps() {
        let counts = [0.5: 16, 2.5: 24, 4.5: 42]
        for (t, faces) in counts {
            let frame = GuideExample.silhouette.frame(at: t)
            XCTAssertEqual(frame.mesh.aliveFaces.count, faces)
            XCTAssertTrue(frame.mesh.aliveFaces.allSatisfy(frame.mesh.isQuad))
        }
    }

    func testPolesAreWhereThePagesSay() {
        let expected: [GuideExample: Int] = [.poles: 1, .sprout: 4, .reductions: 1, .reducingTube: 3]
        for example in GuideExample.allCases {
            let mesh = example.frame(at: example.stillTime).mesh
            XCTAssertEqual(MeshValidator.stars(mesh).count, expected[example] ?? 0, "\(example)")
        }
        let poles = GuideExample.poles.frame(at: 0)
        XCTAssertEqual(poles.highlight.vertices.count, 1)
        XCTAssertEqual(poles.highlight.vertices.first.map { poles.mesh.edgesOf($0).count }, 3)
    }

    func testEveryExampleLightsSomethingUp() {
        for example in GuideExample.allCases where example != .silhouette {
            XCTAssertFalse(example.frame(at: example.stillTime).highlight.isEmpty, "\(example)")
        }
    }

    func testBendStaysInOnePiece() {
        let straight = GuideExample.bend.frame(at: 0).mesh
        let bent = GuideExample.bend.frame(at: 2).mesh
        XCTAssertEqual(straight.aliveFaces.count, bent.aliveFaces.count)
        XCTAssertGreaterThan(bent.bounds.maxCorner.x, straight.bounds.maxCorner.x + 0.5)
    }
}
