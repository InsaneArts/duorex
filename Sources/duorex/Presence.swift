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
    /// A ring is hollow. Any other mark is filled.
    var isRing = false
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
        /// A swipe is drawn again from its start to its end, because the log tells it only when it is over.
        var travel: Double { isTap ? 0 : 0.25 }
    }

    private var touches: [Touch] = []
    private var latest: (activity: SimWire.Activity, time: Double)?

    /// The size of a fingertip on the screen.
    private static let radius = 0.045
    /// Seconds the marks take to fade once the finger is up and the swipe is drawn.
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
            // One finger is told twice: when it starts to move, and when it comes up.
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

    /// The server follows one finger for a device, and does not always tell that it came up.
    /// A new touch means that the finger before it is up.
    private mutating func liftFinger() {
        touches.removeAll { $0.up == nil }
    }

    /// The marks to draw at `time`. Call it at every tick: it also forgets the touches that have faded.
    mutating func step(to time: Double) -> [Mark] {
        touches.removeAll { touch in
            if let up = touch.up { return time - up >= touch.travel + Self.fade }
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
            // The server hides which keys are typed.
            return ["key": "typing", "multi-touch": "pinch", "ca-debug": "debug option"][kind] ?? kind.replacingOccurrences(of: "-", with: " ")
        }
    }

    private static func marks(of touch: Touch, at time: Double) -> [Mark] {
        guard let up = touch.up else {
            // The finger is down: one spot, which comes in fast.
            return [Mark(point: touch.to, radius: radius, opacity: 0.95 * min((time - touch.seen) / 0.08, 1))]
        }
        let age = time - up
        func easeOut(_ share: Double) -> Double { 1 - (1 - share) * (1 - share) }
        func along(_ share: Double) -> CGPoint {
            CGPoint(x: touch.from.x + (touch.to.x - touch.from.x) * share, y: touch.from.y + (touch.to.y - touch.from.y) * share)
        }
        let progress = touch.isTap ? 1 : easeOut(min(age / touch.travel, 1))
        let spread = min(max((age - touch.travel) / fade, 0), 1)
        var marks: [Mark] = []
        if !touch.isTap {
            // The trail: small and faint at the start, larger and brighter toward the finger.
            let length = hypot(touch.to.x - touch.from.x, touch.to.y - touch.from.y)
            let count = min(max(Int(length / 0.03), 2), 24)
            for index in 0..<count {
                let share = Double(index) / Double(count - 1)
                guard share < progress else { break }
                marks.append(Mark(point: along(share), radius: radius * (0.3 + 0.4 * share), opacity: 0.7 * (0.25 + 0.75 * share) * (1 - spread)))
            }
        }
        // The finger's spot stays solid for a moment, so its colour is not lost in the screen's.
        marks.append(Mark(point: along(progress), radius: radius, opacity: 0.95 * min((1 - spread) / 0.6, 1)))
        // The finger came up: a ring spreads from where it was.
        if age >= touch.travel {
            marks.append(Mark(point: touch.to, radius: radius * (1 + 1.6 * easeOut(spread)), opacity: 0.9 * (1 - spread) * (1 - spread), isRing: true))
        }
        return marks
    }
}
