import Darwin
import Foundation
import os

nonisolated let log = Logger(subsystem: "duorex", category: "app")

/// The terminal pane duorex runs in. The terminal owns the pointer and the keyboard,
/// and reports both here: pointer positions arrive in pixels from the pane's top left.
final class Pane {
    struct Pointer {
        enum Kind { case down, up, move, drag, wheel(lines: Double) }
        var kind: Kind
        /// Pixels from the pane's top left corner.
        var x: Double, y: Double
        var option: Bool
    }

    enum Event {
        case pointer(Pointer)
        case key(Character)
        case focus(Bool)
        case resized
    }

    struct Size: Equatable {
        var columns = 0, rows = 0
        var pixelWidth = 0, pixelHeight = 0
    }

    var onEvent: ((Event) -> Void)?
    private(set) var size = Size()

    private var original = termios()
    private var input: DispatchSourceRead?
    private var resize: DispatchSourceSignal?
    private var buffer = [UInt8]()
    private var restored = false

    /// Fails when duorex is not attached to a terminal.
    init() throws {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1, tcgetattr(STDIN_FILENO, &original) == 0 else {
            throw DuoError.sim("duorex draws over a terminal pane. Run it inside Rex.")
        }
    }

    func start() {
        var raw = original
        cfmakeraw(&raw)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        // Alternate screen, no cursor, pointer motion in pixels (1003 + 1006 + 1016), focus reports.
        write("\u{1B}[?1049h\u{1B}[?25l\u{1B}[?1003h\u{1B}[?1006h\u{1B}[?1016h\u{1B}[?1004h\u{1B}[2J")
        _ = fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK)

        let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        input.setEventHandler { [weak self] in self?.readInput() }
        input.resume()
        self.input = input

        signal(SIGWINCH, SIG_IGN)
        let resize = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        resize.setEventHandler { [weak self] in
            self?.measure()
            self?.onEvent?(.resized)
        }
        resize.resume()
        self.resize = resize
        measure()
    }

    /// Puts the terminal back the way it was. Safe to call twice.
    func restore() {
        guard !restored else { return }
        restored = true
        input?.cancel()
        write("\u{1B}[?1004l\u{1B}[?1016l\u{1B}[?1006l\u{1B}[?1003l\u{1B}[?25h\u{1B}[?1049l")
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
    }

    func write(_ text: String) {
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
            guard written > 0 else {
                if errno == EAGAIN || errno == EINTR { usleep(1000); continue }
                return
            }
            bytes = bytes.dropFirst(written)
        }
    }

    /// Draws one dim line of text centered in the pane, under the device.
    func caption(_ text: String) {
        guard size.rows > 0 else { return }
        let column = max(1, (size.columns - text.count) / 2 + 1)
        write("\u{1B}[2J\u{1B}[\(size.rows);\(column)H\u{1B}[2m\(text)\u{1B}[0m")
    }

    private func measure() {
        var window = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &window) == 0 else { return }
        size.columns = Int(window.ws_col)
        size.rows = Int(window.ws_row)
        if window.ws_xpixel > 0, window.ws_ypixel > 0 {
            size.pixelWidth = Int(window.ws_xpixel)
            size.pixelHeight = Int(window.ws_ypixel)
        } else {
            write("\u{1B}[14t")   // the terminal answers with its text area size in pixels
        }
    }

    private func readInput() {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(STDIN_FILENO, &chunk, chunk.count)
            guard count > 0 else { break }
            buffer.append(contentsOf: chunk[..<count])
        }
        parse()
    }

    private func parse() {
        var index = 0
        while index < buffer.count {
            guard buffer[index] == 0x1B else {
                // Plain bytes are keys. Multi-byte characters are not needed for shortcuts.
                if buffer[index] < 0x80 { onEvent?(.key(Character(UnicodeScalar(buffer[index])))) }
                index += 1
                continue
            }
            guard index + 1 < buffer.count else {
                onEvent?(.key("\u{1B}"))
                index += 1
                continue
            }
            guard buffer[index + 1] == UInt8(ascii: "[") else {
                index += 2   // an Alt chord or an SS3 key: not used
                continue
            }
            // A control sequence runs to its final byte, 0x40...0x7E.
            guard let end = buffer[(index + 2)...].firstIndex(where: { (0x40...0x7E).contains($0) }) else { break }
            let body = String(decoding: buffer[(index + 2)..<end], as: UTF8.self)
            control(body, final: buffer[end])
            index = end + 1
        }
        buffer.removeFirst(min(index, buffer.count))
    }

    private func control(_ body: String, final: UInt8) {
        switch final {
        case UInt8(ascii: "I"): onEvent?(.focus(true))
        case UInt8(ascii: "O"): onEvent?(.focus(false))
        case UInt8(ascii: "t"):
            let parts = body.split(separator: ";").compactMap { Int($0) }
            guard parts.count == 3, parts[0] == 4 else { return }
            size.pixelHeight = parts[1]
            size.pixelWidth = parts[2]
            onEvent?(.resized)
        case UInt8(ascii: "M"), UInt8(ascii: "m"):
            guard body.hasPrefix("<") else { return }
            let parts = body.dropFirst().split(separator: ";").compactMap { Int($0) }
            guard parts.count == 3 else { return }
            let code = parts[0]
            let kind: Pointer.Kind
            if code & 64 != 0 {
                guard code & 3 < 2 else { return }   // horizontal wheel: not used
                kind = .wheel(lines: code & 3 == 0 ? -1 : 1)
            } else if code & 32 != 0 {
                kind = code & 3 == 3 ? .move : .drag
            } else {
                guard code & 3 == 0 else { return }  // left button only
                kind = final == UInt8(ascii: "M") ? .down : .up
            }
            onEvent?(.pointer(Pointer(kind: kind, x: Double(parts[1]), y: Double(parts[2]), option: code & 8 != 0)))
        default:
            break
        }
    }
}
