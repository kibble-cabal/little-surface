import LittleSurfaceCore
import MetalKit
import simd
import UIKit

/// The viewport's UIKit surface. Tells Pencil apart from fingers: the Pencil always goes to the
/// active tool, and fingers navigate unless the artist has chosen for one finger to draw.
final class ViewportView: MTKView, UIPencilInteractionDelegate {
    weak var model: EditorModel?
    private var engine: RetopoEngine? { model?.engine }
    private var settings: AppSettings { AppSettings.shared }

    private lazy var canvasFeedback = UICanvasFeedbackGenerator(view: self)
    /// Where the last stroke ended, for haptics played as it finishes.
    private var lastStrokeEnd = CGPoint.zero
    private var pencilTouch: UITouch?
    private var lastPencilTime: TimeInterval = 0
    /// A finger acting as a Pencil, when that setting is on or when the Pencil is unavailable.
    private var fingerStroke: UITouch?
    private var fingerStrokeStart: TimeInterval = 0

    private var navTouches: [UITouch] = []
    private var ignoredTouches = Set<UITouch>()
    private var multiTouchStart: TimeInterval = 0
    private var multiTouchMoved = false
    private var multiTouchPeak = 0
    /// After a two-finger gesture, a remaining finger doesn't start orbiting until all are lifted.
    private var navigationLocked = false
    private var lastCentroid = CGPoint.zero
    private var lastSpread: CGFloat = 0
    private var lastFingerAngle: CGFloat = 0
    /// How far two fingers have turned so far, and whether that's enough to count as meaning it.
    private var fingerTurn: CGFloat = 0
    private var isTwisting = false
    /// A pinch or pan always wanders a bit, so the view stays level until the fingers turn this far.
    private let twistThreshold: CGFloat = 12 * .pi / 180

