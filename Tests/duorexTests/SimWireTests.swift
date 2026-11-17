import Foundation
import Testing
@testable import duorex

/// One stream record: a 4-byte length that counts the tag, the tag, and the payload.
private func record(_ tag: UInt8, _ payload: [UInt8]) -> Data {
    let length = UInt32(payload.count + 1)
    return Data([UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF), tag] + payload)
}

/// The avcC record serve-sim sent for the cover panel, captured from a live stream.
private let avcC: [UInt8] = [0x01, 0x64, 0x00, 0x33, 0xFF, 0xE1, 0x00, 0x04, 0x27, 0x64, 0x00, 0x33, 0x01, 0x00, 0x03, 0x28, 0xEE, 0x3C]

private func fields(_ message: SimWire.Message) throws -> (tag: UInt8, json: [String: Any]) {
    let data = message.data
    let json = try #require(try JSONSerialization.jsonObject(with: data.dropFirst()) as? [String: Any])
    return (data[0], json)
}

@Test func `the stream splits into the format and the pictures`() {
    var stream = SimWire.Stream()
    let bytes = record(0x04, [0xFF, 0xD8]) + record(0x01, avcC) + record(0x02, [1, 2, 3]) + record(0x03, [4, 5])
    #expect(stream.read(bytes) == [
        .format(sps: Data([0x27, 0x64, 0x00, 0x33]), pps: Data([0x28, 0xEE, 0x3C])),
        .picture(Data([1, 2, 3])),
        .picture(Data([4, 5])),
    ])
}

@Test func `a record that arrives in pieces is one record`() {
    var stream = SimWire.Stream()
    let bytes = record(0x02, Array(repeating: 7, count: 1000))
    #expect(stream.read(bytes.prefix(3)).isEmpty)
    #expect(stream.read(bytes.dropFirst(3).prefix(500)).isEmpty)
    #expect(stream.read(bytes.dropFirst(503)) == [.picture(Data(repeating: 7, count: 1000))])
}

@Test func `an empty record does not stall the stream`() {
    var stream = SimWire.Stream()
    #expect(stream.read(Data([0, 0, 0, 0]) + record(0x03, [9])) == [.picture(Data([9]))])
}

@Test func `an unknown record is passed over`() {
    var stream = SimWire.Stream()
    #expect(stream.read(record(0x7A, [1, 2]) + record(0x03, [9])) == [.picture(Data([9]))])
}

@Test func `a length no record has marks the stream as out of step`() {
    var stream = SimWire.Stream()
    #expect(stream.read(Data([0xFF, 0xFF, 0xFF, 0xFF, 0x03, 1, 2])).isEmpty)
    #expect(stream.isOutOfStep)
    // Nothing after that point can be trusted, wherever the next bytes begin.
    #expect(stream.read(record(0x03, [9])).isEmpty)
}

@Test func `the simulator's report decodes`() {
    let json = #"{"width":2007,"height":2853,"orientation":"landscape_left","hingeDegrees":130,"duoViewOrientation":"portrait"}"#
    #expect(SimWire.report(from: Data([0x82]) + Data(json.utf8)) ==
        SimWire.Report(width: 2007, orientation: "landscape_left", hingeDegrees: 130, duoViewOrientation: "portrait"))
    #expect(SimWire.report(from: Data([0x82]) + Data(#"{"width":1398,"height":2034,"orientation":"portrait"}"#.utf8)) ==
        SimWire.Report(width: 1398, orientation: "portrait"))
    #expect(SimWire.report(from: Data([0x84]) + Data(json.utf8)) == nil)
}

@Test func `a touch carries its phase, its point and its edge`() throws {
    let touch = try fields(.touch(.begin, x: 0.25, y: 0.5, edge: 3))
    #expect(touch.tag == 0x03)
    #expect(touch.json["type"] as? String == "begin")
    #expect(touch.json["x"] as? Double == 0.25)
    #expect(touch.json["edge"] as? Int == 3)
    #expect(try fields(.touch(.end, x: 0, y: 0, edge: nil)).json["edge"] == nil)
}

@Test func `a fold carries the hinge angle to a tenth of a degree`() throws {
    let fold = try fields(.fold(degrees: 129.96))
    #expect(fold.tag == 0x0E)
    #expect(fold.json["hinge"] as? Double == 130)
}

@Test func `a rotation carries serve-sim's name for the orientation`() throws {
    let turn = try fields(.rotate(.landscapeLeft))
    #expect(turn.tag == 0x07)
    #expect(turn.json["orientation"] as? String == "landscape_left")
}

@Test func `a button carries its HID usage and whether it went down or came up`() throws {
    let down = try fields(.button(.cameraControl, pressed: true))
    #expect(down.tag == 0x04)
    #expect(down.json["page"] as? Int == 65280)
    #expect(down.json["usage"] as? Int == 102)
    #expect(down.json["phase"] as? String == "down")
    let up = try fields(.button(.volumeUp, pressed: false))
    #expect(up.json["page"] as? Int == 12)
    #expect(up.json["usage"] as? Int == 233)
    #expect(up.json["phase"] as? String == "up")
}

// MARK: The event log

/// One event of the server's event stream, as serve-sim 0.1.49 sends it.
private func eventLine(_ event: String) -> Data {
    Data("data: {\"event\":\(event)}\n\n".utf8)
}

