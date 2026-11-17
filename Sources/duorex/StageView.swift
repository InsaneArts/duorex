import AppKit
import Metal
import IOSurface
import QuartzCore

/// Draws the device at display rate. The pose and the gestures are `DeviceMotion`'s; this view
/// gives it the pointer, the time and what the scene has under a point.
/// Pointer positions are in view points with the origin at the top left.
final class StageView: NSView {
    let scene: DuoScene
    /// The screen that takes touches. The simulator decides which one is lit.
    var activePanel = Panel.inner
    /// What the user's motion asks of the simulator.
    var onEffect: ((DeviceMotion.Effect) -> Void)?

    private var motion = DeviceMotion()
    private var link: CADisplayLink?
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
        motion.viewSize = CGSize(width: max(newSize.width, 1), height: max(newSize.height, 1))
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

    var hingeDegrees: Double { motion.pose.hinge }

    /// True while a press that began on the device is still held.
    var isDragging: Bool { motion.isDragging }

    /// Animates to a hinge angle the user asked for.
    func fold(to degrees: Double) {
        motion.fold(to: degrees)
        setNeedsRender()
    }

    /// Takes the hinge angle the simulator reports, as when an agent folds the device.
    func follow(hinge degrees: Double, animated: Bool) {
        motion.follow(hinge: degrees, animated: animated)
        setNeedsRender()
    }

    /// Animates the device to a roll, in degrees.
    func rotate(to degrees: Double) {
        motion.rotate(to: degrees)
        setNeedsRender()
    }

    // MARK: Pointer

    func pointerDown(at point: CGPoint, option: Bool) {
        send(motion.pointerDown(at: point, option: option) { probe($0) })
    }

    func pointerMoved(to point: CGPoint) {
        send(motion.pointerMoved(to: point) { probe($0) })
    }

    func pointerUp(at point: CGPoint) {
        send(motion.pointerUp(at: point) { probe($0) })
    }

    /// The pointer left the pane, so the device stops turning toward it.
    func pointerLeft() { motion.pointerLeft() }

    /// One wheel step. Positive `lines` scrolls the content down.
    func scroll(at point: CGPoint, lines: Double) {
        send(motion.wheel(at: point, lines: lines) { probe($0) })
    }

    private func probe(_ point: CGPoint) -> Probe {
        scene.probe(at: CGPoint(x: point.x / max(bounds.width, 1), y: point.y / max(bounds.height, 1)), panel: activePanel)
    }

    private func send(_ effects: [DeviceMotion.Effect]) {
        effects.forEach { onEffect?($0) }
        setNeedsRender()
    }

    // MARK: Frame

    @objc private func tick(_ link: CADisplayLink) {
        let step = motion.step(to: CACurrentMediaTime())
        step.effects.forEach { onEffect?($0) }
        if step.moving { setNeedsRender() }
        guard pendingFrames > 0, !rendering, window?.isVisible == true, !surfaces.isEmpty else { return }
        pendingFrames -= 1
        scene.apply(motion.pose)
        let index = nextSurface, generation = surfaceGeneration
        nextSurface = (nextSurface + 1) % surfaces.count
        rendering = true
        do {
            try scene.render(into: surfaces[index].texture, deltaTime: 1.0 / 60, onComplete: { [weak self] in
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
