import CoreGraphics
import Testing
@testable import duorex

/// A flat screen in the middle of an 800 by 600 view, with a 30 point frame around it.
private let glass = CGRect(x: 200, y: 150, width: 400, height: 300)

/// The power button, on the right edge of the device.
private let powerButton = CGPoint(x: 640, y: 250)

private func probe(_ point: CGPoint) -> Probe {
    if hypot(point.x - powerButton.x, point.y - powerButton.y) < 20 { return Probe(button: .power) }
    let nearest = CGPoint(x: min(max((point.x - glass.minX) / glass.width, 0), 1),
                          y: min(max((point.y - glass.minY) / glass.height, 0), 1))
    if glass.contains(point) { return Probe(glass: nearest, nearest: nearest) }
    return Probe(glass: nil, nearest: nearest, onFrame: glass.insetBy(dx: -30, dy: -30).contains(point))
}

private func motion() -> DeviceMotion {
    var motion = DeviceMotion()
    motion.viewSize = CGSize(width: 800, height: 600)
    _ = motion.step(to: 100)
    return motion
}

/// Steps the motion for `seconds` at 60 frames a second and returns every effect.
private func run(_ motion: inout DeviceMotion, from start: Double, seconds: Double) -> [DeviceMotion.Effect] {
    var effects: [DeviceMotion.Effect] = []
    var time = start
    while time < start + seconds {
        time += 1.0 / 60
        effects += motion.step(to: time).effects
    }
    return effects
}

@Test func `a press on the glass is a touch from begin to end`() {
    var motion = motion()
    #expect(motion.pointerDown(at: CGPoint(x: 400, y: 300), option: false, probe: probe) == [.touch(.begin, CGPoint(x: 0.5, y: 0.5))])
    #expect(motion.pointerMoved(to: CGPoint(x: 500, y: 300), probe: probe) == [.touch(.move, CGPoint(x: 0.75, y: 0.5))])
    #expect(motion.pointerUp(at: CGPoint(x: 500, y: 300), probe: probe) == [.touch(.end, CGPoint(x: 0.75, y: 0.5))])
    #expect(!motion.isDragging)
}

@Test func `a touch that leaves the glass stays on its edge`() {
    var motion = motion()
    _ = motion.pointerDown(at: CGPoint(x: 400, y: 300), option: false, probe: probe)
    #expect(motion.pointerMoved(to: CGPoint(x: 790, y: 300), probe: probe) == [.touch(.move, CGPoint(x: 1, y: 0.5))])
    #expect(motion.pointerUp(at: CGPoint(x: 790, y: 300), probe: probe) == [.touch(.end, CGPoint(x: 1, y: 0.5))])
}

@Test func `dragging the frame folds the device and tells the simulator`() {
    var motion = motion()
    // The left edge of the frame, pulled a quarter of the view to the right.
    #expect(motion.pointerDown(at: CGPoint(x: 185, y: 300), option: false, probe: probe).isEmpty)
    _ = motion.pointerMoved(to: CGPoint(x: 385, y: 300), probe: probe)
    #expect(abs(motion.pose.hinge - 90) < 0.001)
    #expect(run(&motion, from: 100, seconds: 0.1) == [.hinge(motion.pose.hinge)])
    _ = motion.pointerUp(at: CGPoint(x: 385, y: 300), probe: probe)
    #expect(run(&motion, from: 101, seconds: 1).isEmpty)
    #expect(abs(motion.pose.hinge - 90) < 0.001)
}

@Test func `letting go close to flat finishes the move`() {
    var motion = motion()
    _ = motion.pointerDown(at: CGPoint(x: 185, y: 300), option: false, probe: probe)
    _ = motion.pointerMoved(to: CGPoint(x: 205, y: 300), probe: probe)   // 171 degrees
    _ = motion.pointerUp(at: CGPoint(x: 205, y: 300), probe: probe)
    let effects = run(&motion, from: 100, seconds: 2)
    #expect(motion.pose.hinge == 180)
    #expect(effects.last == .hinge(180))
}

