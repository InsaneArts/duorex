import AppKit
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
    /// The pointer came to rest on a hardware button, or left it.
    var onHover: ((HardwareButton?) -> Void)?
    /// Another client of the simulator did something, or has been quiet for a moment.
    var onActivity: ((SimWire.Activity?) -> Void)?
    /// When set, every change to the device also goes into its movie.
    var recorder: Recorder?

    private var motion = DeviceMotion()
    private var presence = Presence()
    /// The marks and the activity as they were at the last tick.
    private var marks: [Mark] = []
    private var activity: SimWire.Activity?
    private var link: CADisplayLink?
    /// The device is drawn into these in turn, and the finished one becomes the layer's contents:
    /// one on screen, one being drawn, one spare.
    private var frames: [Frame] = []
    private var nextFrame = 0
    private var rendering = false
    /// Frames drawn since the last reading, for the frame rate in the debug log.
    private(set) var framesDrawn = 0

    func resetFrameCount() { framesDrawn = 0 }
    private var needsRender = true
    /// True while the movie has not taken the latest change. The movie and the pane draw at their own pace.
    private var movieNeedsRender = true

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
        makeFrames()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        motion.viewSize = CGSize(width: max(newSize.width, 1), height: max(newSize.height, 1))
        makeFrames()
    }

    override func viewDidChangeBackingProperties() { makeFrames() }

    private func makeFrames() {
        let scale = window?.backingScaleFactor ?? 2
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard width > 1, height > 1, frames.first.map({ $0.width != width || $0.height != height }) ?? true else { return }
        frames = (0..<3).compactMap { _ in Frame(device: scene.device, width: width, height: height) }
        nextFrame = 0
        layer?.contentsScale = scale
        setNeedsRender()
    }

    /// Asks for a new frame, as when a screen texture changed.
    func setNeedsRender() {
        needsRender = true
        movieNeedsRender = true
    }

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

    /// Takes something another client did to the simulator. Its touches show on the lit screen.
    func saw(_ activity: SimWire.Activity) {
        presence.saw(activity, time: CACurrentMediaTime())
    }

    // MARK: Pointer

    func pointerDown(at point: CGPoint, option: Bool) {
        send(motion.pointerDown(at: point, option: option) { probe($0) })
    }

    /// `pressed` is whether the terminal says that a button is down.
    func pointerMoved(to point: CGPoint, option: Bool, pressed: Bool) {
        let hovered = motion.hoveredButton
        send(motion.pointerMoved(to: point, option: option, pressed: pressed) { probe($0) })
        if motion.hoveredButton != hovered { onHover?(motion.hoveredButton) }
    }

    func pointerUp(at point: CGPoint) {
        send(motion.pointerUp(at: point) { probe($0) })
    }

    /// The pointer left the pane, so the device stops turning toward it.
    func pointerLeft() {
        let hovered = motion.hoveredButton
        motion.pointerLeft()
        if hovered != nil { onHover?(nil) }
    }

    /// One wheel step. Positive `lines` scrolls the content down.
    func scroll(at point: CGPoint, lines: Double) {
        send(motion.wheel(at: point, lines: lines) { probe($0) })
    }

    private func probe(_ point: CGPoint) -> Probe {
        scene.probe(at: CGPoint(x: point.x / max(bounds.width, 1), y: point.y / max(bounds.height, 1)),
                    aspect: Float(bounds.width / max(bounds.height, 1)), panel: activePanel)
    }

    private func send(_ effects: [DeviceMotion.Effect]) {
        effects.forEach { onEffect?($0) }
        setNeedsRender()
    }

    // MARK: Frame

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let step = motion.step(to: now)
        step.effects.forEach { onEffect?($0) }
        if step.moving { setNeedsRender() }
        // Another client's touches, and under them the user's own two fingers in a pinch.
        let marks = motion.fingers.map { Mark(point: $0, radius: Presence.radius, opacity: 1, look: .finger) } + presence.step(to: now)
        if marks != self.marks {
            self.marks = marks
            setNeedsRender()
        }
        let activity = presence.current(at: now)
        if activity != self.activity {
            self.activity = activity
            onActivity?(activity)
        }
        guard needsRender || movieNeedsRender else { return }
        scene.apply(motion.pose, marks: marks, on: activePanel)
        // The movie gets every change, whether or not the pane can show it.
        if movieNeedsRender { movieNeedsRender = !(recorder?.capture(scene: scene, time: now) ?? true) }
        guard needsRender else { return }
        guard window?.isVisible == true, !frames.isEmpty else {
            needsRender = false
            return
        }
        // The last frame is still drawing. Try again at the next tick.
        guard !rendering else { return }
        needsRender = false
        let frame = frames[nextFrame]
        nextFrame = (nextFrame + 1) % frames.count
        rendering = true
        do {
            try scene.render(into: frame) { [weak self, weak frame] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.rendering = false
                    self.framesDrawn += 1
                    // A resize may have replaced the frames while this one was drawing.
                    if let frame, self.frames.contains(where: { $0 === frame }) { self.layer?.contents = frame.surface }
                }
            }
        } catch {
            rendering = false
            log.error("render: \(String(describing: error), privacy: .public)")
        }
    }
}
