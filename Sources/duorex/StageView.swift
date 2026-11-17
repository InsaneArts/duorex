import AppKit
import Metal
import IOSurface
import QuartzCore

/// Draws the device at display rate and turns pointer input into touches, tilts and folds.
/// Pointer positions are in view points with the origin at the top left.
final class StageView: NSView {
    enum TouchPhase: String { case begin, move, end }

    let scene: DuoScene
    /// The screen that takes touches. The simulator decides it; the hinge is the fallback.
    var activePanel: DuoScene.Panel = .inner
    var onTouch: ((TouchPhase, DuoScene.ScreenHit) -> Void)?
    /// Called while the hinge moves because of the user. The simulator follows it.
    var onHinge: ((Double) -> Void)?
    /// False while the hinge is following the simulator, so its own motion is not sent back to it.
    private var userOwnsHinge = true

    private enum Grab {
        case none
        case touch
        case tilt(from: CGPoint, yaw: Double, pitch: Double)
        case fold(from: CGPoint, hinge: Double, sign: Double)
    }

    private var hinge = Spring(180, response: 0.55, damping: 0.9)
    private var yaw = Spring(0, response: 0.5, damping: 0.55)
    private var pitch = Spring(0, response: 0.5, damping: 0.55)
    private var roll = Spring(0, response: 0.45, damping: 0.8)
    private var grab = Grab.none
    private var lastHit: DuoScene.ScreenHit?
    private var lastHover = Date.distantPast
    private var scrollPoint: CGPoint?
    private var scrollEnd: DispatchWorkItem?
    private var reportedHinge = 180.0
    private var link: CADisplayLink?
    private var lastTick = CACurrentMediaTime()
    /// Frames are drawn into these in turn, and the finished one becomes the layer's contents.
    private var surfaces: [(surface: IOSurface, texture: MTLTexture)] = []
    private var nextSurface = 0
    private var surfaceGeneration = 0
    private var rendering = false
    /// Frames drawn since the last reading, for the frame rate in the debug log.
    private(set) var framesDrawn = 0

    func resetFrameCount() { framesDrawn = 0 }
    /// Frames still to draw. The fold rig settles one frame after the pose stops changing.
    private var pendingFrames = 3

    /// Bezel width that counts as grabbing the frame, in framebuffer units.
    private let bezelReach: Float = 0.09

    init(scene: DuoScene) {
        self.scene = scene
        super.init(frame: .zero)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.contentsGravity = .resize
        // Core Animation draws the shadow from the frame's alpha, so it follows the device's outline.
        layer?.shadowColor = .black
        layer?.shadowOpacity = 0.5
        layer?.shadowRadius = 26
        layer?.shadowOffset = CGSize(width: 0, height: -20)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("StageView is created in code") }

    override func viewDidMoveToWindow() {
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        link = displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
        makeSurfaces()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        makeSurfaces()
    }

    override func viewDidChangeBackingProperties() { makeSurfaces() }