@Test func `a turned device folds along its own width`() {
    var motion = motion()
    motion.rotate(to: -90)
    _ = run(&motion, from: 100, seconds: 2)
    // Held a quarter turn round, the hinge runs across the view, so the fold follows the pointer down.
    _ = motion.pointerDown(at: CGPoint(x: 400, y: 140), option: false, probe: probe)
    _ = motion.pointerMoved(to: CGPoint(x: 600, y: 140), probe: probe)
    #expect(abs(motion.pose.hinge - 180) < 0.001)
    _ = motion.pointerMoved(to: CGPoint(x: 400, y: 290), probe: probe)
    #expect(abs(motion.pose.hinge - 90) < 0.001)
}

@Test func `a drag on the background turns the device, and it springs back`() {
    var motion = motion()
    _ = motion.pointerDown(at: CGPoint(x: 50, y: 50), option: false, probe: probe)
    _ = motion.pointerMoved(to: CGPoint(x: 150, y: 90), probe: probe)
    #expect(abs(motion.pose.yaw - 50) < 0.001)
    #expect(abs(motion.pose.pitch - 20) < 0.001)
    #expect(motion.pointerUp(at: CGPoint(x: 150, y: 90), probe: probe).isEmpty)
    _ = run(&motion, from: 100, seconds: 4)
    #expect(motion.pose.yaw == 0)
    #expect(motion.pose.pitch == 0)
}

@Test func `a long drag turns the device all the way round`() {
    var motion = motion()
    _ = motion.pointerDown(at: CGPoint(x: 50, y: 50), option: false, probe: probe)
    _ = motion.pointerMoved(to: CGPoint(x: 410, y: 50), probe: probe)
    // Half a turn: the user looks at the back.
    #expect(abs(motion.pose.yaw - 180) < 0.001)
    _ = motion.pointerMoved(to: CGPoint(x: 750, y: 50), probe: probe)
    #expect(abs(motion.pose.yaw - 350) < 0.001)
}

@Test func `a turned device comes back to the front by the shorter way`() {
    var motion = motion()
    _ = motion.pointerDown(at: CGPoint(x: 50, y: 50), option: false, probe: probe)
    // 250 degrees one way is 110 degrees the other way.
    _ = motion.pointerMoved(to: CGPoint(x: 550, y: 50), probe: probe)
    _ = motion.pointerUp(at: CGPoint(x: 550, y: 50), probe: probe)
    #expect(abs(motion.pose.yaw + 110) < 0.001)
    var time = 100.0, furthest = 0.0, past = 0.0
    while time < 104 {
        time += 1.0 / 60
        _ = motion.step(to: time)
        furthest = min(furthest, motion.pose.yaw)
        past = max(past, motion.pose.yaw)
    }
    #expect(furthest >= -110.001)
    // From far away it arrives without a swing past the front.
    #expect(past < 2)
    #expect(motion.pose.yaw == 0)
}

@Test func `after a long way back, a small tilt bounces again`() {
    var motion = motion()
    _ = motion.pointerDown(at: CGPoint(x: 50, y: 50), option: false, probe: probe)
    _ = motion.pointerMoved(to: CGPoint(x: 550, y: 50), probe: probe)
    _ = motion.pointerUp(at: CGPoint(x: 550, y: 50), probe: probe)
    _ = run(&motion, from: 100, seconds: 4)
    // A small tilt, let go.
    _ = motion.pointerDown(at: CGPoint(x: 50, y: 50), option: false, probe: probe)
    _ = motion.pointerMoved(to: CGPoint(x: 90, y: 50), probe: probe)
    _ = motion.pointerUp(at: CGPoint(x: 90, y: 50), probe: probe)
    var time = 104.0, past = 0.0
    while time < 108 {
        time += 1.0 / 60
        _ = motion.step(to: time)
        past = min(past, motion.pose.yaw)
    }
    #expect(past < -1)
}

