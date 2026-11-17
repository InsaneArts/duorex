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
