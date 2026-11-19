import CoreGraphics

/// One of the four quarter turns. It names how the user holds the device, and how the interface
/// is turned inside a panel's framebuffer. The raw values are the simulator's names for them, in snake case.
nonisolated enum Orientation: String, CaseIterable {
    case portrait
    case landscapeLeft = "landscape_left"
    case upsideDown = "portrait_upside_down"
    case landscapeRight = "landscape_right"

    /// The device's roll when it is held this way, in degrees.
    var roll: Double {
        switch self {
        case .portrait: 0
        case .landscapeLeft: -90
        case .upsideDown: -180
        case .landscapeRight: 90
        }
    }

    /// The next quarter turn.
    var next: Orientation {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// Where a point of the interface lies in the framebuffer. Both are 0...1 with the origin at the top left.
    func framebufferPoint(_ point: CGPoint) -> CGPoint {
        switch self {
        case .portrait: point
        case .landscapeLeft: CGPoint(x: point.y, y: 1 - point.x)
        case .upsideDown: CGPoint(x: 1 - point.x, y: 1 - point.y)
        case .landscapeRight: CGPoint(x: 1 - point.y, y: point.x)
        }
    }

    /// Where a framebuffer point lies in the interface. The inverse of `framebufferPoint`.
    func interfacePoint(_ point: CGPoint) -> CGPoint {
        switch self {
        case .portrait: point
        case .landscapeLeft: CGPoint(x: 1 - point.y, y: point.x)
        case .upsideDown: CGPoint(x: 1 - point.x, y: 1 - point.y)
        case .landscapeRight: CGPoint(x: point.y, y: 1 - point.x)
        }
    }

    /// The framebuffer edge under the interface's bottom edge, as SimulatorKit numbers edges:
    /// 1 left, 2 top, 3 bottom, 4 right.
    private var bottomEdge: Int {
        switch self {
        case .portrait: 3
        case .landscapeLeft: 4
        case .upsideDown: 2
        case .landscapeRight: 1
        }
    }

    /// A touch that starts in the bottom 7% of the interface is the swipe home. SimulatorKit wants
    /// that touch tagged with the framebuffer edge it starts from. Nil for any other touch.
    func homeEdge(atFramebufferPoint point: CGPoint) -> Int? {
        interfacePoint(point).y >= 0.93 ? bottomEdge : nil
    }
}