@Test func `the wheel moves a finger that lifts when the wheel stops`() {
    var motion = motion()
    let start = CGPoint(x: 400, y: 300)
    #expect(motion.wheel(at: start, lines: 1, probe: probe) == [.scroll(.begin, CGPoint(x: 0.5, y: 0.5))])
    #expect(motion.wheel(at: start, lines: 1, probe: probe) == [.scroll(.move, CGPoint(x: 0.5, y: 0.43))])
    #expect(run(&motion, from: 100, seconds: 0.05).isEmpty)
    #expect(run(&motion, from: 100.05, seconds: 0.2) == [.scroll(.end, CGPoint(x: 0.5, y: 0.43))])
}

@Test func `the wheel does nothing off the glass`() {
    var motion = motion()
    #expect(motion.wheel(at: CGPoint(x: 50, y: 50), lines: 1, probe: probe).isEmpty)
}

@Test func `following the simulator is not sent back to it`() {
    var motion = motion()
    motion.follow(hinge: 60, animated: true)
    #expect(run(&motion, from: 100, seconds: 3).isEmpty)
    #expect(motion.pose.hinge == 60)
    motion.fold(to: 130)
    #expect(run(&motion, from: 103, seconds: 3).last == .hinge(130))
}

@Test func `the device turns toward a pointer in the view and settles when it leaves`() {
    var motion = motion()
    _ = motion.pointerMoved(to: CGPoint(x: 800, y: 300), probe: probe)
    _ = run(&motion, from: 100, seconds: 1)
    #expect(motion.pose.yaw > 3)
    motion.pointerLeft()
    _ = run(&motion, from: 101, seconds: 4)
    #expect(motion.pose.yaw == 0)
}

@Test func `the device does not move under a finger that is down`() {
    var motion = motion()
    _ = motion.pointerDown(at: CGPoint(x: 400, y: 300), option: false, probe: probe)
    // The simulator reports a new hinge angle while the touch is held.
    motion.follow(hinge: 60, animated: false)
    #expect(motion.pose.hinge == 180)
}

@Test func `a press on a button holds it down until the pointer lets go`() {
    var motion = motion()
    #expect(motion.pointerDown(at: powerButton, option: false, probe: probe) == [.button(.power, pressed: true)])
    #expect(motion.isDragging)
    // The pointer slides off the button and onto the glass. The button stays down and nothing is touched.
    #expect(motion.pointerMoved(to: CGPoint(x: 400, y: 300), probe: probe).isEmpty)
    #expect(motion.pointerUp(at: CGPoint(x: 400, y: 300), probe: probe) == [.button(.power, pressed: false)])
    #expect(!motion.isDragging)
}

@Test func `a pressed button goes in and comes back out`() {
    var motion = motion()
    _ = motion.pointerDown(at: powerButton, option: false, probe: probe)
    _ = run(&motion, from: 100, seconds: 1)
    #expect(motion.pose.press == Pose.Press(button: .power, depth: 1))
    _ = motion.pointerUp(at: powerButton, probe: probe)
    _ = run(&motion, from: 101, seconds: 1)
    #expect(motion.pose.press == nil)
}

@Test func `the button under a resting pointer is known`() {
    var motion = motion()
    _ = motion.pointerMoved(to: powerButton, probe: probe)
    #expect(motion.hoveredButton == .power)
    _ = motion.pointerMoved(to: CGPoint(x: 50, y: 50), probe: probe)
    #expect(motion.hoveredButton == nil)
    _ = motion.pointerMoved(to: powerButton, probe: probe)
    motion.pointerLeft()
    #expect(motion.hoveredButton == nil)
}