    /// Three surfaces: one on screen, one being drawn, one spare.
    private func makeSurfaces() {
        let scale = window?.backingScaleFactor ?? 2
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard width > 1, height > 1, surfaces.first.map({ $0.texture.width != width || $0.texture.height != height }) ?? true else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        surfaces = (0..<3).compactMap { _ in
            guard let surface = IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4, .pixelFormat: kCVPixelFormatType_32BGRA]),
                  let texture = scene.device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else { return nil }
            // RealityRenderer writes Display P3 colors.
            if let space = CGColorSpace(name: CGColorSpace.displayP3)?.copyPropertyList() {
                IOSurfaceSetValue(surface, kIOSurfaceColorSpace, space)
            }
            return (surface, texture)
        }
        surfaceGeneration += 1
        nextSurface = 0
        layer?.contentsScale = scale
        setNeedsRender()
    }

    /// Asks for a new frame, as when a screen texture changed.
    func setNeedsRender() { pendingFrames = max(pendingFrames, 2) }

    var hingeDegrees: Double { hinge.value }

    /// Animates to a hinge angle the user asked for.
    func fold(to degrees: Double) {
        userOwnsHinge = true
        hinge.target = min(max(degrees, 0), 180)
    }

    /// Takes the hinge angle the simulator reports, as when an agent folds the device.
    func follow(hinge degrees: Double, animated: Bool) {
        guard case .none = grab else { return }
        userOwnsHinge = false
        if animated { hinge.target = degrees } else { hinge.hold(degrees) }
        reportedHinge = degrees
        setNeedsRender()
    }

    /// Animates the device to a quarter-turn rotation, in degrees.
    func rotate(to degrees: Double) {
        // Take the short way round.
        var delta = (degrees - roll.target).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
        roll.target += delta
    }

    // MARK: Pointer

    /// True while a press that began on the device is still held.
    var isDragging: Bool {
        if case .none = grab { false } else { true }
    }

    /// The pointer left the pane, so the device stops turning toward it.
    func pointerLeft() { lastHover = .distantPast }

    func pointerDown(at point: CGPoint, option: Bool) {
        endScroll()
        if !option, let hit = scene.screenHit(at: unit(point), panel: activePanel) {
            grab = .touch
            lastHit = hit
            onTouch?(.begin, hit)
        } else if option || scene.screenHit(at: unit(point), panel: activePanel, reach: bezelReach) != nil {
            // Pulling the leaf that moves closes it toward the other; pulling the fixed leaf mirrors that.
            let fixedLeaf = hinge.value > 90 && point.x > bounds.midX
            userOwnsHinge = true
            grab = .fold(from: point, hinge: hinge.value, sign: fixedLeaf ? 1 : -1)
        } else {
            grab = .tilt(from: point, yaw: yaw.value, pitch: pitch.value)
        }
    }

    func pointerMoved(to point: CGPoint) {
        switch grab {
        case .none:
            // A little parallax toward the pointer keeps the device feeling like an object.
            lastHover = Date()
            yaw.target = (Double(point.x / max(bounds.width, 1)) - 0.5) * 9
            pitch.target = (Double(point.y / max(bounds.height, 1)) - 0.5) * 6
        case .touch:
            guard let hit = scene.screenHit(at: unit(point), panel: activePanel, reach: .infinity) else { return }
            lastHit = hit
            onTouch?(.move, hit)
        case .tilt(let from, let startYaw, let startPitch):
            yaw.hold(rubberBand(startYaw + Double(point.x - from.x) * 0.35, limit: 55))
            pitch.hold(rubberBand(startPitch + Double(point.y - from.y) * 0.35, limit: 35))
        case .fold(let from, let start, let sign):
            let travel = Double(point.x - from.x) / Double(max(bounds.width, 1) * 0.5)
            hinge.hold(min(max(start + sign * travel * 180, 0), 180))
        }
        setNeedsRender()
    }

    func pointerUp(at point: CGPoint) {
        switch grab {
        case .touch:
            if let hit = scene.screenHit(at: unit(point), panel: activePanel, reach: .infinity) ?? lastHit { onTouch?(.end, hit) }
        case .fold:
            // Close enough to shut or flat finishes the move.
            if hinge.value < 14 { hinge.target = 0 } else if hinge.value > 166 { hinge.target = 180 }
        case .tilt, .none:
            break
        }
        grab = .none
        yaw.target = 0
        pitch.target = 0
        setNeedsRender()
    }

    /// One wheel step. Positive `lines` scrolls the content down, as a finger moving up does.
    func scroll(at point: CGPoint, lines: Double) {
        guard case .none = grab else { return }
        let step = CGFloat(lines) * bounds.height * 0.035
        if let current = scrollPoint {
            let next = CGPoint(x: current.x, y: current.y - step)
            scrollPoint = next
            if let hit = scene.screenHit(at: unit(next), panel: activePanel, reach: .infinity) {
                lastHit = hit
                onTouch?(.move, hit)
            }
        } else if let hit = scene.screenHit(at: unit(point), panel: activePanel) {
            scrollPoint = point
            lastHit = hit
            onTouch?(.begin, hit)
        }
        scrollEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in self?.endScroll() }
        scrollEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: end)
    }

    private func endScroll() {
        scrollEnd?.cancel()
        scrollEnd = nil
        guard scrollPoint != nil else { return }
        scrollPoint = nil
        if let lastHit { onTouch?(.end, lastHit) }
    }

    private func unit(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / max(bounds.width, 1), y: point.y / max(bounds.height, 1))
    }

    /// Lets a drag go past `limit` with growing resistance.
    private func rubberBand(_ value: Double, limit: Double) -> Double {
        let over = abs(value) - limit
        guard over > 0 else { return value }
        return (value < 0 ? -1 : 1) * (limit + limit * 0.5 * (1 - 1 / (over / limit + 1)))
    }

    // MARK: Frame

    @objc private func tick(_ link: CADisplayLink) {
        // Real elapsed time, so a late frame does not slow the motion down.
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTick, 1.0 / 240), 0.1)
        lastTick = now
        if case .none = grab, Date().timeIntervalSince(lastHover) > 1.2 {
            yaw.target = 0
            pitch.target = 0
        }
        let moving = [hinge.step(dt), yaw.step(dt), pitch.step(dt), roll.step(dt)].contains(true)
        if moving { setNeedsRender() }
        if userOwnsHinge, abs(hinge.value - reportedHinge) >= 0.5 || (!moving && hinge.value != reportedHinge) {
            reportedHinge = hinge.value
            onHinge?(hinge.value)
        }
        guard pendingFrames > 0, !rendering, window?.isVisible == true, !surfaces.isEmpty else { return }
        pendingFrames -= 1
        scene.apply(.init(hinge: hinge.value, roll: roll.value, yaw: yaw.value, pitch: pitch.value))
        let index = nextSurface, generation = surfaceGeneration
        nextSurface = (nextSurface + 1) % surfaces.count
        rendering = true
        do {
            try scene.render(into: surfaces[index].texture, deltaTime: dt, onComplete: { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.rendering = false
                    self.framesDrawn += 1
                    // A resize may have replaced the surfaces while this frame was drawing.
                    if generation == self.surfaceGeneration { self.layer?.contents = self.surfaces[index].surface }
                }
            })
        } catch {
            rendering = false
            log.error("render: \(String(describing: error), privacy: .public)")
        }
    }
}
