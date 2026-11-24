import AppKit
import CoreVideo
import IOSurface
import Metal
import QuartzCore

/// An iPhone drawn flat, as Simulator.app draws it: Xcode's chrome, with the simulator's live
/// framebuffer on its screen.
///
/// The pose and the gestures are `DeviceMotion`'s, as for iPhone Duo: it turns as the device is
/// held, and leans a little toward the pointer. It does not fold. The screen shows the
/// framebuffer itself, so a new picture costs no copy.
final class FlatStageView: NSView, DeviceView {
    var onEffect: ((DeviceMotion.Effect) -> Void)?
    var onHover: ((HardwareButton?) -> Void)?
    var onActivity: ((SimWire.Activity?) -> Void)?
    private(set) var framesDrawn = 0
    func resetFrameCount() { framesDrawn = 0 }

    private let chrome: DeviceChrome
    private var geometry: FlatGeometry
    private var motion = DeviceMotion()
    private var presence = Presence()
    private var marks: [Mark] = []
    private var activity: SimWire.Activity?
    private var link: CADisplayLink?

    /// The device in the chrome's points. Its transform places, turns and leans it.
    private let device = CALayer()
    private let body = CALayer()
    private let screen = CALayer()
    private let screenShape = CALayer()
    private let glowLayer = CALayer()
    private var buttonLayers: [HardwareButton: CALayer] = [:]
    /// Each button's picture, out and pushed in, drawn at the scale the device shows at.
    private var buttonPictures: [HardwareButton: (out: CGImage?, pushed: CGImage?)] = [:]
    private var markLayers: [CALayer] = []
    private let markPictures: [Mark.Look: CGImage]
    private let glow: Glow?
    private var surface: IOSurface?
    /// The pixels to a chrome point that the pictures were drawn at.
    private var drawnScale: CGFloat = 0

    /// Whether the screen lights the pane around the device. The user's choice is kept from one run to the next.
    var glows = !UserDefaults.standard.bool(forKey: "glowOff") {
        didSet {
            UserDefaults.standard.set(!glows, forKey: "glowOff")
            glowLayer.isHidden = !glows
        }
    }

