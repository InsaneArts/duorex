import CoreGraphics
import Testing
@testable import duorex

/// A flat screen in the middle of an 800 by 600 view, with a 30 point frame around it.
private let glass = CGRect(x: 200, y: 150, width: 400, height: 300)

private func probe(_ point: CGPoint) -> Probe {
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

@Test func `a drag on the background tilts the device, and it springs back`() {
    var motion = motion()
    _ = motion.pointerDown(at: CGPoint(x: 50, y: 50), option: false, probe: probe)
    _ = motion.pointerMoved(to: CGPoint(x: 150, y: 50), probe: probe)
    #expect(abs(motion.pose.yaw - 35) < 0.001)
    #expect(motion.pointerUp(at: CGPoint(x: 150, y: 50), probe: probe).isEmpty)
    _ = run(&motion, from: 100, seconds: 4)
    #expect(motion.pose.yaw == 0)
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
