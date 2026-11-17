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
    #expect(early.map(\.isRing) == [false, true])
    // The ring grows and fades. The spot keeps its size.
    #expect(late[1].radius > early[1].radius)
    #expect(late[1].opacity < early[1].opacity)
    #expect(late[0].radius == early[0].radius)
    #expect(late[0].opacity < early[0].opacity)
    #expect(presence.step(to: 10.5).isEmpty)
}

@Test func `a finger that is down shows as one spot until it comes up`() {
    var presence = Presence()
    presence.saw(.drag(from: here, to: CGPoint(x: 0.32, y: 0.58), ended: false), time: 10)
    #expect(presence.step(to: 13) == [Mark(point: CGPoint(x: 0.32, y: 0.58), radius: 0.045, opacity: 0.95)])
    presence.saw(.drag(from: here, to: there, ended: true), time: 13.5)
    #expect(presence.step(to: 13.5).first?.point == here)
    #expect(presence.step(to: 15).isEmpty)
}

@Test func `a swipe is drawn from its start to its end, then a ring spreads where it ended`() {
    var presence = Presence()
    presence.saw(.drag(from: here, to: there, ended: true), time: 10)
    // On the way: a trail behind the finger, and no ring yet.
    let onTheWay = presence.step(to: 10.1)
    #expect(onTheWay.count > 3)
    #expect(onTheWay.allSatisfy { !$0.isRing })
    #expect(onTheWay.first?.point == here)
    let finger = onTheWay.last!
    #expect(finger.point.x > here.x && finger.point.x < there.x)
    // The trail gets larger toward the finger.
    #expect(onTheWay.dropLast().map(\.radius) == onTheWay.dropLast().map(\.radius).sorted())
    // Arrived: the finger's spot is at the end, with the ring.
    let arrived = presence.step(to: 10.3)
    #expect(arrived.last == Mark(point: there, radius: arrived.last!.radius, opacity: arrived.last!.opacity, isRing: true))
    #expect(arrived.dropLast().last?.point == there)
    #expect(presence.step(to: 10.71).isEmpty)
}

@Test func `a finger whose end was lost goes away by itself`() {
    var presence = Presence()
    presence.saw(.drag(from: here, to: there, ended: false), time: 10)
    #expect(presence.step(to: 17.9).count == 1)
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
    // The server follows one finger for a device, and does not always tell that it came up.
    var presence = Presence()
    presence.saw(.drag(from: here, to: CGPoint(x: 0.3, y: 0.62), ended: false), time: 10)
    // The finger went back to where it began, so the server tells a tap and never ends the drag.
    presence.saw(.tap(here), time: 10.5)
    #expect(presence.step(to: 10.6).map(\.point) == [here, here])
    #expect(presence.step(to: 11).isEmpty)
    #expect(presence.current(at: 13.1) == nil)

    presence.saw(.drag(from: here, to: here, ended: false), time: 20)
    presence.saw(.drag(from: there, to: there, ended: false), time: 21)
    #expect(presence.step(to: 21.5).map(\.point) == [there])
}
