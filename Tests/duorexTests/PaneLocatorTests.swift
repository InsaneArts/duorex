import CoreGraphics
import Testing
@testable import duorex

/// The pane from the Rex session where the device left its pane: the right half of the window.
private let paneOrigin = CGPoint(x: 1464, y: 46)
private let paneSize = CGSize(width: 1061, height: 1176)
/// The Rex window that pane was in. The pane is the right half of the pane area.
private let layout = PaneLocator.Layout(windowSize: CGSize(width: 2530, height: 1260), paneSize: paneSize,
                                        rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))

/// Feeds a locator the report a terminal sends for a pointer at `reported`, in window coordinates.
/// Like Rex, the terminal keeps reporting when the pointer leaves the pane, clamped to the pane.
/// `pointer` is where the pointer is on screen when the report is read: the same place, or further on.
private func report(_ locator: inout PaneLocator, at reported: CGPoint, pointer: CGPoint? = nil, time: Double, from origin: CGPoint = paneOrigin) {
    let local = CGPoint(x: min(max(reported.x - origin.x, 0), paneSize.width),
                        y: min(max(reported.y - origin.y, 0), paneSize.height))
    locator.reported(local: local, pointer: pointer ?? reported, time: time)
}

/// Looks for the pane the way the dock does at each tick, with the pointer at `pointer` on screen.
private func look(_ locator: inout PaneLocator, pointer: CGPoint, time: Double) {
    guard let local = locator.restingReport(pointer: pointer, time: time) else { return }
    _ = locator.measure(CGPoint(x: pointer.x - local.x, y: pointer.y - local.y))
}

/// A locator that has found the pane from a pointer resting inside it.
private func locatedPane() -> PaneLocator {
    var locator = PaneLocator()
    locator.update(layout)
    report(&locator, at: CGPoint(x: 1700, y: 300), time: 0)
    look(&locator, pointer: CGPoint(x: 1700, y: 300), time: 0.1)
    return locator
}

@Test func `a pointer resting in the pane finds the pane`() {
    #expect(locatedPane().origin == paneOrigin)
}

@Test func `a pointer that leaves the pane does not move it`() {
    var locator = locatedPane()
    // The pointer drifts left into the next pane, one point per report.
    var time = 1.0
    for x in stride(from: 1470.0, through: 370, by: -1) {
        report(&locator, at: CGPoint(x: x, y: 300), time: time)
        look(&locator, pointer: CGPoint(x: x, y: 300), time: time)
        time += 0.016
    }
    // It stops there.
    look(&locator, pointer: CGPoint(x: 370, y: 300), time: time + 1)
    #expect(locator.origin == paneOrigin)
}

@Test func `a pointer that comes back after a long drag outside does not move the pane`() {
    var locator = locatedPane()
    report(&locator, at: CGPoint(x: 400, y: 300), time: 1)
    look(&locator, pointer: CGPoint(x: 400, y: 300), time: 1.1)
    #expect(locator.origin == paneOrigin)
}

@Test func `a moving pointer is not trusted`() {
    var locator = PaneLocator()
    locator.update(layout)
    // Reports lag a moving pointer, so they would place the pane wrongly.
    var time = 0.0
    for x in stride(from: 1600.0, through: 1700, by: 2) {
        report(&locator, at: CGPoint(x: x, y: 300), pointer: CGPoint(x: x + 3, y: 300), time: time)
        look(&locator, pointer: CGPoint(x: x + 3, y: 300), time: time)
        time += 0.016
    }
    #expect(locator.origin == nil)
}

@Test func `a pointer that moved on where the terminal does not see it is not trusted`() {
    var locator = PaneLocator()
    locator.update(layout)
    // The last report is from inside the pane. The pointer then rests on a window in front of it.
    report(&locator, at: CGPoint(x: 1700, y: 300), time: 0)
    look(&locator, pointer: CGPoint(x: 1740, y: 300), time: 0.5)
    #expect(locator.origin == nil)
}

@Test func `a new layout is predicted, then measured again`() {
    var locator = locatedPane()
    // The window gets 400 points narrower. The panes keep their shares.
    var narrower = layout
    narrower.windowSize.width -= 400
    narrower.paneSize.width -= 200
    locator.update(narrower)
    #expect(locator.origin == CGPoint(x: paneOrigin.x - 200, y: paneOrigin.y))
    #expect(!locator.isMeasured)
    // The prediction was off by three points. A pointer resting in the pane corrects it.
    let pointer = CGPoint(x: 1500, y: 300)
    report(&locator, at: pointer, time: 5, from: CGPoint(x: paneOrigin.x - 197, y: paneOrigin.y))
    look(&locator, pointer: pointer, time: 5.2)
    #expect(locator.origin == CGPoint(x: paneOrigin.x - 197, y: paneOrigin.y))
    #expect(locator.isMeasured)
}

@Test func `chrome learned in one layout places the pane in another`() {
    var locator = locatedPane()
    #expect(locator.chrome == PaneLocator.Chrome(top: 46, right: 5))
    // The other pane closes, so this one takes the whole pane area.
    locator.update(PaneLocator.Layout(windowSize: layout.windowSize, paneSize: CGSize(width: 2122, height: 1176),
                                      rect: CGRect(x: 0, y: 0, width: 1, height: 1)))
    #expect(locator.origin == CGPoint(x: 403, y: 46))
}

@Test func `saved chrome places the pane before the pointer moves`() {
    var locator = PaneLocator(chrome: PaneLocator.Chrome(top: 46, right: 5))
    #expect(locator.origin == nil)
    locator.update(layout)
    #expect(locator.origin == paneOrigin)
    #expect(!locator.isMeasured)
}

@Test func `the same layout again keeps the measurement`() {
    var locator = locatedPane()
    locator.update(layout)
    #expect(locator.isMeasured)
}

@Test func `reports from a moving pointer do not move the pane`() {
    var locator = locatedPane()
    // The pointer crosses the pane. Three of its reports are read together, when the pointer
    // on screen has already moved on.
    let pointer = CGPoint(x: 1708, y: 300)
    for x in [1700.0, 1703, 1706] {
        report(&locator, at: CGPoint(x: x, y: 300), pointer: pointer, time: 1)
        look(&locator, pointer: pointer, time: 1)
    }
    look(&locator, pointer: pointer, time: 1.016)
    #expect(locator.origin == paneOrigin)
}