    init(chrome: DeviceChrome) {
        self.chrome = chrome
        geometry = FlatGeometry(body: chrome.body, screen: chrome.screen, margin: chrome.margin,
                                buttons: chrome.buttons.map { .init(button: $0.button, frame: $0.frame) })
        markPictures = Dictionary(uniqueKeysWithValues: [Mark.Look.spot, .ring, .finger].compactMap { look in look.picture.map { (look, $0) } })
        glow = MTLCreateSystemDefaultDevice().map(Glow.init)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.isOpaque = false
        // A little perspective, so a lean looks like one.
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 2400
        layer?.sublayerTransform = perspective

        let offset = CGPoint(x: chrome.margin, y: chrome.margin)
        device.bounds = CGRect(origin: .zero, size: geometry.canvas)
        glowLayer.frame = chrome.screen.offsetBy(dx: offset.x, dy: offset.y)
            .insetBy(dx: -chrome.screen.width * 0.3, dy: -chrome.screen.height * 0.2)
        glowLayer.isHidden = !glows
        device.addSublayer(glowLayer)
        // The buttons go under the body, which covers their inner part.
        for button in chrome.buttons {
            let layer = CALayer()
            layer.frame = button.frame.offsetBy(dx: offset.x, dy: offset.y)
            device.addSublayer(layer)
            buttonLayers[button.button] = layer
        }
        body.frame = CGRect(origin: offset, size: chrome.body)
        // Core Animation draws the shadow from the body's outline.
        body.shadowColor = .black
        body.shadowOpacity = 0.5
        body.shadowRadius = 26
        body.shadowOffset = CGSize(width: 0, height: 20)
        body.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: chrome.body), cornerWidth: chrome.cornerRadius,
                                 cornerHeight: chrome.cornerRadius, transform: nil)
        device.addSublayer(body)
        screen.frame = chrome.screen.offsetBy(dx: offset.x, dy: offset.y)
        screen.contentsGravity = .resize
        screen.backgroundColor = .black
        screenShape.frame = CGRect(origin: .zero, size: chrome.screen.size)
        screen.mask = screenShape
        device.addSublayer(screen)
        for each in [device, glowLayer, body, screen, screenShape] + Array(buttonLayers.values) {
            // A layer of its own fades from one picture to the next unless it is told not to.
            each.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "transform": NSNull(), "hidden": NSNull()]
        }
        layer?.addSublayer(device)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("FlatStageView is created in code") }

    /// The origin is at the top left, as the pointer and the chrome have it.
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        link = displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
        drawPictures()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        motion.viewSize = CGSize(width: max(newSize.width, 1), height: max(newSize.height, 1))
        geometry.view = motion.viewSize
        place()
        drawPictures()
    }

    override func viewDidChangeBackingProperties() { drawPictures() }

    /// Draws the body and the buttons sharp at the size they show at. Only a resize changes that.
    private func drawPictures() {
        let scale = geometry.scale * (window?.backingScaleFactor ?? 2)
        guard scale > 0, abs(scale - drawnScale) > 0.01 else { return }
        drawnScale = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.contents = chrome.bodyImage(scale: scale)
        screenShape.contents = chrome.maskImage(scale: scale)
        screenShape.backgroundColor = chrome.mask == nil ? .black : nil
        for each in [body, screenShape] { each.contentsScale = scale }
        for button in chrome.buttons {
            buttonPictures[button.button] = (DeviceChrome.picture(of: button.image, scale: scale), DeviceChrome.picture(of: button.pressedImage, scale: scale))
            buttonLayers[button.button]?.contentsScale = scale
        }
        pressButtons()
        CATransaction.commit()
    }

    // MARK: What the session gives it

    /// Shows a picture of the simulator's screen. The picture is the live framebuffer.
    func show(_ frame: CVPixelBuffer) {
        guard let surface = CVPixelBufferGetIOSurface(frame)?.takeUnretainedValue() else { return }
        self.surface = surface
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The same surface with a new picture in it: Core Animation takes it again when it is set again.
        screen.contents = nil
        screen.contents = surface
        if glows, let glow { glowLayer.contents = glow.surface(for: surface) }
        CATransaction.commit()
        framesDrawn += 1
    }

    /// The screen in pixels, as the framebuffer has it.
    var screenPixels: CGSize { chrome.screenPixels }

    /// Shows a still picture on the screen, as the test pattern.
    func show(picture: CGImage) {
        screen.contents = picture
    }

    func setNeedsRender() {}

    var isDragging: Bool { motion.isDragging }

    func rotate(to degrees: Double) {
        motion.rotate(to: degrees)
    }

    func saw(_ activity: SimWire.Activity) {
        presence.saw(activity, time: CACurrentMediaTime())
    }

    // MARK: Pointer

    func pointerDown(at point: CGPoint, option: Bool) {
        send(motion.pointerDown(at: point, option: option) { geometry.probe($0) })
    }

    func pointerMoved(to point: CGPoint, option: Bool, pressed: Bool) {
        let hovered = motion.hoveredButton
        send(motion.pointerMoved(to: point, option: option, pressed: pressed) { geometry.probe($0) })
        if motion.hoveredButton != hovered { onHover?(motion.hoveredButton) }
    }

    func pointerUp(at point: CGPoint) {
        send(motion.pointerUp(at: point) { geometry.probe($0) })
    }

    func pointerLeft() {
        let hovered = motion.hoveredButton
        motion.pointerLeft()
        if hovered != nil { onHover?(nil) }
    }

    func scroll(at point: CGPoint, lines: Double) {
        send(motion.wheel(at: point, lines: lines) { geometry.probe($0) })
    }

    /// The device does not fold, so the motion's hinge and its sounds go nowhere.
    private func send(_ effects: [DeviceMotion.Effect]) {
        for effect in effects {
            switch effect {
            case .hinge, .sound: continue
            default: onEffect?(effect)
            }
        }
    }

    // MARK: Frame

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let step = motion.step(to: now)
        send(step.effects)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place()
        pressButtons()
        // Another client's touches, and under them the user's own two fingers in a pinch.
        let marks = motion.fingers.map { Mark(point: $0, radius: Presence.radius, opacity: 1, look: .finger) } + presence.step(to: now)
        if marks != self.marks {
            self.marks = marks
            showMarks()
        }
        CATransaction.commit()
        let activity = presence.current(at: now)
        if activity != self.activity {
            self.activity = activity
            onActivity?(activity)
        }
    }

    /// Puts the device in the middle of the view, turned and leaning as the motion has it.
    private func place() {
        let pose = motion.pose
        geometry.roll = pose.roll
        let scale = geometry.scale, radians = { (degrees: Double) in CGFloat(degrees * .pi / 180) }
        var transform = CATransform3DMakeScale(scale, scale, 1)
        transform = CATransform3DConcat(transform, CATransform3DMakeRotation(radians(pose.roll), 0, 0, 1))
        // The lean: the device turns to face the pointer, about the view's own axes.
        transform = CATransform3DConcat(transform, CATransform3DMakeRotation(radians(-pose.yaw), 0, 1, 0))
        transform = CATransform3DConcat(transform, CATransform3DMakeRotation(radians(pose.pitch), 1, 0, 0))
        device.position = CGPoint(x: bounds.midX, y: bounds.midY)
        device.transform = transform
    }

    /// Each button's picture, and the pushed one a little way in.
    private func pressButtons() {
        let press = motion.pose.press
        for button in chrome.buttons {
            guard let layer = buttonLayers[button.button] else { continue }
            let depth = press?.button == button.button ? press!.depth : 0
            let pictures = buttonPictures[button.button]
            layer.contents = depth > 0.5 ? pictures?.pushed : pictures?.out
            // In toward the body's middle, by up to a third of the button's depth.
            let inward: CGFloat = button.frame.midX < chrome.body.width / 2 ? 1 : -1
            layer.frame = button.frame.offsetBy(dx: chrome.margin + inward * button.frame.width / 3 * depth, dy: chrome.margin)
        }
    }

    /// Lays the marks on the screen. Their points are framebuffer points, as the screen's own.
    private func showMarks() {
        let size = chrome.screen.size, side = min(size.width, size.height)
        while markLayers.count < marks.count {
            let layer = CALayer()
            layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
            screen.addSublayer(layer)
            markLayers.append(layer)
        }
        for (index, layer) in markLayers.enumerated() {
            guard index < marks.count else {
                layer.isHidden = true
                continue
            }
            let mark = marks[index], diameter = mark.radius * 2 * side
            layer.isHidden = false
            layer.contents = markPictures[mark.look]
            layer.opacity = Float(mark.opacity)
            layer.frame = CGRect(x: mark.point.x * size.width - diameter / 2, y: mark.point.y * size.height - diameter / 2,
                                 width: diameter, height: diameter)
        }
    }
}
