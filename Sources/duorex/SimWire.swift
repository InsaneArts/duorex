import CoreGraphics
import SimHostKit

/// What duorex and the simulator tell each other: duorex's input, the simulator's pose, and
/// what the simulator's other clients do. simhost carries it; this file turns it into duorex's terms.
nonisolated enum SimWire {
    /// What the simulator reports about its pose.
    struct Report: Equatable {
        /// The width of the lit panel's framebuffer, in pixels. It tells which panel the report is about.
        var width: Int?
        /// How the interface is turned inside the lit panel's framebuffer.
        var orientation: String
        var hingeDegrees: Double?
        /// How the device is held. The name is serve-sim's, from when only iPhone Duo had it.
        var duoViewOrientation: String?
    }

    /// Something another client of the simulator did to it.
    /// Points are on the lit panel's framebuffer, from 0 to 1 with the origin at the top left.
    enum Activity: Equatable {
        /// A finger went down and came up in one place.
        case tap(CGPoint)
        /// A finger moves across the panel. While it is still down, `ended` is false and `to` is
        /// where it is now.
        case drag(from: CGPoint, to: CGPoint, ended: Bool)
        /// A hardware button, by the name its client gave it. The phase is "down", "up" or "press".
        case button(String, phase: String)
        /// The device was turned to an orientation, by `Orientation`'s raw value.
        case rotate(String)
        /// Anything else, by a name for that kind of action, such as "key".
        case other(String)
    }

    /// Something to tell the simulator.
    enum Message {
        /// A finger on the lit panel, at a framebuffer point from 0 to 1.
        /// `edge` marks a system edge swipe, such as the swipe home.
        case touch(DeviceMotion.TouchPhase, x: Double, y: Double, edge: Int?)
        case fold(degrees: Double)
        case rotate(Orientation)
        /// Two fingers on the lit panel, at framebuffer points from 0 to 1.
        case pinch(DeviceMotion.TouchPhase, CGPoint, CGPoint)
        /// A hardware button going down or coming up.
        case button(HardwareButton, pressed: Bool)
        /// Text to type into the app that has focus, as on a US keyboard. A line break is the return key.
        case type(String)
        /// Makes every animation on the simulator slow, or normal again.
        case slowAnimations(Bool)
        /// Tells the apps on the simulator that memory is low.
        case memoryWarning
    }

    /// Turns what the other clients do, as the host passes it on, into activities. The host tells
    /// every move of a finger, so a swipe is drawn while it happens.
    struct Activities {
        /// Where each client's finger went down, and whether it moved since.
        private var touches: [UInt32: (start: CGPoint, moved: Bool)] = [:]

        mutating func read(_ input: Wire.Input, from client: UInt32) -> Activity? {
            switch input {
            case .touch(let phase, let x, let y, _, _):
                let point = CGPoint(x: Double(x), y: Double(y))
                switch phase {
                case .down:
                    touches[client] = (point, false)
                    return .drag(from: point, to: point, ended: false)
                case .move:
                    guard let start = touches[client]?.start else { return nil }
                    touches[client]?.moved = true
                    return .drag(from: start, to: point, ended: false)
                case .up:
                    guard let touch = touches.removeValue(forKey: client) else { return nil }
                    return touch.moved ? .drag(from: touch.start, to: point, ended: true) : .tap(touch.start)
                }
            case .pinch:
                return .other("multi-touch")
            case .key, .type:
                return .other("key")
            case .fold:
                // The hinge is in the simulator's report.
                return nil
            case .orientation(let held):
                return .rotate(Orientation(held).rawValue)
            case .button(let page, let usage, let down):
                let button = HardwareButton.allCases.first { $0.usage == (Int(page), Int(usage)) }
                return .button(button?.rawValue ?? "button", phase: down ? "down" : "up")
            case .slowAnimations:
                return .other("ca-debug")
            case .memoryWarning:
                return .other("memory-warning")
            }
        }
    }
}
