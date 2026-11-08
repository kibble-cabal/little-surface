import LittleSurfaceCore
import MetalKit
import SwiftUI
import simd

// MARK: Content

struct GuidePage {
    let title: String
    /// Markdown, for the bold terms.
    let text: String
    var examples: [GuideExample] = []
    var checklist: [String] = []
}

enum Guide {
    static let pages: [GuidePage] = [
        GuidePage(
            title: "Quads and edge loops",
            text: """
            Aim for **quads**, faces with four sides. When quads sit side by side, their edges join up into **edge loops**, lines of edges you can follow all the way around a shape. Edge loops let a mesh bend evenly, and they're easy to add or remove later.

            **Triangles** are fine on flat parts that won't bend. **N-gons**, faces with five or more sides, are fine while planning but shouldn't stay in the final mesh.
            """,
            examples: [.loops]
        ),
        GuidePage(
            title: "Edge flow",
            text: """
            **Edge flow** is the direction your edge loops run. Make it follow the shape: loops go around anything that sticks out or goes in, like a handle, a horn or a hole, and run along long shapes.
            """,
            examples: [.flow]
        ),
        GuidePage(
            title: "Deformation",
            text: """
            **Deformation** is how a mesh bends when it's posed or animated. Put about 3 edge loops across anything that will bend, and more for a tight bend. Space them evenly, and run them across the bend, not along it.
            """,
            examples: [.bend]
        ),
        GuidePage(
            title: "Poles",
            text: """
            Usually 4 edges meet at a vertex. A **pole** is a vertex where 3 meet (an **N-pole**) or 5 meet (an **E-pole**). Poles are how edge flow turns, splits or changes how many rows there are. Put them on flat parts that won't bend. If more than 5 edges meet, split them across two poles.

            Wherever one shape grows out of another, like a branch or a handle, it takes poles where they join. Poles with 5 or more edges show as purple stars.
            """,
            examples: [.poles, .sprout]
        ),
        GuidePage(
            title: "Openings",
            text: """
            Put at least two edge loops around any hole or opening so its edge keeps its shape.
            """,
            examples: [.opening]
        ),
        GuidePage(
            title: "Reducing loops",
            text: """
            To go from more rows to fewer, use a **3-to-1** or **2-to-1** reduction on a part that doesn't bend.
            """,
            examples: [.reductions, .reducingTube]
        ),
        GuidePage(
            title: "Density",
            text: """
            **Density** is how many polygons cover an area. Keep quads close to square and about the same size. Where density has to change, change it a little at a time.
            """,
            examples: [.density]
        ),
        GuidePage(
            title: "Silhouette",
            text: """
            The **silhouette** is the outline of a shape. It's where low polygon counts show, because a curved edge turns into visible corners. Spend polygons on curves that show in the outline. Areas facing the camera can stay light, since a few polygons more or less barely changes how they look.
            """,
            examples: [.silhouette]
        ),
        GuidePage(
            title: "Before you export",
            text: "",
            checklist: [
                "In **Poly Budget**, there are no n-gons or poles with 6 or more edges, and no poles sit on a bend.",
                "Each bend has about 3 edge loops.",
                "With Mirror on, the vertices on the **mirror seam**, the line down the middle, sit exactly on it.",
                "With **Hide Model** on, the edge flow reads clearly.",
                "Most tools **triangulate** quads into two triangles each when they export or render. On bends, check that the split runs the way the bend folds.",
            ]
        ),
    ]
}

// MARK: Panel

/// The guide, open beside the viewport so you can keep drawing while you read it.
struct GuidePanel: View {
    let model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // As tall as the page, and scrolling only once it's taller than the room there is.
            ViewThatFits(in: .vertical) {
                page
                ScrollView { page }
            }
            if let index = model.guidePage {
                Divider()
                footer(index)
            }
        }
        .frame(width: 360)
        .panel()
        .accessibilityIdentifier("Guide")
    }

    @ViewBuilder private var page: some View {
        if let index = model.guidePage, Guide.pages.indices.contains(index) {
            GuidePageView(page: Guide.pages[index], device: model.renderer?.device)
                .id(index)
        } else {
            contents
        }
    }

    private var header: some View {
        HStack {
            if model.guidePage != nil {
                Button { model.guidePage = nil } label: { Label("Contents", systemImage: "chevron.backward") }
                    .accessibilityIdentifier("Guide Contents")
            } else {
                Text("Retopology Guide").font(.headline)
            }
            Spacer()
            Button { withAnimation(.snappy) { model.showsGuide = false } } label: {
                Image(systemName: "xmark").frame(width: Theme.touchTarget, height: Theme.touchTarget).contentShape(Rectangle())
            }
            .accessibilityLabel("Close Guide")
            .accessibilityIdentifier("Close Guide")
        }
        .buttonStyle(.plain)
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .frame(minHeight: Theme.touchTarget)
    }

    private var contents: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Guide.pages.enumerated()), id: \.offset) { index, page in
                Button { model.guidePage = index } label: {
                    HStack {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(Theme.quiet).frame(width: 22, alignment: .leading)
                        Text(page.title)
                        Spacer()
                        Image(systemName: "chevron.forward").font(.footnote).foregroundStyle(Theme.quiet)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: Theme.touchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("guide-page-\(index + 1)")
            }
        }
        .padding(.vertical, 6)
    }

    private func footer(_ index: Int) -> some View {
        HStack {
            Button { model.guidePage = index - 1 } label: { Label("Previous", systemImage: "chevron.backward") }
                .disabled(index == 0)
                .accessibilityIdentifier("Guide Previous")
            Spacer()
            Text("\(index + 1) of \(Guide.pages.count)").font(.footnote).monospacedDigit().foregroundStyle(Theme.quiet)
            Spacer()
            Button { model.guidePage = index + 1 } label: { Label("Next", systemImage: "chevron.forward") }
                .disabled(index == Guide.pages.count - 1)
                .accessibilityIdentifier("Guide Next")
        }
        .labelStyle(.iconOnly)
        .frame(minHeight: Theme.touchTarget)
        .padding(.horizontal, 16)
    }
}