@Test func `a press after a lost release lets the held button go first`() {
    var motion = motion()
    _ = motion.pointerDown(at: powerButton, option: false, probe: probe)
    // The terminal never reported the release. The next press is on the glass.
    #expect(motion.pointerDown(at: CGPoint(x: 400, y: 300), option: false, probe: probe)
        == [.button(.power, pressed: false), .touch(.begin, CGPoint(x: 0.5, y: 0.5))])
}

@Test func `a press after a lost release lifts the finger that was down`() {
    var motion = motion()
    _ = motion.pointerDown(at: CGPoint(x: 400, y: 300), option: false, probe: probe)
    #expect(motion.pointerDown(at: CGPoint(x: 500, y: 300), option: false, probe: probe)
        == [.touch(.end, CGPoint(x: 0.75, y: 0.5)), .touch(.begin, CGPoint(x: 0.75, y: 0.5))])
}

// MARK: Pinch

@Test func `an Option-press on the glass is a pinch: two fingers, mirrored about the middle of the screen`() {
    var motion = motion()
    let first = CGPoint(x: 0.25, y: 0.25), second = CGPoint(x: 1 - 0.25, y: 1 - 0.25)
    #expect(motion.pointerDown(at: CGPoint(x: 300, y: 225), option: true, probe: probe) == [.pinch(.begin, first, second)])
    #expect(motion.fingers == [first, second])
    let inFirst = CGPoint(x: 0.4, y: 0.4), inSecond = CGPoint(x: 1 - 0.4, y: 1 - 0.4)
    #expect(motion.pointerMoved(to: CGPoint(x: 360, y: 270), probe: probe) == [.pinch(.move, inFirst, inSecond)])
    #expect(motion.fingers == [inFirst, inSecond])
    #expect(motion.pointerUp(at: CGPoint(x: 360, y: 270), probe: probe) == [.pinch(.end, inFirst, inSecond)])
    #expect(motion.fingers.isEmpty)
    #expect(!motion.isDragging)
    // A pinch is not a fold.
    #expect(motion.pose.hinge == 180)
}

@Test func `a pinch that leaves the glass stays on its edge`() {
    var motion = motion()
    _ = motion.pointerDown(at: CGPoint(x: 300, y: 225), option: true, probe: probe)
    #expect(motion.pointerMoved(to: CGPoint(x: 100, y: 300), probe: probe) == [.pinch(.move, CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5))])
}

@Test func `an Option-press off the glass still folds`() {
    var motion = motion()
    // On the background, far from the device.
    #expect(motion.pointerDown(at: CGPoint(x: 60, y: 300), option: true, probe: probe).isEmpty)
    _ = motion.pointerMoved(to: CGPoint(x: 260, y: 300), probe: probe)
    #expect(motion.pose.hinge < 180)
    #expect(motion.fingers.isEmpty)
}

@Test func `with Option held, a resting pointer shows where the two fingers would go`() {
    var motion = motion()
    _ = motion.pointerMoved(to: CGPoint(x: 300, y: 225), option: true, probe: probe)
    #expect(motion.fingers == [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 1 - 0.25, y: 1 - 0.25)])
    // Off the glass, and without Option, there is nothing to show.
    _ = motion.pointerMoved(to: CGPoint(x: 60, y: 300), option: true, probe: probe)
    #expect(motion.fingers.isEmpty)
    _ = motion.pointerMoved(to: CGPoint(x: 300, y: 225), option: true, probe: probe)
    _ = motion.pointerMoved(to: CGPoint(x: 301, y: 225), probe: probe)
    #expect(motion.fingers.isEmpty)
    _ = motion.pointerMoved(to: CGPoint(x: 300, y: 225), option: true, probe: probe)
    motion.pointerLeft()
    #expect(motion.fingers.isEmpty)
}

@Test func `the fingers shown for a resting pointer go away when a press begins somewhere else`() {
    var motion = motion()
    _ = motion.pointerMoved(to: CGPoint(x: 300, y: 225), option: true, probe: probe)
    #expect(motion.fingers.count == 2)
    // The press lands on the background before any report of the move there.
    _ = motion.pointerDown(at: CGPoint(x: 60, y: 300), option: true, probe: probe)
    #expect(motion.fingers.isEmpty)
}

