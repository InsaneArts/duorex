import CoreGraphics
import Testing
@testable import duorex

/// An iPhone 18 Pro's chrome: a 402x874 screen in an 18-point bezel, with 9 points for the buttons.
private func geometry(roll: Double = 0) -> FlatGeometry {
    FlatGeometry(body: CGSize(width: 438, height: 910), screen: CGRect(x: 18, y: 18, width: 402, height: 874), margin: 9,
                 buttons: [.init(button: .power, frame: CGRect(x: 430, y: 262, width: 16, height: 101))],
                 view: CGSize(width: 800, height: 600), roll: roll)
}

private func close(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6 }

@Test(arguments: [0.0, 90, -90, 180, 37])
func `a point of the body goes to the view and back`(roll: Double) {
    let flat = geometry(roll: roll)
    for point in [CGPoint(x: 0, y: 0), CGPoint(x: 219, y: 455), CGPoint(x: 400, y: 30)] {
        #expect(close(flat.bodyPoint(flat.viewPoint(point)), point))
    }
}

@Test func `the middle of the view is the middle of the body`() {
    #expect(close(geometry(roll: 90).bodyPoint(CGPoint(x: 400, y: 300)), CGPoint(x: 219, y: 455)))
}

@Test(arguments: [0.0, 90, -90, 180])
func `the screen's top left corner is the framebuffer's, however the device is turned`(roll: Double) {
    let flat = geometry(roll: roll)
    let corner = flat.viewPoint(CGPoint(x: 18.5, y: 18.5))
    let glass = flat.probe(corner).glass
    #expect(glass.map { $0.x < 0.01 && $0.y < 0.01 } == true)
}

@Test func `turned clockwise, the screen's top runs down the right of the view`() {
    let flat = geometry(roll: 90)
    let topLeft = flat.viewPoint(CGPoint(x: 18, y: 18)), topRight = flat.viewPoint(CGPoint(x: 420, y: 18))
    #expect(topLeft.x > 400 && topRight.x > 400)
    #expect(topRight.y > topLeft.y)
}

@Test func `off the glass, a point has no glass but a nearest point`() {
    let flat = geometry()
    let probe = flat.probe(flat.viewPoint(CGPoint(x: 5, y: 455)))
    #expect(probe.glass == nil)
    #expect(probe.nearest.map { close($0, CGPoint(x: 0, y: 437.0 / 874)) } == true)
}

@Test func `a side button takes the pointer`() {
    let flat = geometry()
    #expect(flat.probe(flat.viewPoint(CGPoint(x: 440, y: 300))).button == .power)
    #expect(flat.probe(flat.viewPoint(CGPoint(x: 219, y: 455))).button == nil)
}

@Test func `the device fits the view, and fits again when turned`() {
    // Upright, the height limits it: 600 points for 928. Turned, the width of 800 for 928 does.
    #expect(abs(geometry().scale - 600.0 / 928 * FlatGeometry.fill) < 1e-9)
    #expect(abs(geometry(roll: 90).scale - min(800.0 / 928, 600.0 / 456) * FlatGeometry.fill) < 1e-9)
}