private struct GuidePageView: View {
    let page: GuidePage
    let device: MTLDevice?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let device {
                ForEach(page.examples, id: \.self) { example in
                    ExampleClip(example: example, device: device)
                }
            }
            Text(page.title).font(.title3.weight(.semibold))
            if !page.text.isEmpty {
                Text(LocalizedStringKey(page.text)).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(page.checklist, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "checkmark.circle").foregroundStyle(Theme.quiet)
                    Text(LocalizedStringKey(item)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
    }
}

// MARK: Clips

/// A guide example playing on a loop, drawn by the same renderer as the viewport.
private struct ExampleClip: View {
    let example: GuideExample
    let device: MTLDevice
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ExampleViewport(example: example, device: device, start: start, still: reduceMotion)
            .aspectRatio(1.5, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topLeading) {
                if example.frame(at: 0).caption != nil {
                    TimelineView(.periodic(from: start, by: 0.25)) { context in
                        let t = reduceMotion ? example.stillTime : context.date.timeIntervalSince(start)
                        if let caption = example.frame(at: t).caption {
                            Text(caption)
                                .font(.footnote.weight(.semibold))
                                .monospacedDigit()
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.thinMaterial, in: Capsule())
                                .padding(8)
                        }
                    }
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Example")
    }
}

private struct ExampleViewport: UIViewRepresentable {
    let example: GuideExample
    let device: MTLDevice
    let start: Date
    let still: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> ExamplePlayer {
        ExamplePlayer(example: example, device: device, start: start)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = ViewportRenderer.colorFormat
        view.depthStencilPixelFormat = ViewportRenderer.depthFormat
        #if targetEnvironment(simulator)
        view.depthStencilStorageMode = .private
        #else
        view.depthStencilStorageMode = .memoryless
        #endif
        view.sampleCount = ViewportRenderer.sampleCount
        view.clearDepth = 1
        view.preferredFramesPerSecond = 30
        view.isUserInteractionEnabled = false
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        let player = context.coordinator
        player.renderer?.isDark = colorScheme == .dark
        player.still = still
        view.isPaused = still
        view.enableSetNeedsDisplay = still
        view.setNeedsDisplay()
    }

    static func dismantleUIView(_ view: MTKView, coordinator: ExamplePlayer) {
        view.isPaused = true
        view.delegate = nil
    }
}

/// Moves an example along in time and hands each frame to a renderer of its own.
final class ExamplePlayer: NSObject, MTKViewDelegate {
    let example: GuideExample
    let renderer: ViewportRenderer?
    let engine = RetopoEngine(name: "Example")
    private let start: Date
    private let bounds: AABB
    var still = false

    init(example: GuideExample, device: MTLDevice, start: Date) {
        self.example = example
        self.start = start
        renderer = ViewportRenderer(device: device)
        bounds = example.bounds
        super.init()
        renderer?.engine = engine
        renderer?.dotScale = 0.55
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let renderer, view.bounds.width > 0 else { return }
        show(at: still ? example.stillTime : Date().timeIntervalSince(start), size: view.bounds.size)
        renderer.draw(in: view)
    }

    /// Puts the example's frame at time `t` on the engine, with the camera looking at it.
    func show(at t: Double, size: CGSize) {
        let frame = example.frame(at: t)
        engine.showExample(mesh: frame.mesh, highlight: frame.highlight)

        let look = example.view(at: t.truncatingRemainder(dividingBy: example.duration))
        let toEye = Vec3(sin(look.yaw) * cos(look.pitch), sin(look.pitch), cos(look.yaw) * cos(look.pitch))
        var camera = Camera()
        camera.viewSize = Vec2(Float(size.width), Float(size.height))
        camera.orientation = Camera.orientation(facing: toEye, near: Vec3(0, 1, 0))
        camera.frame(bounds, updateSceneRadius: true)
        // Close enough that the box's corners just fit across and up the clip, with a margin.
        let center = bounds.center
        var across: Float = 0, up: Float = 0, deep: Float = 0
        for i in 0..<8 {
            let corner = Vec3(i & 1 == 0 ? bounds.minCorner.x : bounds.maxCorner.x,
                              i & 2 == 0 ? bounds.minCorner.y : bounds.maxCorner.y,
                              i & 4 == 0 ? bounds.minCorner.z : bounds.maxCorner.z) - center
            across = max(across, abs(simd_dot(corner, camera.right)))
            up = max(up, abs(simd_dot(corner, camera.up)))
            deep = max(deep, simd_dot(corner, toEye))
        }
        let slope = tan(camera.fovY / 2)
        camera.target = center
        camera.distance = max(up / slope, across / (slope * camera.aspect)) * 1.18 + deep
        engine.camera = camera
    }
}