    private var inertia: CADisplayLink?
    private var orbitVelocity = Vec2(repeating: 0)
    private var lastOrbitTime: TimeInterval = 0

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        isMultipleTouchEnabled = true
        isPaused = true
        enableSetNeedsDisplay = true
        colorPixelFormat = ViewportRenderer.colorFormat
        depthStencilPixelFormat = ViewportRenderer.depthFormat
        #if targetEnvironment(simulator)
        depthStencilStorageMode = .private
        #else
        depthStencilStorageMode = .memoryless
        #endif
        sampleCount = ViewportRenderer.sampleCount
        clearDepth = 1
        addInteraction(UIPencilInteraction(delegate: self))
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        isAccessibilityElement = true
        accessibilityLabel = "3D viewport"
        accessibilityHint = "Draw with Apple Pencil. Drag one finger to turn the model, two fingers to pan, pinch to zoom and twist to rotate."
        accessibilityTraits = .allowsDirectInteraction
        accessibilityIdentifier = "viewport"
    }

    private var holdTimer: Timer?
    private var pauseTimer: Timer?
    private var pauseSpot = CGPoint.zero

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let engine, bounds.width > 0 else { return }
        engine.camera.viewSize = Vec2(Float(bounds.width), Float(bounds.height))
        setNeedsDisplay()
    }

    private func point(_ touch: UITouch) -> Vec2 {
        let p = touch.location(in: self)
        return Vec2(Float(p.x), Float(p.y))
    }

    private func pressure(_ touch: UITouch) -> Float {
        guard touch.type == .pencil, touch.maximumPossibleForce > 0 else { return 1 }
        return Float(touch.force / touch.maximumPossibleForce)
    }

    // MARK: Touches

    /// Resting the tip on a point picks it up to move. Anything else is a stroke.
    private func scheduleHold() {
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let self, self.pencilTouch != nil || self.fingerStroke != nil else { return }
            self.engine?.pencilHeld()
            self.setNeedsDisplay()
        }
    }

    /// Resting the tip partway through a stroke tidies it into the shape it was going for. A real
    /// Pencil never quite stops, so only moving away from where it last settled counts.
    private func watchForPause(at p: CGPoint) {
        if pauseTimer != nil, hypot(p.x - pauseSpot.x, p.y - pauseSpot.y) <= 4 { return }
        pauseSpot = p
        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self, let touch = self.pencilTouch ?? self.fingerStroke else { return }
            self.engine?.pencilPaused(at: self.point(touch))
            self.setNeedsDisplay()
        }
    }

    override var accessibilityValue: String? {
        get {
            guard let engine else { return nil }
            let stats = engine.statistics
            return "\(stats.vertices) points, \(stats.edges) lines, \(stats.quads) quads, \(stats.faces - stats.quads) shapes, \(engine.sketches.count) marks"
        }
        set {}
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        stopInertia()
        let now = event?.timestamp ?? CACurrentMediaTime()
        for touch in touches {
            switch touch.type {
            case .pencil, .indirectPointer:
                // The Pencil wins over anything the hand was doing.
                cancelNavigation()
                cancelFingerStroke()
                pencilTouch = touch
                lastPencilTime = now
                canvasFeedback.prepare()
                model?.gestureBegan()
                engine?.steadiness = settings.steadiness
                engine?.pencilBegan(at: point(touch), pressure: pressure(touch))
                scheduleHold()
                pauseTimer?.invalidate()
                pauseTimer = nil
                watchForPause(at: touch.location(in: self))
            default:
                // Palm rejection: nothing counts while the Pencil is down or just after, or if it's palm-sized.
                if pencilTouch != nil || now - lastPencilTime < 0.35 || touch.majorRadius > 60 {
                    ignoredTouches.insert(touch)
                } else {
                    navTouches.append(touch)
                }
            }
        }
        beginFingerGestures(now: now)
        setNeedsDisplay()
    }

    private func beginFingerGestures(now: TimeInterval) {
        switch navTouches.count {
        case 0:
            break
        case 1:
            multiTouchPeak = max(multiTouchPeak, 1)
            multiTouchStart = now
            multiTouchMoved = false
            if settings.oneFingerAction == .draw, !navigationLocked, fingerStroke == nil {
                fingerStroke = navTouches[0]
                fingerStrokeStart = now
                model?.gestureBegan()
                engine?.steadiness = settings.steadiness
                engine?.pencilBegan(at: point(navTouches[0]), pressure: 1)
                scheduleHold()
                pauseTimer?.invalidate()
                pauseTimer = nil
                watchForPause(at: navTouches[0].location(in: self))
            }
        default:
            // A second finger arriving just after the first means it was a navigation gesture all along.
            if fingerStroke != nil { cancelFingerStroke() }
            if multiTouchPeak < navTouches.count {
                multiTouchPeak = navTouches.count
                multiTouchStart = now
                multiTouchMoved = false
            }
            navigationLocked = true
            lastCentroid = centroid()
            lastSpread = spread()
            lastFingerAngle = fingerAngle()
            fingerTurn = 0
            isTwisting = false
            model?.gestureBegan()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let pencil = pencilTouch, touches.contains(pencil) {
            lastPencilTime = event?.timestamp ?? CACurrentMediaTime()
            forwardStroke(pencil, event: event)
        }
        if let finger = fingerStroke, touches.contains(finger) {
            forwardStroke(finger, event: event)
        } else if !navTouches.isEmpty, !touches.isDisjoint(with: navTouches) {
            navigate(touches: touches, event: event)
        }
        setNeedsDisplay()
    }

    private func forwardStroke(_ touch: UITouch, event: UIEvent?) {
        let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
        let predicted = (event?.predictedTouches(for: touch) ?? []).map { point($0) }
        for (i, sample) in coalesced.enumerated() {
            let last = i == coalesced.count - 1
            let p = sample.location(in: self)
            engine?.pencilMoved(to: Vec2(Float(p.x), Float(p.y)), pressure: pressure(sample), predicted: last ? predicted : [])
            watchForPause(at: p)
        }
    }

    private func navigate(touches: Set<UITouch>, event: UIEvent?) {
        guard let engine else { return }
        if navTouches.count == 1 {
            guard !navigationLocked, let touch = touches.first(where: { $0 === navTouches[0] }) else { return }
            let now = event?.timestamp ?? CACurrentMediaTime()
            let a = touch.location(in: self), b = touch.previousLocation(in: self)
            let delta = Vec2(Float(a.x - b.x), Float(a.y - b.y))
            if settings.oneFingerAction == .orbit {
                model?.gestureBegan()
                engine.camera.orbit(deltaPoints: delta)
                let dt = max(Float(now - lastOrbitTime), 1 / 120)
                lastOrbitTime = now
                orbitVelocity = orbitVelocity * 0.6 + delta / dt * 0.4
            }
            engine.cameraChanged()
            model?.cameraDidChange()
            return
        }
        let c = centroid(), s = spread()
        let delta = Vec2(Float(c.x - lastCentroid.x), Float(c.y - lastCentroid.y))
        if simd_length(delta) > 0.5 || abs(s - lastSpread) > 1 { multiTouchMoved = true }
        engine.camera.pan(deltaPoints: delta)
        if lastSpread > 1, s > 1 {
            engine.camera.zoom(factor: Float(s / lastSpread), focus: Vec2(Float(c.x), Float(c.y)))
        }
        var turn = fingerAngle() - lastFingerAngle
        if turn > .pi { turn -= 2 * .pi }
        if turn < -.pi { turn += 2 * .pi }
        lastFingerAngle += turn
        fingerTurn += turn
        if abs(fingerTurn) > twistThreshold, s > 1 {
            isTwisting = true
            multiTouchMoved = true
        }
        if isTwisting { engine.camera.twist(by: Float(turn)) }
        lastCentroid = c
        lastSpread = s
        engine.cameraChanged()
        model?.cameraDidChange()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let now = event?.timestamp ?? CACurrentMediaTime()
        for touch in touches {
            if touch === pencilTouch {
                pencilTouch = nil
                lastPencilTime = now
                lastStrokeEnd = touch.location(in: self)
                engine?.pencilEnded(at: point(touch), pressure: pressure(touch))
                model?.gestureEnded()
            } else if touch === fingerStroke {
                fingerStroke = nil
                navTouches.removeAll { $0 === touch }
                engine?.pencilEnded(at: point(touch), pressure: 1)
                model?.gestureEnded()
            } else if ignoredTouches.remove(touch) == nil {
                navTouches.removeAll { $0 === touch }
            }
        }
        finishNavigationIfDone(now: now)
        setNeedsDisplay()
    }

    private func finishNavigationIfDone(now: TimeInterval) {
        if navTouches.count == 1 {
            lastCentroid = centroid()
            lastSpread = 0
        }
        guard navTouches.isEmpty else { return }
        // Multi-finger taps are decided once everything has lifted, so a gesture can't both undo and pan.
        if multiTouchPeak >= 2, !multiTouchMoved, now - multiTouchStart < 0.35 {
            if multiTouchPeak == 2 { model?.undo() }
            if multiTouchPeak == 3 { model?.redo() }
        }
        let wasOrbiting = !navigationLocked && settings.oneFingerAction == .orbit && multiTouchPeak == 1
        multiTouchPeak = 0
        navigationLocked = false
        model?.gestureEnded()
        if wasOrbiting, settings.orbitInertia, now - lastOrbitTime < 0.05, simd_length(orbitVelocity) > 60 {
            startInertia()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if touch === pencilTouch {
                pencilTouch = nil
                engine?.pencilCancelled()
                model?.gestureEnded()
            } else if touch === fingerStroke {
                fingerStroke = nil
                navTouches.removeAll { $0 === touch }
                engine?.pencilCancelled()
                model?.gestureEnded()
            } else {
                ignoredTouches.remove(touch)
                navTouches.removeAll { $0 === touch }
            }
        }
        if navTouches.isEmpty {
            multiTouchPeak = 0
            navigationLocked = false
            model?.gestureEnded()
        }
        setNeedsDisplay()
    }

    private func cancelNavigation() {
        for touch in navTouches where touch !== fingerStroke { ignoredTouches.insert(touch) }
        navTouches.removeAll { $0 !== fingerStroke }
        multiTouchPeak = 0
        navigationLocked = false
        stopInertia()
    }

    private func cancelFingerStroke() {
        guard fingerStroke != nil else { return }
        fingerStroke = nil
        engine?.pencilCancelled()
    }

    private func centroid() -> CGPoint {
        let n = CGFloat(max(navTouches.count, 1))
        let sum = navTouches.reduce(CGPoint.zero) { partial, t in
            let p = t.location(in: self)
            return CGPoint(x: partial.x + p.x, y: partial.y + p.y)
        }
        return CGPoint(x: sum.x / n, y: sum.y / n)
    }

    private func spread() -> CGFloat {
        guard navTouches.count >= 2 else { return 0 }
        let a = navTouches[0].location(in: self), b = navTouches[1].location(in: self)
        return hypot(a.x - b.x, a.y - b.y)
    }

    private func fingerAngle() -> CGFloat {
        guard navTouches.count >= 2 else { return 0 }
        let a = navTouches[0].location(in: self), b = navTouches[1].location(in: self)
        return atan2(b.y - a.y, b.x - a.x)
    }

    // MARK: Orbit inertia

    private func startInertia() {
        let link = CADisplayLink(target: self, selector: #selector(inertiaStep(_:)))
        link.add(to: .main, forMode: .common)
        inertia = link
    }

    private func stopInertia() {
        inertia?.invalidate()
        inertia = nil
    }

    @objc private func inertiaStep(_ link: CADisplayLink) {
        guard let engine else { return stopInertia() }
        let dt = Float(link.targetTimestamp - link.timestamp)
        orbitVelocity *= pow(0.02, dt)
        if simd_length(orbitVelocity) < 8 { return stopInertia() }
        engine.camera.orbit(deltaPoints: orbitVelocity * dt)
        engine.cameraChanged()
        model?.cameraDidChange()
        setNeedsDisplay()
    }

    // MARK: Pencil extras

    /// A stroke met something existing. Only an Apple Pencil Pro can feel this: iPads have no haptics of their own.
    func playAlignment() {
        canvasFeedback.alignmentOccurred(at: lastStrokeEnd)
    }

    /// A stroke closed into a loop.
    func playPathCompleted() {
        canvasFeedback.pathCompleted(at: lastStrokeEnd)
    }

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        model?.pencilDoubleTapped()
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            let p = recognizer.location(in: self)
            engine?.hover(at: Vec2(Float(p.x), Float(p.y)))
        default:
            engine?.hover(at: nil)
        }
        setNeedsDisplay()
    }
}
