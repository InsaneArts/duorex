import CoreGraphics
import Testing
@testable import duorex

@Test(arguments: Orientation.allCases)
func `interface and framebuffer points map back and forth`(orientation: Orientation) {
    let point = CGPoint(x: 0.2, y: 0.7)
    let there = orientation.framebufferPoint(point)
    let back = orientation.interfacePoint(there)
    #expect(abs(back.x - point.x) < 1e-9 && abs(back.y - point.y) < 1e-9)
}

@Test func `the interface is turned inside the framebuffer as serve-sim turns it`() {
    let point = CGPoint(x: 0.2, y: 0.7)
    #expect(Orientation.portrait.framebufferPoint(point) == CGPoint(x: 0.2, y: 0.7))
    #expect(Orientation.landscapeLeft.framebufferPoint(point) == CGPoint(x: 0.7, y: 0.8))
    #expect(Orientation.landscapeRight.framebufferPoint(point) == CGPoint(x: 1 - 0.7, y: 0.2))
    #expect(Orientation.upsideDown.framebufferPoint(point) == CGPoint(x: 0.8, y: 1 - 0.7))
}

@Test(arguments: zip(Orientation.allCases, [3, 4, 2, 1]))
func `a touch at the bottom of the interface is the swipe home`(orientation: Orientation, edge: Int) {
    let bottom = orientation.framebufferPoint(CGPoint(x: 0.5, y: 0.97))
    let middle = orientation.framebufferPoint(CGPoint(x: 0.5, y: 0.5))
    #expect(orientation.homeEdge(atFramebufferPoint: bottom) == edge)
    #expect(orientation.homeEdge(atFramebufferPoint: middle) == nil)
}

@Test func `four quarter turns come back to portrait`() {
    var orientation = Orientation.portrait
    var rolls: [Double] = []
    for _ in 0..<4 {
        orientation = orientation.next
        rolls.append(orientation.roll)
    }
    #expect(orientation == .portrait)
    #expect(rolls == [-90, -180, 90, 0])
}

@Test func `serve-sim's names decode`() {
    #expect(Orientation(rawValue: "landscape_left") == .landscapeLeft)
    #expect(Orientation(rawValue: "portrait_upside_down") == .upsideDown)
    #expect(Orientation(rawValue: "sideways") == nil)
}
