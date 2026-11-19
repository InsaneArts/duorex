import CoreGraphics
import Foundation

/// A spot of light on the lit screen.
nonisolated struct Mark: Equatable {
    /// Where its middle is on the framebuffer, from 0 to 1 with the origin at the top left.
    var point: CGPoint
    /// Its radius, as a share of the screen's shorter side.
    var radius: Double
    /// 0 is invisible, 1 is solid.
    var opacity: Double
    var look = Look.spot

    enum Look {
        /// Another client's finger: a filled spot in the colour of an agent.
        case spot
        /// The ring that spreads where another client's finger came up.
        case ring
        /// One of the user's own two fingers in a pinch: a pale spot.
        case finger
    }
}

/// What another client of the simulator does, shown on the device. Most of the time the other
/// client is an agent.
///
/// A touch leaves marks on the screen where it lands, and they fade away. It is a value and
/// takes the time as an input, like `DeviceMotion`.
nonisolated struct Presence {
    private struct Touch {
        var from: CGPoint
        var to: CGPoint
        /// When the finger was first seen.
        var seen: Double
        /// When the finger came up. Nil while it is still down.
        var up: Double?

        var isTap: Bool { from == to }
    }

    private var touches: [Touch] = []
    private var latest: (activity: SimWire.Activity, time: Double)?

    /// The size of a fingertip on the screen, as a share of its shorter side.
    static let radius = 0.045
    /// Seconds the marks take to fade once the finger is up.
    private static let fade = 0.45
    /// Seconds a finger can stay down. After that, the report of its end was lost.
    private static let longestHold = 8.0
    /// Seconds an action stays in the caption.
    private static let attention = 2.5

    /// Takes something another client did, at `time` in seconds.
    mutating func saw(_ activity: SimWire.Activity, time: Double) {
        latest = (activity, time)
        switch activity {
        case .tap(let point):
            liftFinger()
            touches.append(Touch(from: point, to: point, seen: time, up: time))
        case .drag(let from, let to, let ended):
            // One finger is told at each move, from where it went down.
            if let index = touches.firstIndex(where: { $0.up == nil && $0.from == from }) {
                touches[index].to = to
                if ended { touches[index].up = time }
            } else {
                liftFinger()
                touches.append(Touch(from: from, to: to, seen: time, up: ended ? time : nil))
            }
        case .button, .rotate, .other:
            break
        }
    }

    /// The device shows one other finger at a time. A new touch means that the finger before it is up.
    private mutating func liftFinger() {
        touches.removeAll { $0.up == nil }
    }

    /// The marks to draw at `time`. Call it at every tick: it also forgets the touches that have faded.
    mutating func step(to time: Double) -> [Mark] {
        touches.removeAll { touch in
            if let up = touch.up { return time - up >= Self.fade }
            return time - touch.seen >= Self.longestHold
        }
        return touches.flatMap { Self.marks(of: $0, at: time) }
    }

    /// What the other client does now, or nil when it has done nothing for a moment.
    func current(at time: Double) -> SimWire.Activity? {
        guard let latest, time - latest.time < Self.attention || touches.contains(where: { $0.up == nil }) else { return nil }
        return latest.activity
    }

    /// A few words for an activity, such as "swipe ↑". `interface` is how the interface is turned
    /// inside the framebuffer, so the arrow points the way the user sees the finger move.
    static func words(for activity: SimWire.Activity, interface: Orientation) -> String {
        switch activity {
        case .tap:
            return "tap"
        case .drag(let from, let to, _):
            let start = interface.interfacePoint(from), end = interface.interfacePoint(to)
            let across = end.x - start.x, down = end.y - start.y
            return "swipe " + (abs(across) > abs(down) ? (across > 0 ? "→" : "←") : (down > 0 ? "↓" : "↑"))
        case .button(let name, _):
            return "\(name) button"
        case .rotate:
            return "rotate"
        case .other(let kind):
            // The host tells what is typed, but the caption does not show it: it can be a password.
            return ["key": "typing", "multi-touch": "pinch", "ca-debug": "debug option"][kind] ?? kind.replacingOccurrences(of: "-", with: " ")
        }
    }

    /// The marks of one finger. The host tells each move as it happens, so the trail follows the
    /// finger while it is down, and fades with the ring once it is up.
    private static func marks(of touch: Touch, at time: Double) -> [Mark] {
        func easeOut(_ share: Double) -> Double { 1 - (1 - share) * (1 - share) }
        func along(_ share: Double) -> CGPoint {
            CGPoint(x: touch.from.x + (touch.to.x - touch.from.x) * share, y: touch.from.y + (touch.to.y - touch.from.y) * share)
        }
        // 0 while the finger is down. Once it is up, it goes to 1 as the marks fade.
        let spread = touch.up.map { min(max((time - $0) / fade, 0), 1) } ?? 0
        var marks: [Mark] = []
        if !touch.isTap {
            // The trail: small and faint at the start, larger and brighter toward the finger.
            let length = hypot(touch.to.x - touch.from.x, touch.to.y - touch.from.y)
            let count = min(max(Int(length / 0.03), 2), 24)
            for index in 0..<(count - 1) {
                let share = Double(index) / Double(count - 1)
                marks.append(Mark(point: along(share), radius: radius * (0.3 + 0.4 * share), opacity: 0.7 * (0.25 + 0.75 * share) * (1 - spread)))
            }
        }
        if touch.up == nil {
            // The finger is down: its spot comes in fast.
            marks.append(Mark(point: touch.to, radius: radius, opacity: 0.95 * min((time - touch.seen) / 0.08, 1)))
        } else {
            // The finger's spot stays solid for a moment, so its colour is not lost in the screen's.
            marks.append(Mark(point: touch.to, radius: radius, opacity: 0.95 * min((1 - spread) / 0.6, 1)))
            // The finger came up: a ring spreads from where it was.
            marks.append(Mark(point: touch.to, radius: radius * (1 + 1.6 * easeOut(spread)), opacity: 0.9 * (1 - spread) * (1 - spread), look: .ring))
        }
        return marks
    }
}