// MARK: Sound

/// The sounds among some effects.
private func sounds(_ effects: [DeviceMotion.Effect]) -> [DeviceMotion.Sound] {
    effects.compactMap { if case .sound(let sound, _) = $0 { sound } else { nil } }
}

@Test func `the device makes a sound when it shuts and when it opens flat`() {
    var motion = motion()
    motion.fold(to: 0)
    #expect(sounds(run(&motion, from: 100, seconds: 3)) == [.shut])
    motion.fold(to: 180)
    #expect(sounds(run(&motion, from: 103, seconds: 3)) == [.flat])
    // A fold that stops half way makes none.
    motion.fold(to: 130)
    #expect(sounds(run(&motion, from: 106, seconds: 3)).isEmpty)
}

@Test func `a device that the simulator folds makes the same sounds`() {
    var motion = motion()
    motion.follow(hinge: 0, animated: true)
    #expect(sounds(run(&motion, from: 100, seconds: 3)) == [.shut])
}

@Test func `a device that takes the simulator's angle at once makes no sound`() {
    var motion = motion()
    // As at the start, when the simulator is already shut.
    motion.follow(hinge: 0, animated: false)
    #expect(sounds(run(&motion, from: 100, seconds: 1)).isEmpty)
    motion.follow(hinge: 180, animated: true)
    #expect(sounds(run(&motion, from: 101, seconds: 3)) == [.flat])
}

@Test func `a hinge held near shut makes one sound, not one for each small move`() {
    var motion = motion()
    _ = motion.pointerDown(at: CGPoint(x: 185, y: 300), option: false, probe: probe)
    var heard: [DeviceMotion.Sound] = []
    var time = 100.0
    // Pulled shut, then moved a few degrees open and shut again, four times.
    for x in [585.0, 580, 585, 578, 585, 580, 585, 579, 585] {
        _ = motion.pointerMoved(to: CGPoint(x: x, y: 300), probe: probe)
        time += 0.05
        heard += sounds(motion.step(to: time).effects)
    }
    #expect(heard == [.shut])
}

@Test func `a fast shut is louder than a slow one`() {
    func strength(of effects: [DeviceMotion.Effect]) -> Double {
        effects.compactMap { if case .sound(_, let strength) = $0 { strength } else { nil } }.first ?? -1
    }
    var fast = motion()
    fast.fold(to: 0)
    let hard = strength(of: run(&fast, from: 100, seconds: 3))
    // The same way by hand, a degree at a time.
    var slow = motion()
    _ = slow.pointerDown(at: CGPoint(x: 185, y: 300), option: false, probe: probe)
    var soft = -1.0, time = 100.0
    for step in 0...200 {
        _ = slow.pointerMoved(to: CGPoint(x: 185 + Double(step) * 2, y: 300), probe: probe)
        time += 0.05
        let effects = slow.step(to: time).effects
        if strength(of: effects) >= 0 { soft = strength(of: effects) }
    }
    #expect(soft >= 0 && soft < hard)
    #expect(hard <= 1)
}

// MARK: Found by review

