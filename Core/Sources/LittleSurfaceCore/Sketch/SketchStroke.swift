import Foundation
import simd

/// A planning line drawn on the model, as you might on paper. It lives apart from the mesh, so it
/// never reaches the topology, the counts or an export.
public struct SketchStroke: Equatable {
    public var points: [Vec3]
    public var colorIndex: Int

    public init(points: [Vec3], colorIndex: Int) {
        self.points = points
        self.colorIndex = colorIndex
    }
}

public enum SketchPalette {
    /// Strong enough to read on a gray model and next to the emerald topology.
    public static let colors: [Vec4] = [
        Vec4(0.90, 0.18, 0.16, 1),
        Vec4(0.96, 0.55, 0.05, 1),
        Vec4(0.13, 0.42, 0.92, 1),
        Vec4(0.72, 0.20, 0.82, 1),
        Vec4(0.08, 0.62, 0.72, 1),
        Vec4(0.10, 0.10, 0.12, 1),
        Vec4(0.33, 0.33, 0.35, 0.8),
    ]

    public static let names = ["Red", "Orange", "Blue", "Purple", "Teal", "Black", "Graphite"]

    /// A pencil mark that didn't become topology.
    public static let graphite = 6

    public static func color(_ index: Int) -> Vec4 {
        colors[max(0, min(index, colors.count - 1))]
    }
}
