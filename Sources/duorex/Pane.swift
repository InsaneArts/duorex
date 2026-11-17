import Darwin
import Foundation
import os

nonisolated let log = Logger(subsystem: "duorex", category: "app")

/// The terminal pane duorex runs in. The terminal owns the pointer and the keyboard,
/// and reports both here: pointer positions arrive in pixels from the pane's top left.
final class Pane {
    enum Event {
        case pointer(TerminalInput.Pointer)
        case key(Character)
        case resized
    }

    struct Size: Equatable {
        var columns = 0, rows = 0
        var pixelWidth = 0, pixelHeight = 0
    }

    var onEvent: ((Event) -> Void)?
    private(set) var size = Size()

    private var original = termios()
    private var input = TerminalInput()
    private var reads: DispatchSourceRead?
    private var resizes: DispatchSourceSignal?
    private var restored = false

    /// Fails when duorex is not attached to a terminal.
    init() throws {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1, tcgetattr(STDIN_FILENO, &original) == 0 else {
            throw DuoError.terminal("duorex draws over a terminal pane. Run it inside Rex.")
        }
    }

    func start() {
        var raw = original
        cfmakeraw(&raw)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        // Alternate screen, no cursor, and pointer motion reported in pixels (1003 + 1006 + 1016).
        write("\u{1B}[?1049h\u{1B}[?25l\u{1B}[?1003h\u{1B}[?1006h\u{1B}[?1016h\u{1B}[2J")
        _ = fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK)

        let reads = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        reads.setEventHandler { [weak self] in self?.readInput() }
        reads.resume()
        self.reads = reads

        signal(SIGWINCH, SIG_IGN)
        let resizes = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        resizes.setEventHandler { [weak self] in
            self?.measure()
            self?.onEvent?(.resized)
        }
        resizes.resume()
        self.resizes = resizes
        measure()
    }

    /// Puts the terminal back the way it was. Safe to call twice.
    func restore() {
        guard !restored else { return }
        restored = true
        reads?.cancel()
        write("\u{1B}[?1016l\u{1B}[?1006l\u{1B}[?1003l\u{1B}[?25h\u{1B}[?1049l")
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

    /// Draws one line of text centered in the pane, under the device. It is dim, or in the
    /// colour of an agent's touches when `accent` is true.
    func caption(_ text: String, accent: Bool = false) {
        guard size.rows > 0 else { return }
        let column = max(1, (size.columns - text.count) / 2 + 1)
        write("\u{1B}[2J\u{1B}[\(size.rows);\(column)H\u{1B}[\(accent ? "38;2;255;102;20" : "2")m\(text)\u{1B}[0m")
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
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(STDIN_FILENO, &chunk, chunk.count)
            guard count > 0 else { break }
            bytes.append(contentsOf: chunk[..<count])
        }
        for event in input.read(bytes) {
            switch event {
            case .key(let key): onEvent?(.key(key))
            case .pointer(let pointer): onEvent?(.pointer(pointer))
            case .textArea(let width, let height):
                size.pixelWidth = width
                size.pixelHeight = height
                onEvent?(.resized)
            }
        }
    }
}
