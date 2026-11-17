import Foundation

/// serve-sim's wire format, release 0.1.x: tagged records on the screen stream and tagged JSON
/// on the input socket. It is not a public format, so every byte of it is kept in this file.
nonisolated enum SimWire {
    /// One record of the screen stream.
    enum Record: Equatable {
        /// The decoder's parameter sets. A new one arrives when the lit panel changes.
        case format(sps: Data, pps: Data)
        /// One H.264 picture, as NAL units with 4-byte lengths.
        case picture(Data)
    }

    /// Splits the screen stream into records. The stream is a run of
    /// `[length: UInt32 big endian][tag: UInt8][payload]`, where the length counts the tag.
    struct Stream {
        private var pending = Data()
        /// True once a length made no sense. The stream has lost its place in the bytes, so
        /// nothing after that point can be read. Only a new connection starts clean.
        private(set) var isOutOfStep = false

        mutating func read(_ bytes: Data) -> [Record] {
            guard !isOutOfStep else { return [] }
            pending.append(bytes)
            var records: [Record] = []
            var offset = pending.startIndex
            while pending.endIndex - offset >= 4 {
                let length = pending[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
                // No record is this large.
                guard length <= 64_000_000 else {
                    isOutOfStep = true
                    pending.removeAll()
                    return records
                }
                guard pending.endIndex - offset >= 4 + length else { break }
                if length >= 1 {
                    let payload = Data(pending[(offset + 5)..<(offset + 4 + length)])
                    switch pending[offset + 4] {
                    case 0x01: if let format = Self.format(avcC: payload) { records.append(format) }
                    case 0x02, 0x03: records.append(.picture(payload))
                    default: break   // 0x04 is a JPEG of the screen, sent before the first picture
                    }
                }
                offset += 4 + length
            }
            pending.removeSubrange(pending.startIndex..<offset)
            return records
        }

        /// An avcC record holds one SPS and one PPS, each behind a 2-byte length.
        private static func format(avcC: Data) -> Record? {
            let bytes = [UInt8](avcC)
            guard bytes.count > 8 else { return nil }
            let spsLength = Int(bytes[6]) << 8 | Int(bytes[7])
            let ppsStart = 8 + spsLength + 3
            guard bytes.count >= ppsStart else { return nil }
            let ppsLength = Int(bytes[ppsStart - 2]) << 8 | Int(bytes[ppsStart - 1])
            guard spsLength > 0, ppsLength > 0, bytes.count >= ppsStart + ppsLength else { return nil }
            return .format(sps: Data(bytes[8..<8 + spsLength]), pps: Data(bytes[ppsStart..<ppsStart + ppsLength]))
        }
    }

    /// What the simulator reports about its pose.
    struct Report: Decodable, Equatable {
        /// The width of the lit panel's framebuffer, in pixels. It tells which panel the report is about.
        var width: Int?
        /// How the interface is turned inside the lit panel's framebuffer.
        var orientation: String
        var hingeDegrees: Double?
        /// How the device is held.
        var duoViewOrientation: String?
    }

    /// The report in a socket message, or nil when the message is something else.
    static func report(from message: Data) -> Report? {
        guard message.first == 0x82 else { return nil }
        return try? JSONDecoder().decode(Report.self, from: message.dropFirst())
    }

    /// Something a client of the server did to the simulator, as the server's event log tells it.
    /// Points are on the lit panel's framebuffer, from 0 to 1 with the origin at the top left.
    enum Activity: Equatable {
        /// A finger went down and came up in one place.
        case tap(CGPoint)
        /// A finger moves across the panel. While it is still down, `ended` is false and `to` is
        /// where it was when the server first saw it move.
        case drag(from: CGPoint, to: CGPoint, ended: Bool)
        /// A hardware button, by the name its client gave it. The phase is "down", "up" or "press".
        case button(String, phase: String)
        /// The device was turned to an orientation, by serve-sim's name for it.
        case rotate(String)
        /// Anything else, by the server's name for that kind of action, such as "key".
        case other(String)
    }

    /// Splits the server's event stream into activities. The stream is server-sent events: one
    /// "data: " line of JSON for each event, after one such line that holds the events of the past.
    struct Events {
        private var pending = Data()

        mutating func read(_ bytes: Data) -> [Activity] {
            pending.append(bytes)
            var activities: [Activity] = []
            while let end = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<end]
                pending.removeSubrange(pending.startIndex...end)
                guard line.starts(with: Data("data: ".utf8)),
                      let message = try? JSONSerialization.jsonObject(with: line.dropFirst(6)) as? [String: Any],
                      let event = message["event"] as? [String: Any],
                      let activity = Self.activity(from: event) else { continue }
                activities.append(activity)
            }
            return activities
        }

        private static func activity(from event: [String: Any]) -> Activity? {
            // "hid" is input to the simulator. The log also holds what the server does itself.
            guard event["source"] as? String == "hid", let kind = event["kind"] as? String else { return nil }
            let details = event["details"] as? [String: Any] ?? [:]
            func point(_ name: String) -> CGPoint? {
                guard let value = details[name] as? [String: Any], let x = value["x"] as? Double, let y = value["y"] as? Double else { return nil }
                return CGPoint(x: x, y: y)
            }
            switch kind {
            case "tap":
                return point("start").map { .tap($0) }
            case "drag":
                guard let from = point("start"), let to = point("current") else { return nil }
                return .drag(from: from, to: to, ended: details["phase"] as? String == "end")
            case "button":
                return .button(event["action"] as? String ?? "", phase: details["phase"] as? String ?? "press")
            case "rotate":
                return .rotate(event["action"] as? String ?? "")
            case "touch":
                // A part of a touch that the log could not join to a whole one. It tells nothing by itself.
                return nil
            default:
                return .other(kind)
            }
        }
    }

    /// Remembers what this duorex sent. The event log tells every client's actions alike, so
    /// duorex's own come back in it with the others'.
    struct Sent {
        /// Where this duorex's touches began, each with the time its finger came up. A touch in
        /// the log is known by the point it began at.
        private var begins: [(point: CGPoint, up: Double?)] = []
        /// The last points this duorex's finger moved to or came up at, each with its time.
        private var moves: [(point: CGPoint, time: Double)] = []
        private var others: [(activity: Activity, time: Double)] = []

        mutating func note(_ message: Message, time: Double) {
            switch message {
            case .touch(let phase, let x, let y, _):
                switch phase {
                case .begin:
                    begins.append((CGPoint(x: x, y: y), nil))
                    if begins.count > 16 { begins.removeFirst() }
                case .move, .end:
                    moves.append((CGPoint(x: x, y: y), time))
                    if moves.count > 64 { moves.removeFirst() }
                    if phase == .end {
                        for index in begins.indices where begins[index].up == nil { begins[index].up = time }
                    }
                }
            case .button(let button, let pressed):
                others.append((.button(button.rawValue, phase: pressed ? "down" : "up"), time))
            case .rotate(let orientation):
                others.append((.rotate(orientation.rawValue), time))
            case .pinch:
                others.append((.other("multi-touch"), time))   // the log has an entry for each part of a pinch
            case .slowAnimations:
                others.append((.other("ca-debug"), time))
            case .memoryWarning:
                others.append((.other("memory-warning"), time))
            case .fold:
                break   // the log has no entry for a fold
            }
        }

        /// Whether an activity from the log is one that this duorex sent. Call it once for each activity.
        mutating func claims(_ activity: Activity, time: Double) -> Bool {
            func same(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6 }
            switch activity {
            case .tap(let start), .drag(let start, _, _):
                // The log's entry for a touch comes a moment after the touch. Later, its points are free again.
                begins.removeAll { touch in touch.up.map { time - $0 > 2 } ?? false }
                moves.removeAll { time - $0.time > 2 }
                if begins.contains(where: { same($0.point, start) }) { return true }
                // The server follows one touch for a device, whoever sends it. So another client's
                // touch ends this duorex's in the log, and two things follow. The log starts a
                // new touch where this duorex's finger moves next.
                if moves.contains(where: { same($0.point, start) }) {
                    begins.append((start, nil))
                    return true
                }
                // And a touch of the other client becomes a drag when this duorex's finger moves:
                // that drag goes to the finger.
                if case .drag(_, let to, _) = activity { return moves.contains { same($0.point, to) } }
                return false
            case .button, .rotate, .other:
                others.removeAll { time - $0.time > 5 }
                guard let index = others.firstIndex(where: { $0.activity == activity }) else { return false }
                others.remove(at: index)
                return true
            }
        }
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
        /// Makes every animation on the simulator slow, or normal again.
        case slowAnimations(Bool)
        /// Tells the apps on the simulator that memory is low.
        case memoryWarning

        /// The bytes of the socket message: a tag and a JSON object.
        var data: Data {
            let (tag, fields): (UInt8, [String: Any]) = switch self {
            case .touch(let phase, let x, let y, let edge):
                (0x03, ["type": Self.name(of: phase), "x": x, "y": y].merging(edge.map { ["edge": $0] } ?? [:]) { $1 })
            case .pinch(let phase, let first, let second):
                (0x05, ["type": Self.name(of: phase), "x1": first.x, "y1": first.y, "x2": second.x, "y2": second.y])
            case .fold(let degrees):
                (0x0E, ["hinge": (degrees * 10).rounded() / 10])
            case .rotate(let orientation):
                (0x07, ["orientation": orientation.rawValue])
            case .button(let button, let pressed):
                (0x04, ["button": button.rawValue, "page": button.usage.page, "usage": button.usage.usage, "phase": pressed ? "down" : "up"])
            case .slowAnimations(let slow):
                (0x08, ["option": "debug_slow_animations", "enabled": slow])
            case .memoryWarning:
                (0x09, [:])
            }
            return Data([tag]) + ((try? JSONSerialization.data(withJSONObject: fields)) ?? Data())
        }

        private static func name(of phase: DeviceMotion.TouchPhase) -> String {
            switch phase {
            case .begin: "begin"
            case .move: "move"
            case .end: "end"
            }
        }
    }
}
