import CoreGraphics
import Foundation

/// What the scene finds under a point of the view.
nonisolated struct Probe: Equatable {
    /// The framebuffer point under the pointer, when it is on the glass of the lit screen.
    var glass: CGPoint?
    /// The framebuffer point on the lit screen nearest the pointer. A drag that left the glass follows it.
    var nearest: CGPoint?
    /// True when the pointer is on the frame around the lit screen.
    var onFrame = false
    /// The hardware button under the pointer.
    var button: HardwareButton?
}

/// The device's pose and what the pointer does to it: touch, scroll, tilt and fold.
///
/// It is a value and takes the time as an input, so it runs the same in a window, in a test and
/// in a recording. Pointer positions are in view points with the origin at the top left. Each
/// pointer call gets a `probe` that says what the scene has under a point.
nonisolated struct DeviceMotion {
    enum TouchPhase {
        case begin, move, end
    }

    /// The sound the device makes when its two halves stop.
    enum Sound: Equatable {
        /// It shut.
        case shut
        /// It opened flat.
        case flat
    }

    /// Something the motion asks for: of the simulator, most of the time.
    enum Effect: Equatable {
        /// A finger on the lit screen, at a framebuffer point.
        case touch(TouchPhase, CGPoint)
        /// A finger that the scroll wheel moves. Unlike a touch, it never counts as an edge swipe.
        case scroll(TouchPhase, CGPoint)
        /// Two fingers on the lit screen, at framebuffer points.
        case pinch(TouchPhase, CGPoint, CGPoint)
        /// The user moved the hinge to this angle.
        case hinge(Double)
        /// The user pressed a hardware button, or let it go.
        case button(HardwareButton, pressed: Bool)
        /// The device shut or opened flat. `strength` is how hard it arrived, from 0 to 1.
        case sound(Sound, strength: Double)
    }

    private enum Grab {
        case none
        case touch
        case pinch
        case tilt(from: CGPoint, yaw: Double, pitch: Double)
        case fold(from: CGPoint, hinge: Double, sign: Double)
        case button(HardwareButton)
    }

    /// How the device settles after a small tilt: with a little bounce, like an object.
    private static let bounce = 0.55
    /// Degrees the device turns for each point of a drag on the background.
    private static let turn = 0.5

    /// The size of the view the pointer moves in, in points.
    var viewSize = CGSize(width: 1, height: 1)

    private var hinge = Spring(180, response: 0.55, damping: 0.9)
    private var yaw = Spring(0, response: 0.5, damping: bounce)
    private var pitch = Spring(0, response: 0.5, damping: bounce)
    private var roll = Spring(0, response: 0.45, damping: 0.8)
    /// How far in the pushed button is: 0 is out, 1 is fully in. A button travels fast.
    private var press = Spring(0, response: 0.13, damping: 0.7)
    private var pushed: HardwareButton?
    private var grab = Grab.none
    private var lastTouch: CGPoint?
    private var lastHover = -Double.infinity
    /// The finger a scroll wheel moves: where it is in the view, and when it lifts if no more steps come.
    private var wheel: (point: CGPoint, lifts: Double)?
    private var reportedHinge = 180.0
    /// False while the hinge follows the simulator, so that motion is not sent back to it.
    private var userOwnsHinge = true
    private var time = 0.0
    /// The end the hinge is at, or nil when it is between the two. The hinge starts flat.
    private var hingeEnd: Sound? = .flat
    private var lastHinge = 180.0
    /// How fast the hinge moved a moment ago, in degrees a second. A spring slows down before
    /// it arrives, so its speed at the end says little about how hard the fold was.
    private var hingeSpeed = 0.0
    /// True while the device turns back to the front from far away.
    private var comingBack = false

    /// What a press would take hold of where the pointer rests, when that is not plain to see.
    enum Hover: Equatable {
        case button(HardwareButton)
        /// The frame. A drag from there folds the device.
        case frame
    }

    /// What is under a pointer that is not pressed.
    private(set) var hovered: Hover?
    /// The two fingers of a pinch, as framebuffer points: while the user pinches, and before
    /// that while the pointer rests on the glass with Option held.
    private(set) var fingers: [CGPoint] = []

    var pose: Pose {
        Pose(hinge: hinge.value, roll: roll.value, yaw: yaw.value, pitch: pitch.value,
             press: pushed.map { .init(button: $0, depth: press.value) })
    }

    /// True while a press that began on the device is still held.
    var isDragging: Bool {
        if case .none = grab { false } else { true }
    }

    // MARK: Poses asked for from outside

    /// Animates to a hinge angle the user asked for.
    mutating func fold(to degrees: Double) {
        userOwnsHinge = true
        hinge.target = min(max(degrees, 0), 180)
    }

    /// Takes the hinge angle the simulator reports, as when an agent folds the device.
    mutating func follow(hinge degrees: Double, animated: Bool) {
        // Not while the pointer holds the device: it would move under the finger.
        guard case .none = grab else { return }
        userOwnsHinge = false
        if animated {
            hinge.target = degrees
        } else {
            // The device takes the angle at once, as at the start. It did not move there, so it makes no sound.
            hinge.hold(degrees)
            hingeEnd = Self.end(at: degrees)
            lastHinge = degrees
            hingeSpeed = 0
        }
        reportedHinge = degrees
    }

    /// Animates to a roll, in degrees, by the shorter way round.
    mutating func rotate(to degrees: Double) {
        var delta = (degrees - roll.target).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
        roll.target += delta
    }

    // MARK: Pointer

    mutating func pointerDown(at point: CGPoint, option: Bool, probe: (CGPoint) -> Probe) -> [Effect] {
        // A press while one is still held means the terminal lost the release. End the held one first.
        var effects = isDragging ? pointerUp(at: point, probe: probe) : []
        effects += liftWheelFinger()
        fingers = []
        let under = probe(point)
        if !option, let button = under.button {
            grab = .button(button)
            pushed = button
            press.target = 1
            effects.append(.button(button, pressed: true))
        } else if let glass = under.glass {
            // With Option, the pointer is one of two fingers. The other mirrors it about the middle of the screen.
            grab = option ? .pinch : .touch
            if option { fingers = Self.pinch(at: glass) }
            lastTouch = glass
            effects.append(option ? .pinch(.begin, glass, fingers[1]) : .touch(.begin, glass))
        } else if option || under.onFrame {
            // Pulling the leaf that moves closes it toward the other. Pulling the fixed leaf mirrors that.
            let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
            let onFixedLeaf = hinge.value > 90 && along(point, from: center) > 0
            userOwnsHinge = true
            grab = .fold(from: point, hinge: hinge.value, sign: onFixedLeaf ? 1 : -1)
        } else {
            // The device stops in the hand, also when it was on its way back to the front.
            yaw.hold(yaw.value)
            pitch.hold(pitch.value)
            grab = .tilt(from: point, yaw: yaw.value, pitch: pitch.value)
        }
        return effects
    }

    mutating func pointerMoved(to point: CGPoint, option: Bool = false, probe: (CGPoint) -> Probe) -> [Effect] {
        switch grab {
        case .none:
            // A little parallax toward the pointer keeps the device feeling like an object.
            lastHover = time
            let under = probe(point)
            hovered = under.button.map(Hover.button) ?? (under.onFrame ? .frame : nil)
            fingers = option ? under.glass.map(Self.pinch) ?? [] : []
            yaw.target = (Double(point.x / viewSize.width) - 0.5) * 9
            pitch.target = (Double(point.y / viewSize.height) - 0.5) * 6
        case .touch:
            guard let nearest = probe(point).nearest else { return [] }
            lastTouch = nearest
            return [.touch(.move, nearest)]
        case .pinch:
            guard let nearest = probe(point).nearest else { return [] }
            lastTouch = nearest
            fingers = Self.pinch(at: nearest)
            return [.pinch(.move, nearest, fingers[1])]
        case .tilt(let from, let startYaw, let startPitch):
            // No limit: a long drag turns the device round, and the user sees its back.
            yaw.hold(startYaw + Double(point.x - from.x) * Self.turn)
            pitch.hold(startPitch + Double(point.y - from.y) * Self.turn)
        case .fold(let from, let start, let sign):
            // The hinge crosses the device, so the fold follows the pointer along the device's width.
            let turn = roll.value * .pi / 180
            let reach = 0.5 * (abs(cos(turn)) * Double(viewSize.width) + abs(sin(turn)) * Double(viewSize.height))
            hinge.hold(min(max(start + sign * along(point, from: from) / reach * 180, 0), 180))
        case .button:
            break   // a button stays down until the pointer lets go, wherever it is
        }
        return []
    }

    mutating func pointerUp(at point: CGPoint, probe: (CGPoint) -> Probe) -> [Effect] {
        var effects: [Effect] = []
        switch grab {
        case .touch:
            if let end = probe(point).nearest ?? lastTouch { effects.append(.touch(.end, end)) }
        case .pinch:
            if let end = probe(point).nearest ?? lastTouch { effects.append(.pinch(.end, end, Self.pinch(at: end)[1])) }
            fingers = []
        case .fold:
            // Close enough to shut or flat finishes the move.
            if hinge.value < 14 { hinge.target = 0 } else if hinge.value > 166 { hinge.target = 180 }
        case .button(let button):
            press.target = 0
            effects.append(.button(button, pressed: false))
        case .tilt:
            // Back to the front by the shorter way. A small tilt bounces back. From far away,
            // the same bounce would swing the device well past the front.
            yaw.hold(Self.shorterWay(yaw.value))
            pitch.hold(Self.shorterWay(pitch.value))
            comingBack = max(abs(yaw.value), abs(pitch.value)) > 30
            yaw.damping = comingBack ? 0.95 : Self.bounce
            pitch.damping = yaw.damping
        case .none:
            break
        }
        grab = .none
        yaw.target = 0
        pitch.target = 0
        return effects
    }

    /// The pointer left the view, so the device stops turning toward it.
    mutating func pointerLeft() {
        lastHover = -.infinity
        hovered = nil
        if case .none = grab { fingers = [] }
    }

    /// One wheel step. Positive `lines` scrolls the content down, as a finger moving up does.
    mutating func wheel(at point: CGPoint, lines: Double, probe: (CGPoint) -> Probe) -> [Effect] {
        guard case .none = grab else { return [] }
        if let finger = wheel {
            let next = CGPoint(x: finger.point.x, y: finger.point.y - CGFloat(lines) * viewSize.height * 0.035)
            wheel = (next, time + 0.12)
            guard let nearest = probe(next).nearest else { return [] }
            lastTouch = nearest
            return [.scroll(.move, nearest)]
        }
        guard let glass = probe(point).glass else { return [] }
        wheel = (point, time + 0.12)
        lastTouch = glass
        return [.scroll(.begin, glass)]
    }

    // MARK: Time

    /// Advances the motion to `time`, in seconds. `moving` is true while the pose is still changing.
    mutating func step(to time: Double) -> (effects: [Effect], moving: Bool) {
        // Real elapsed time, so a late frame does not slow the motion down.
        let elapsed = min(max(time - self.time, 1.0 / 240), 0.1)
        self.time = time
        var effects: [Effect] = []
        if let finger = wheel, time >= finger.lifts { effects += liftWheelFinger() }
        if case .none = grab, time - lastHover > 1.2 {
            yaw.target = 0
            pitch.target = 0
        }
        let turning = [yaw.step(elapsed), pitch.step(elapsed)].contains(true)
        if comingBack, !turning {
            comingBack = false
            yaw.damping = Self.bounce
            pitch.damping = Self.bounce
        }
        let moving = [turning, hinge.step(elapsed), roll.step(elapsed), press.step(elapsed)].contains(true)
        // The halves stop when the hinge comes to an end. Near an end, they stay there for the ear:
        // the hinge must leave by some degrees before it can arrive again.
        hingeSpeed = max(abs(hinge.value - lastHinge) / elapsed, hingeSpeed * exp(-elapsed / 0.3))
        lastHinge = hinge.value
        if let end = Self.end(at: hinge.value) {
            if end != hingeEnd { effects.append(.sound(end, strength: min(max(hingeSpeed / 400, 0.15), 1))) }
            hingeEnd = end
        } else if hinge.value > 8, hinge.value < 172 {
            hingeEnd = nil
        }
        if press.value == 0, press.target == 0 { pushed = nil }
        if userOwnsHinge, abs(hinge.value - reportedHinge) >= 0.5 || (!moving && hinge.value != reportedHinge) {
            reportedHinge = hinge.value
            effects.append(.hinge(hinge.value))
        }
        return (effects, moving)
    }

    private mutating func liftWheelFinger() -> [Effect] {
        guard wheel != nil else { return [] }
        wheel = nil
        return lastTouch.map { [.scroll(.end, $0)] } ?? []
    }

    /// The end of the hinge's way that an angle is at, if it is at one.
    private static func end(at degrees: Double) -> Sound? {
        degrees <= 1 ? .shut : degrees >= 179 ? .flat : nil
    }

    /// The two fingers of a pinch with one of them at `point`, a framebuffer point.
    private static func pinch(at point: CGPoint) -> [CGPoint] {
        [point, CGPoint(x: 1 - point.x, y: 1 - point.y)]
    }

    /// How far `point` lies from `origin` along the device's width, which turns with the roll.
    private func along(_ point: CGPoint, from origin: CGPoint) -> Double {
        let turn = roll.value * .pi / 180
        return Double(point.x - origin.x) * cos(turn) - Double(point.y - origin.y) * sin(turn)
    }

    /// The same direction as `degrees`, as an angle from -180 to 180.
    private static func shorterWay(_ degrees: Double) -> Double {
        let turned = degrees.truncatingRemainder(dividingBy: 360)
        return turned > 180 ? turned - 360 : turned < -180 ? turned + 360 : turned
    }
}
