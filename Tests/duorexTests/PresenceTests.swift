import CoreGraphics
import Testing
@testable import duorex

private let here = CGPoint(x: 0.3, y: 0.6)
private let there = CGPoint(x: 0.8, y: 0.2)

@Test func `a tap leaves a spot and a ring that spreads, and both fade away`() {
    var presence = Presence()
    presence.saw(.tap(here), time: 10)
    let early = presence.step(to: 10.05), late = presence.step(to: 10.4)
    #expect(early.map(\.point) == [here, here])
    #expect(early.map(\.look) == [.spot, .ring])
    // The ring grows and fades. The spot keeps its size.
    #expect(late[1].radius > early[1].radius)
    #expect(late[1].opacity < early[1].opacity)
    #expect(late[0].radius == early[0].radius)
    #expect(late[0].opacity < early[0].opacity)
    #expect(presence.step(to: 10.5).isEmpty)
}

@Test func `a finger that is down and has not moved shows as one spot`() {
    var presence = Presence()
    presence.saw(.drag(from: here, to: here, ended: false), time: 10)
    #expect(presence.step(to: 13) == [Mark(point: here, radius: 0.045, opacity: 0.95)])
}

@Test func `a finger that moves is drawn where it is now, with its trail behind it`() {
    var presence = Presence()
    presence.saw(.drag(from: here, to: here, ended: false), time: 10)
    presence.saw(.drag(from: here, to: there, ended: false), time: 10.2)
    let moving = presence.step(to: 10.2)
    #expect(moving.count > 3)
    #expect(moving.allSatisfy { $0.look == .spot })
    #expect(moving.first?.point == here)
    #expect(moving.last == Mark(point: there, radius: 0.045, opacity: 0.95))
    // The trail gets larger toward the finger.
    #expect(moving.dropLast().map(\.radius) == moving.dropLast().map(\.radius).sorted())
}

@Test func `a swipe that ends keeps its trail, and a ring spreads where it ended`() {
    var presence = Presence()
    presence.saw(.drag(from: here, to: here, ended: false), time: 10)
    presence.saw(.drag(from: here, to: there, ended: true), time: 10.3)
    // At once: the whole trail, the finger's spot at the end, and the ring. Nothing is drawn again.
    let ended = presence.step(to: 10.3)
    #expect(ended.first?.point == here)
    #expect(ended.last == Mark(point: there, radius: ended.last!.radius, opacity: ended.last!.opacity, look: .ring))
    #expect(ended.dropLast().last?.point == there)
    // The trail fades as the ring spreads.
    let later = presence.step(to: 10.6)
    #expect(later[0].opacity < ended[0].opacity)
    #expect(later.last!.radius > ended.last!.radius)
    #expect(presence.step(to: 10.8).isEmpty)
}

@Test func `a finger whose end was lost goes away by itself`() {
    var presence = Presence()
    presence.saw(.drag(from: here, to: there, ended: false), time: 10)
    #expect(!presence.step(to: 17.9).isEmpty)
    #expect(presence.step(to: 18).isEmpty)
    #expect(presence.current(at: 18) == nil)
}

@Test func `the last action stays current for a moment`() {
    var presence = Presence()
    #expect(presence.current(at: 0) == nil)
    presence.saw(.tap(here), time: 10)
    presence.saw(.button("home", phase: "press"), time: 11)
    #expect(presence.current(at: 12) == .button("home", phase: "press"))
    #expect(presence.current(at: 13.6) == nil)
    // A button leaves no mark on the screen.
    #expect(presence.step(to: 11.5).isEmpty)
}

@Test func `a finger that is down stays current for as long as it is down`() {
    var presence = Presence()
    let held = SimWire.Activity.drag(from: here, to: here, ended: false)
    presence.saw(held, time: 10)
    #expect(presence.current(at: 15) == held)
}

@Test func `an action is named in a few words`() {
    #expect(Presence.words(for: .tap(here), interface: .portrait) == "tap")
    #expect(Presence.words(for: .button("home", phase: "press"), interface: .portrait) == "home button")
    #expect(Presence.words(for: .rotate("landscape_left"), interface: .portrait) == "rotate")
    #expect(Presence.words(for: .other("key"), interface: .portrait) == "typing")
    #expect(Presence.words(for: .other("memory-warning"), interface: .portrait) == "memory warning")
}

@Test func `a swipe is named by the way the user sees it go`() {
    let up = SimWire.Activity.drag(from: CGPoint(x: 0.5, y: 0.9), to: CGPoint(x: 0.5, y: 0.3), ended: true)
    #expect(Presence.words(for: up, interface: .portrait) == "swipe ↑")
    // In a turned interface, the same move on the framebuffer goes another way for the user.
    #expect(Presence.words(for: up, interface: .landscapeLeft) == "swipe →")
    #expect(Presence.words(for: up, interface: .upsideDown) == "swipe ↓")
    let across = SimWire.Activity.drag(from: CGPoint(x: 0.9, y: 0.5), to: CGPoint(x: 0.2, y: 0.5), ended: true)
    #expect(Presence.words(for: across, interface: .portrait) == "swipe ←")
}

@Test func `a new touch means the finger before it is up`() {
    // The device shows one other finger at a time, as when a second agent touches.
    var presence = Presence()
    presence.saw(.drag(from: here, to: CGPoint(x: 0.3, y: 0.62), ended: false), time: 10)
    presence.saw(.tap(here), time: 10.5)
    #expect(presence.step(to: 10.6).map(\.point) == [here, here])
    #expect(presence.step(to: 11).isEmpty)
    #expect(presence.current(at: 13.1) == nil)

    presence.saw(.drag(from: here, to: here, ended: false), time: 20)
    presence.saw(.drag(from: there, to: there, ended: false), time: 21)
    #expect(presence.step(to: 21.5).map(\.point) == [there])
}
