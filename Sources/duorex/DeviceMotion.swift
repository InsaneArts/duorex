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
}

/// The device's pose and what the pointer does to it: touch, scroll, tilt and fold.
///
/// It is a value and takes the time as an input, so it runs the same in a window, in a test and
/// in a recording. Pointer positions are in view points with the origin at the top left. Each
/// pointer call gets a `probe` that says what the scene has under a point.
nonisolated struct DeviceMotion {
    enum TouchPhase: String {
        case begin, move, end
    }

    /// Something the motion asks of the simulator.
    enum Effect: Equatable {
        /// A finger on the lit screen, at a framebuffer point.
        case touch(TouchPhase, CGPoint)
        /// A finger that the scroll wheel moves. Unlike a touch, it never counts as an edge swipe.
        case scroll(TouchPhase, CGPoint)
        /// The user moved the hinge to this angle.
        case hinge(Double)
    }

    private enum Grab {
        case none
        case touch
        case tilt(from: CGPoint, yaw: Double, pitch: Double)
        case fold(from: CGPoint, hinge: Double, sign: Double)
    }

    /// The size of the view the pointer moves in, in points.
    var viewSize = CGSize(width: 1, height: 1)

    private var hinge = Spring(180, response: 0.55, damping: 0.9)
    private var yaw = Spring(0, response: 0.5, damping: 0.55)
    private var pitch = Spring(0, response: 0.5, damping: 0.55)
    private var roll = Spring(0, response: 0.45, damping: 0.8)
    private var grab = Grab.none
    private var lastTouch: CGPoint?
    private var lastHover = -Double.infinity
    /// The finger a scroll wheel moves: where it is in the view, and when it lifts if no more steps come.
    private var wheel: (point: CGPoint, lifts: Double)?
    private var reportedHinge = 180.0
    /// False while the hinge follows the simulator, so that motion is not sent back to it.
    private var userOwnsHinge = true
    private var time = 0.0

    var pose: Pose {
        Pose(hinge: hinge.value, roll: roll.value, yaw: yaw.value, pitch: pitch.value)
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
        if case .fold = grab { return }
        userOwnsHinge = false
        if animated { hinge.target = degrees } else { hinge.hold(degrees) }
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
        var effects = liftWheelFinger()
        let under = probe(point)
        if !option, let glass = under.glass {
            grab = .touch
            lastTouch = glass
            effects.append(.touch(.begin, glass))
        } else if option || under.onFrame {
            // Pulling the leaf that moves closes it toward the other. Pulling the fixed leaf mirrors that.
            let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
            let onFixedLeaf = hinge.value > 90 && along(point, from: center) > 0
            userOwnsHinge = true
            grab = .fold(from: point, hinge: hinge.value, sign: onFixedLeaf ? 1 : -1)
        } else {
            grab = .tilt(from: point, yaw: yaw.value, pitch: pitch.value)
        }
        return effects
    }

    mutating func pointerMoved(to point: CGPoint, probe: (CGPoint) -> Probe) -> [Effect] {
        switch grab {
        case .none:
            // A little parallax toward the pointer keeps the device feeling like an object.
            lastHover = time
            yaw.target = (Double(point.x / viewSize.width) - 0.5) * 9
            pitch.target = (Double(point.y / viewSize.height) - 0.5) * 6
        case .touch:
            guard let nearest = probe(point).nearest else { return [] }
            lastTouch = nearest
            return [.touch(.move, nearest)]
        case .tilt(let from, let startYaw, let startPitch):
            yaw.hold(rubberBand(startYaw + Double(point.x - from.x) * 0.35, limit: 55))
            pitch.hold(rubberBand(startPitch + Double(point.y - from.y) * 0.35, limit: 35))
        case .fold(let from, let start, let sign):
            // The hinge crosses the device, so the fold follows the pointer along the device's width.
            let turn = roll.value * .pi / 180
            let reach = 0.5 * (abs(cos(turn)) * Double(viewSize.width) + abs(sin(turn)) * Double(viewSize.height))
            hinge.hold(min(max(start + sign * along(point, from: from) / reach * 180, 0), 180))
        }
        return []
    }

    mutating func pointerUp(at point: CGPoint, probe: (CGPoint) -> Probe) -> [Effect] {
        var effects: [Effect] = []
        switch grab {
        case .touch:
            if let end = probe(point).nearest ?? lastTouch { effects.append(.touch(.end, end)) }
        case .fold:
            // Close enough to shut or flat finishes the move.
            if hinge.value < 14 { hinge.target = 0 } else if hinge.value > 166 { hinge.target = 180 }
        case .tilt, .none:
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
        let moving = [hinge.step(elapsed), yaw.step(elapsed), pitch.step(elapsed), roll.step(elapsed)].contains(true)
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

    /// How far `point` lies from `origin` along the device's width, which turns with the roll.
    private func along(_ point: CGPoint, from origin: CGPoint) -> Double {
        let turn = roll.value * .pi / 180
        return Double(point.x - origin.x) * cos(turn) - Double(point.y - origin.y) * sin(turn)
    }

    /// Lets a drag go past `limit` with growing resistance.
    private func rubberBand(_ value: Double, limit: Double) -> Double {
        let over = abs(value) - limit
        guard over > 0 else { return value }
        return (value < 0 ? -1 : 1) * (limit + limit * 0.5 * (1 - 1 / (over / limit + 1)))
    }
}