private let tapEvent = """
{"device":"D","source":"hid","kind":"tap","action":"tap","summary":"Tap 0.981,0.484","details":{"type":"tap","start":{"x":0.984,"y":0.4843},"current":{"x":0.9813,"y":0.4842},"moveCount":1,"edge":4,"screen":{"width":2007,"height":2853}},"id":183,"timestamp":"2026-11-17T19:25:28.711Z","msg":"Tap 0.981,0.484"}
"""

private func dragEvent(phase: String) -> String {
    """
    {"device":"D","source":"hid","kind":"drag","action":"drag","summary":"Drag 0.896,0.469 -> 0.406,0.458","details":{"type":"drag","phase":"\(phase)","start":{"x":0.896,"y":0.469},"current":{"x":0.406,"y":0.458},"moveCount":13,"screen":{"width":2007,"height":2853}},"id":182,"timestamp":"2026-11-17T19:25:27.161Z","msg":"Drag"}
    """
}

@Test func `the event stream tells a tap and where it began`() {
    var events = SimWire.Events()
    #expect(events.read(eventLine(tapEvent)) == [.tap(CGPoint(x: 0.984, y: 0.4843))])
}

@Test func `the event stream tells a drag twice: when it moves and when it ends`() {
    var events = SimWire.Events()
    let from = CGPoint(x: 0.896, y: 0.469), to = CGPoint(x: 0.406, y: 0.458)
    #expect(events.read(eventLine(dragEvent(phase: "move"))) == [.drag(from: from, to: to, ended: false)])
    #expect(events.read(eventLine(dragEvent(phase: "end"))) == [.drag(from: from, to: to, ended: true)])
}

@Test func `the event stream tells buttons, turns and other kinds`() {
    var events = SimWire.Events()
    let button = #"{"source":"hid","kind":"button","action":"home","summary":"Button home","details":{"button":"home","phase":"press"},"id":4}"#
    let rotate = #"{"source":"hid","kind":"rotate","action":"landscape_left","summary":"Rotate landscape_left","details":{"orientation":"landscape_left"},"id":5}"#
    let key = #"{"source":"hid","kind":"key","action":"down","summary":"Key down character","details":{"type":"down","key":"character","redacted":true},"id":6}"#
    #expect(events.read(eventLine(button) + eventLine(rotate) + eventLine(key))
        == [.button("home", phase: "press"), .rotate("landscape_left"), .other("key")])
}

@Test func `the events of the past and the heartbeats are not activities`() {
    var events = SimWire.Events()
    let past = Data(":\n\ndata: {\"events\":[\(tapEvent)]}\n\n:\n\n".utf8)
    #expect(events.read(past).isEmpty)
}

@Test func `an event that arrives in pieces is one event`() {
    var events = SimWire.Events()
    let line = eventLine(tapEvent)
    #expect(events.read(line.prefix(40)).isEmpty)
    #expect(events.read(line.dropFirst(40)) == [.tap(CGPoint(x: 0.984, y: 0.4843))])
}

@Test func `a touch that duorex sent is its own, however it ends`() {
    var sent = SimWire.Sent()
    sent.note(.touch(.begin, x: 0.3, y: 0.6, edge: nil), time: 0)
    sent.note(.touch(.move, x: 0.4, y: 0.6, edge: nil), time: 0.1)
    #expect(sent.claims(.tap(CGPoint(x: 0.3, y: 0.6)), time: 0.2) == true)
    #expect(sent.claims(.drag(from: CGPoint(x: 0.3, y: 0.6), to: CGPoint(x: 0.4, y: 0.6), ended: false), time: 0.2) == true)
    // The end of a long drag comes much later.
    #expect(sent.claims(.drag(from: CGPoint(x: 0.3, y: 0.6), to: CGPoint(x: 0.9, y: 0.6), ended: true), time: 30) == true)
}

@Test func `a touch that began somewhere else is another client's`() {
    var sent = SimWire.Sent()
    sent.note(.touch(.begin, x: 0.3, y: 0.6, edge: nil), time: 0)
    #expect(sent.claims(.tap(CGPoint(x: 0.5, y: 0.5)), time: 0.2) == false)
    // Where duorex's own touch went on to does not make a touch from there its own.
    sent.note(.touch(.move, x: 0.5, y: 0.5, edge: nil), time: 0.1)
    #expect(sent.claims(.tap(CGPoint(x: 0.5, y: 0.5)), time: 0.2) == false)
}

@Test func `a button or a turn that duorex sent is its own once`() {
    var sent = SimWire.Sent()
    sent.note(.button(.power, pressed: true), time: 0)
    sent.note(.rotate(.landscapeLeft), time: 0)
    #expect(sent.claims(.button("Power", phase: "down"), time: 0.1) == true)
    #expect(sent.claims(.rotate("landscape_left"), time: 0.1) == true)
    // The same again is from someone else: duorex sent one of each.
    #expect(sent.claims(.button("Power", phase: "down"), time: 0.2) == false)
    #expect(sent.claims(.rotate("landscape_left"), time: 0.2) == false)
    #expect(sent.claims(.button("home", phase: "press"), time: 0.2) == false)
}

@Test func `a status of the server is not an activity`() {
    var events = SimWire.Events()
    // The server also logs what it does itself, such as starting its own 3D preview.
    let renderer = #"{"source":"capture","kind":"duo.renderer","action":"start","summary":"Duo renderer started","id":7}"#
    // A finger that comes up when the log follows no touch is logged raw.
    let touch = #"{"source":"hid","kind":"touch","action":"end","summary":"Touch end 0.5,0.5","details":{"type":"end","x":0.5,"y":0.5},"id":8}"#
    #expect(events.read(eventLine(renderer) + eventLine(touch)).isEmpty)
}
