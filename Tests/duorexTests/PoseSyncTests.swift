import Testing
@testable import duorex

@Test func `the first hinge report snaps the device to the simulator`() {
    var sync = PoseSync()
    #expect(sync.simulatorReported(hinge: 0, shown: 180, time: 0) == .snap(0))
    #expect(sync.reportedHinge == 0)
}

@Test func `the echo of the user's own fold is ignored`() {
    var sync = PoseSync()
    _ = sync.simulatorReported(hinge: 180, shown: 180, time: 0)
    sync.userMovedHinge(time: 10)
    // The device on screen is already at 90; the simulator is still on its way.
    #expect(sync.simulatorReported(hinge: 150, shown: 90, time: 10.3) == .ignore)
    #expect(sync.simulatorReported(hinge: 95, shown: 90, time: 10.9) == .ignore)
}

@Test func `a fold from elsewhere is followed`() {
    var sync = PoseSync()
    _ = sync.simulatorReported(hinge: 180, shown: 180, time: 0)
    sync.userMovedHinge(time: 10)
    #expect(sync.simulatorReported(hinge: 130, shown: 180, time: 20) == .follow(130))
}

@Test func `a report that matches the screen changes nothing`() {
    var sync = PoseSync()
    _ = sync.simulatorReported(hinge: 180, shown: 180, time: 0)
    #expect(sync.simulatorReported(hinge: 178, shown: 180, time: 20) == .ignore)
}

@Test func `the lit panel sets the pose only until a hinge angle arrives`() {
    var sync = PoseSync()
    #expect(sync.panelLit(.cover) == .snap(0))
    #expect(sync.panelLit(.inner) == .snap(180))
    _ = sync.simulatorReported(hinge: 130, shown: 180, time: 0)
    #expect(sync.panelLit(.cover) == .ignore)
}

@Test func `a stale report does not undo the user's turn`() {
    var sync = PoseSync()
    #expect(sync.userTurned(time: 5) == .landscapeLeft)
    // Sent before the simulator turned.
    #expect(sync.simulatorReported(held: .portrait, time: 5.2) == nil)
    #expect(sync.held == .landscapeLeft)
    // The simulator confirms the turn.
    #expect(sync.simulatorReported(held: .landscapeLeft, time: 5.6) == nil)
}

@Test func `a turn from elsewhere is taken`() {
    var sync = PoseSync()
    _ = sync.userTurned(time: 5)
    #expect(sync.simulatorReported(held: .landscapeRight, time: 30) == .landscapeRight)
    #expect(sync.held == .landscapeRight)
}
