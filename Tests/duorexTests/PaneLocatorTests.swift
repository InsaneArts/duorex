import CoreGraphics
import Testing
@testable import duorex

/// The pane from the Rex session where the device left its pane: the right half of the window.
private let paneOrigin = CGPoint(x: 1464, y: 46)
private let paneSize = CGSize(width: 1061, height: 1176)

/// Feeds a locator the report a terminal sends for a pointer at `pointer`, in window coordinates.
/// Like Rex, the terminal keeps reporting when the pointer leaves the pane, clamped to the pane.
private func report(_ locator: inout PaneLocator, pointer: CGPoint, time: Double) {
    let local = CGPoint(x: min(max(pointer.x - paneOrigin.x, 0), paneSize.width),
                        y: min(max(pointer.y - paneOrigin.y, 0), paneSize.height))
    if locator.wants(local: local, pointer: pointer, paneSize: paneSize, time: time) {
        _ = locator.measure(CGPoint(x: pointer.x - local.x, y: pointer.y - local.y))
    }
}

/// A locator that has found the pane from a pointer resting inside it.
private func locatedPane() -> PaneLocator {
    var locator = PaneLocator()
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
    // Reports lag a fast pointer, so the first ones would place the pane wrongly.
    report(&locator, pointer: CGPoint(x: 1600, y: 300), time: 0)
    report(&locator, pointer: CGPoint(x: 1680, y: 300), time: 0.016)
    #expect(locator.origin == nil)
}

@Test func `a new layout is measured again`() {
    var locator = locatedPane()
    locator.layoutChanged(predicted: CGPoint(x: 900, y: 46))
    #expect(locator.origin == CGPoint(x: 900, y: 46))
    #expect(!locator.isMeasured)
    report(&locator, pointer: CGPoint(x: 1700, y: 300), time: 5)
    report(&locator, pointer: CGPoint(x: 1700.4, y: 300), time: 5.016)
    #expect(locator.origin == paneOrigin)
    #expect(locator.isMeasured)
}
