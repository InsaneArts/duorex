/// Turns the bytes a terminal sends into keys, pointer reports and size reports.
///
/// The bytes arrive in whatever pieces the terminal writes them. A report that is cut in two
/// waits here for its other half, so its digits are never taken for key presses.
nonisolated struct TerminalInput {
    struct Pointer: Equatable {
        enum Kind: Equatable {
            case down, up, move, drag
            /// One wheel step. Positive scrolls the content down.
            case wheel(lines: Double)
        }

        var kind: Kind
        /// Pixels from the pane's top left corner.
        var x: Double, y: Double
        var option: Bool
    }

    enum Event: Equatable {
        case key(Character)
        case pointer(Pointer)
        /// The terminal's answer to a size query: its text area in pixels.
        case textArea(width: Int, height: Int)
    }

    private var pending: [UInt8] = []

    mutating func read(_ bytes: some Sequence<UInt8>) -> [Event] {
        pending.append(contentsOf: bytes)
        var events: [Event] = []
        var index = 0
        while index < pending.count {
            guard pending[index] == 0x1B else {
                // Plain bytes are keys. Multi-byte characters are not needed for shortcuts.
                if pending[index] < 0x80 { events.append(.key(Character(UnicodeScalar(pending[index])))) }
                index += 1
                continue
            }
            // An escape starts a sequence. If the rest has not arrived, wait for it.
            guard index + 1 < pending.count else { break }
            if pending[index + 1] == UInt8(ascii: "O") {
                // A function or cursor key: escape, O and one letter. Not used.
                guard index + 2 < pending.count else { break }
                index += 3
                continue
            }
            guard pending[index + 1] == UInt8(ascii: "[") else {
                index += 2   // an Alt chord: not used
                continue
            }
            // A control sequence runs to its final byte, 0x40...0x7E.
            guard let end = pending[(index + 2)...].firstIndex(where: { (0x40...0x7E).contains($0) }) else {
                // No real sequence is this long, so this one is noise.
                if pending.count - index > 64 { index = pending.count }
                break
            }
            if let event = Self.control(String(decoding: pending[(index + 2)..<end], as: UTF8.self), final: pending[end]) {
                events.append(event)
            }
            index = end + 1
        }
        pending.removeFirst(index)
        return events
    }

    private static func control(_ body: String, final: UInt8) -> Event? {
        switch final {
        case UInt8(ascii: "t"):
            // "4;height;width": the answer to CSI 14 t.
            let parts = body.split(separator: ";").compactMap { Int($0) }
            guard parts.count == 3, parts[0] == 4 else { return nil }
            return .textArea(width: parts[2], height: parts[1])
        case UInt8(ascii: "M"), UInt8(ascii: "m"):
            // "<code;x;y": an SGR pointer report. With mode 1016 the position is in pixels.
            guard body.hasPrefix("<") else { return nil }
            let parts = body.dropFirst().split(separator: ";").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            let code = parts[0]
            let kind: Pointer.Kind
            if code & 64 != 0 {
                guard code & 3 < 2 else { return nil }   // horizontal wheel: not used
                kind = .wheel(lines: code & 3 == 0 ? -1 : 1)
            } else if code & 32 != 0 {
                kind = code & 3 == 3 ? .move : .drag
            } else {
                guard code & 3 == 0 else { return nil }  // left button only
                kind = final == UInt8(ascii: "M") ? .down : .up
            }
            return .pointer(Pointer(kind: kind, x: Double(parts[1]), y: Double(parts[2]), option: code & 8 != 0))
        default:
            return nil
        }
    }
}