@Test func `a click late in a long way back does not take the bounce from a small tilt`() {
    func swing(clickDuringReturn: Bool) -> Double {
        var motion = motion()
        _ = motion.pointerDown(at: CGPoint(x: 50, y: 50), option: false, probe: probe)
        _ = motion.pointerMoved(to: CGPoint(x: 550, y: 50), probe: probe)
        _ = motion.pointerUp(at: CGPoint(x: 550, y: 50), probe: probe)
        var time = 100.0
        // Until the device is nearly back, and still moving.
        while abs(motion.pose.yaw) > 20 {
            time += 1.0 / 60
            _ = motion.step(to: time)
        }
        if clickDuringReturn {
            _ = motion.pointerDown(at: CGPoint(x: 50, y: 50), option: false, probe: probe)
            _ = motion.pointerUp(at: CGPoint(x: 50, y: 50), probe: probe)
        }
        _ = run(&motion, from: time, seconds: 4)
        // A small tilt, let go.
        _ = motion.pointerDown(at: CGPoint(x: 50, y: 50), option: false, probe: probe)
        _ = motion.pointerMoved(to: CGPoint(x: 90, y: 50), probe: probe)
        _ = motion.pointerUp(at: CGPoint(x: 90, y: 50), probe: probe)
        var past = 0.0
        time += 4
        let end = time + 4
        while time < end {
            time += 1.0 / 60
            _ = motion.step(to: time)
            past = min(past, motion.pose.yaw)
        }
        return past
    }
    #expect(swing(clickDuringReturn: false) < -1)
    #expect(swing(clickDuringReturn: true) < -1)
}

@Test func `a press on the background holds a device that was on its way back`() {
    var motion = motion()
    _ = motion.pointerDown(at: CGPoint(x: 50, y: 50), option: false, probe: probe)
    _ = motion.pointerMoved(to: CGPoint(x: 410, y: 50), probe: probe)
    _ = motion.pointerUp(at: CGPoint(x: 410, y: 50), probe: probe)
    var time = 100.0
    while abs(motion.pose.yaw) > 110 {
        time += 1.0 / 60
        _ = motion.step(to: time)
    }
    _ = motion.pointerDown(at: CGPoint(x: 50, y: 50), option: false, probe: probe)
    let held = motion.pose.yaw
    // The user holds still, then moves one point. The device stays in the hand.
    _ = run(&motion, from: time, seconds: 0.4)
    #expect(abs(motion.pose.yaw - held) < 0.001)
    _ = motion.pointerMoved(to: CGPoint(x: 51, y: 50), probe: probe)
    #expect(abs(motion.pose.yaw - held) < 1)
}

@Test func `a frame that comes late does not make a slow fold loud`() {
    var motion = motion()
    _ = motion.pointerDown(at: CGPoint(x: 185, y: 300), option: false, probe: probe)
    // The hand shuts the device over two seconds, and the display draws only once, at the end.
    _ = motion.pointerMoved(to: CGPoint(x: 585, y: 300), probe: probe)
    let effects = motion.step(to: 102).effects
    let strength = effects.compactMap { if case .sound(.shut, let strength) = $0 { strength } else { nil } }.first
    #expect(strength != nil)
    #expect((strength ?? 1) < 0.4)
}

@Test func `a move with no button down ends a press whose release was lost`() {
    var motion = motion()
    // The terminal tells a drag as a drag.
    _ = motion.pointerDown(at: CGPoint(x: 300, y: 225), option: true, probe: probe)
    _ = motion.pointerMoved(to: CGPoint(x: 310, y: 225), option: true, pressed: true, probe: probe)
    _ = motion.pointerUp(at: CGPoint(x: 310, y: 225), probe: probe)
    // A pinch begins, and its release never arrives.
    _ = motion.pointerDown(at: CGPoint(x: 300, y: 225), option: true, probe: probe)
    let ended = motion.pointerMoved(to: CGPoint(x: 360, y: 270), pressed: false, probe: probe)
    #expect(ended.contains { if case .pinch(.end, _, _) = $0 { true } else { false } })
    #expect(!motion.isDragging)
    #expect(motion.fingers.isEmpty)
}

@Test func `a terminal that tells every move the same way keeps its drags`() {
    var motion = motion()
    _ = motion.pointerDown(at: CGPoint(x: 400, y: 300), option: false, probe: probe)
    // No report ever said that a button was down, so a move may still be a drag.
    #expect(motion.pointerMoved(to: CGPoint(x: 500, y: 300), pressed: false, probe: probe) == [.touch(.move, CGPoint(x: 0.75, y: 0.5))])
    #expect(motion.isDragging)
}
