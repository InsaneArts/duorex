import CoreGraphics
import Testing
@testable import duorex

/// The pane from the Rex session where the device left its pane: the right half of the window.
private let paneOrigin = CGPoint(x: 1464, y: 46)
private let paneSize = CGSize(width: 1061, height: 1176)
/// The Rex window that pane was in. The pane is the right half of the pane area.
private let layout = PaneLocator.Layout(windowSize: CGSize(width: 2530, height: 1260), paneSize: paneSize,
                                        rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))

/// Feeds a locator the report a terminal sends for a pointer at `pointer`, in window coordinates.
/// Like Rex, the terminal keeps reporting when the pointer leaves the pane, clamped to the pane.
private func report(_ locator: inout PaneLocator, pointer: CGPoint, time: Double) {
    let local = CGPoint(x: min(max(pointer.x - paneOrigin.x, 0), paneSize.width),
                        y: min(max(pointer.y - paneOrigin.y, 0), paneSize.height))
    if locator.wants(local: local, pointer: pointer, time: time) {
        _ = locator.measure(CGPoint(x: pointer.x - local.x, y: pointer.y - local.y))
    }
}

/// A locator that has found the pane from a pointer resting inside it.
private func locatedPane() -> PaneLocator {
    var locator = PaneLocator()
    locator.update(layout)
    report(&locator, pointer: CGPoint(x: 1700, y: 300), time: 0)
    report(&locator, pointer: CGPoint(x: 1700.5, y: 300), time: 0.016)
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
        report(&locator, pointer: CGPoint(x: x, y: 300), time: time)
        time += 0.016
    }
    #expect(locator.origin == paneOrigin)
}

@Test func `a pointer that comes back after a long drag outside does not move the pane`() {
    var locator = locatedPane()
    report(&locator, pointer: CGPoint(x: 400, y: 300), time: 1)
    report(&locator, pointer: CGPoint(x: 400.2, y: 300), time: 1.016)
    #expect(locator.origin == paneOrigin)
}

@Test func `a fast pointer is not trusted`() {
    var locator = PaneLocator()
    locator.update(layout)
    // Reports lag a fast pointer, so the first ones would place the pane wrongly.
    report(&locator, pointer: CGPoint(x: 1600, y: 300), time: 0)
    report(&locator, pointer: CGPoint(x: 1680, y: 300), time: 0.016)
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
    for step in 0..<2 {
        let local = CGPoint(x: pointer.x - (paneOrigin.x - 197), y: pointer.y - paneOrigin.y)
        if locator.wants(local: local, pointer: pointer, time: 5 + Double(step) * 0.016) {
            _ = locator.measure(CGPoint(x: pointer.x - local.x, y: pointer.y - local.y))
        }
    }
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
