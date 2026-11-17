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

    /// Something to tell the simulator.
    enum Message {
        /// A finger on the lit panel, at a framebuffer point from 0 to 1.
        /// `edge` marks a system edge swipe, such as the swipe home.
        case touch(DeviceMotion.TouchPhase, x: Double, y: Double, edge: Int?)
        case fold(degrees: Double)
        case rotate(Orientation)

        /// The bytes of the socket message: a tag and a JSON object.
        var data: Data {
            let (tag, fields): (UInt8, [String: Any]) = switch self {
            case .touch(let phase, let x, let y, let edge):
                (0x03, ["type": Self.name(of: phase), "x": x, "y": y].merging(edge.map { ["edge": $0] } ?? [:]) { $1 })
            case .fold(let degrees):
                (0x0E, ["hinge": (degrees * 10).rounded() / 10])
            case .rotate(let orientation):
                (0x07, ["orientation": orientation.rawValue])
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
