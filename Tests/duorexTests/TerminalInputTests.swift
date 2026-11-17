import Testing
@testable import duorex

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

@Test func `plain bytes are keys`() {
    var input = TerminalInput()
    #expect(input.read(bytes("q2")) == [.key("q"), .key("2")])
}

@Test func `a pointer report gives the position in pixels`() {
    var input = TerminalInput()
    let move = TerminalInput.Pointer(kind: .move, x: 410, y: 22, option: false)
    #expect(input.read(bytes("\u{1B}[<35;410;22M")) == [.pointer(move)])
    #expect(input.read(bytes("\u{1B}[<0;5;6M\u{1B}[<0;5;6m")) == [
        .pointer(.init(kind: .down, x: 5, y: 6, option: false)),
        .pointer(.init(kind: .up, x: 5, y: 6, option: false)),
    ])
    #expect(input.read(bytes("\u{1B}[<40;5;6M")) == [.pointer(.init(kind: .drag, x: 5, y: 6, option: true))])
    #expect(input.read(bytes("\u{1B}[<65;5;6M")) == [.pointer(.init(kind: .wheel(lines: 1), x: 5, y: 6, option: false))])
}

@Test func `a report cut in two is one report, not key presses`() {
    var input = TerminalInput()
    // The digits 1, 2 and 3 are pose keys and [ folds the device, so reading them as keys moves it.
    #expect(input.read(bytes("\u{1B}")).isEmpty)
    #expect(input.read(bytes("[<35;12")).isEmpty)
    #expect(input.read(bytes("3;45Mq")) == [.pointer(.init(kind: .move, x: 123, y: 45, option: false)), .key("q")])
}

@Test func `the answer to a size query is the text area in pixels`() {
    var input = TerminalInput()
    #expect(input.read(bytes("\u{1B}[4;1192;1592t")) == [.textArea(width: 1592, height: 1192)])
}

@Test func `sequences duorex does not use are skipped`() {
    var input = TerminalInput()
    #expect(input.read(bytes("\u{1B}[A\u{1B}[I\u{1B}OP\u{1B}x")) == [])
    #expect(input.read(bytes("\u{1B}[<2;5;6Mh")) == [.key("h")])
}

@Test func `noise after an escape does not swallow what follows forever`() {
    var input = TerminalInput()
    #expect(input.read(bytes("\u{1B}[" + String(repeating: "9", count: 100))).isEmpty)
    #expect(input.read(bytes("q")) == [.key("q")])
}

@Test func `an Esc key press does not turn the next report into keys`() {
    var input = TerminalInput()
    #expect(input.read(bytes("\u{1B}")).isEmpty)
    #expect(input.read(bytes("\u{1B}[<35;410;22M")) == [.pointer(.init(kind: .move, x: 410, y: 22, option: false))])
}

@Test func `a key pressed after Esc still counts`() {
    var input = TerminalInput()
    #expect(input.read(bytes("\u{1B}")).isEmpty)
    #expect(input.read(bytes("q")) == [.key("q")])
}
