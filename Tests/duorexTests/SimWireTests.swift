import CoreGraphics
import SimHostKit
import Testing
@testable import duorex

private let agent: UInt32 = 2

private func touch(_ phase: Wire.Phase, _ x: Float, _ y: Float) -> Wire.Input {
    .touch(phase, x: x, y: y, screen: .duoCover, edge: 0)
}

@Test func `a finger shows as soon as it goes down`() {
    var activities = SimWire.Activities()
    #expect(activities.read(touch(.down, 0.25, 0.5), from: agent) == .drag(from: CGPoint(x: 0.25, y: 0.5), to: CGPoint(x: 0.25, y: 0.5), ended: false))
}

@Test func `a finger that comes up without moving is a tap`() {
    var activities = SimWire.Activities()
    _ = activities.read(touch(.down, 0.25, 0.5), from: agent)
    #expect(activities.read(touch(.up, 0.25, 0.5), from: agent) == .tap(CGPoint(x: 0.25, y: 0.5)))
}

@Test func `every move of a finger is a drag from where it went down`() {
    var activities = SimWire.Activities()
    let start = CGPoint(x: 0.5, y: 0.875)
    _ = activities.read(touch(.down, 0.5, 0.875), from: agent)
    #expect(activities.read(touch(.move, 0.5, 0.625), from: agent) == .drag(from: start, to: CGPoint(x: 0.5, y: 0.625), ended: false))
    #expect(activities.read(touch(.move, 0.5, 0.375), from: agent) == .drag(from: start, to: CGPoint(x: 0.5, y: 0.375), ended: false))
    #expect(activities.read(touch(.up, 0.5, 0.25), from: agent) == .drag(from: start, to: CGPoint(x: 0.5, y: 0.25), ended: true))
}

@Test func `each client's finger is its own`() {
    var activities = SimWire.Activities()
    _ = activities.read(touch(.down, 0.25, 0.25), from: agent)
    _ = activities.read(touch(.down, 0.75, 0.75), from: agent + 1)
    #expect(activities.read(touch(.up, 0.25, 0.25), from: agent) == .tap(CGPoint(x: 0.25, y: 0.25)))
    #expect(activities.read(touch(.move, 0.75, 0.5), from: agent + 1) == .drag(from: CGPoint(x: 0.75, y: 0.75), to: CGPoint(x: 0.75, y: 0.5), ended: false))
}

@Test func `a finger that was never seen going down tells nothing`() {
    var activities = SimWire.Activities()
    #expect(activities.read(touch(.move, 0.5, 0.5), from: agent) == nil)
    #expect(activities.read(touch(.up, 0.5, 0.5), from: agent) == nil)
}

@Test func `a button is told by its name and whether it went down or came up`() {
    var activities = SimWire.Activities()
    #expect(activities.read(.button(page: 12, usage: 233, down: true), from: agent) == .button("Volume up", phase: "down"))
    #expect(activities.read(.button(page: 65280, usage: 102, down: false), from: agent) == .button("Camera control", phase: "up"))
}

@Test func `a turn is told by duorex's name for the orientation`() {
    var activities = SimWire.Activities()
    #expect(activities.read(.orientation(.landscapeLeft), from: agent) == .rotate("landscape_left"))
    #expect(activities.read(.orientation(.upsideDown), from: agent) == .rotate("portrait_upside_down"))
}

@Test func `a fold is in the report, not an activity`() {
    var activities = SimWire.Activities()
    #expect(activities.read(.fold(degrees: 130, milliseconds: 0), from: agent) == nil)
}

@Test func `typing, pinches and debug messages are other kinds`() {
    var activities = SimWire.Activities()
    #expect(activities.read(.type("hello"), from: agent) == .other("key"))
    #expect(activities.read(.key(usage: 40, down: true), from: agent) == .other("key"))
    #expect(activities.read(.pinch(.move, x1: 0, y1: 0, x2: 1, y2: 1, screen: .duoInner), from: agent) == .other("multi-touch"))
    #expect(activities.read(.slowAnimations(true), from: agent) == .other("ca-debug"))
    #expect(activities.read(.memoryWarning, from: agent) == .other("memory-warning"))
}

@Test(arguments: duorex.Orientation.allCases) func `orientations keep their meaning between duorex and simhost`(_ orientation: duorex.Orientation) {
    #expect(duorex.Orientation(SimHostKit.Orientation(orientation)) == orientation)
}
