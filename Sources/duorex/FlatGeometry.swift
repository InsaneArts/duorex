import CoreGraphics
import Foundation

/// Where a flat device lies in its view, and what lies under a point of the view.
///
/// The device is its chrome's canvas: the body with a margin around it for the buttons, in the
/// chrome's points. It sits in the middle of the view, scaled to fit, and turned by `roll`.
/// View points have the origin at the top left, as the pointer has them.
nonisolated struct FlatGeometry: Equatable {
    /// The body, without the buttons, in the chrome's points.
    var body: CGSize
    /// The screen in the body's points.
    var screen: CGRect
    /// Room around the body that the buttons reach into.
    var margin: CGFloat
    /// Where each side button lies in the body's points.
    var buttons: [Placed] = []
    /// The size of the view, in points.
    var view = CGSize(width: 1, height: 1)
    /// How the device is turned, in degrees. A positive roll turns it clockwise on the screen.
    var roll = 0.0

    struct Placed: Equatable {
        var button: HardwareButton
        var frame: CGRect
    }

    /// The share of the view the device takes along its longer fit.
    static let fill = 0.9

    /// The body with room for the buttons.
    var canvas: CGSize { CGSize(width: body.width + margin * 2, height: body.height + margin * 2) }

    /// View points for each of the chrome's points. The device fits the view whichever way it is turned.
    var scale: CGFloat {
        let turn = roll * .pi / 180
        let width = abs(cos(turn)) * canvas.width + abs(sin(turn)) * canvas.height
        let height = abs(sin(turn)) * canvas.width + abs(cos(turn)) * canvas.height
        return min(view.width / width, view.height / height) * Self.fill
    }

    /// A view point as a point of the body.
    func bodyPoint(_ point: CGPoint) -> CGPoint {
        let turn = roll * .pi / 180, scale = scale
        let x = point.x - view.width / 2, y = point.y - view.height / 2
        // Turned back by the roll, then into the canvas, whose middle is the view's middle.
        let backX = x * cos(turn) + y * sin(turn), backY = -x * sin(turn) + y * cos(turn)
        return CGPoint(x: backX / scale + canvas.width / 2 - margin, y: backY / scale + canvas.height / 2 - margin)
    }

    /// A point of the body as a view point. The inverse of `bodyPoint`.
    func viewPoint(_ point: CGPoint) -> CGPoint {
        let turn = roll * .pi / 180, scale = scale
        let x = (point.x + margin - canvas.width / 2) * scale, y = (point.y + margin - canvas.height / 2) * scale
        return CGPoint(x: x * cos(turn) - y * sin(turn) + view.width / 2, y: x * sin(turn) + y * cos(turn) + view.height / 2)
    }

    /// What lies under a view point: the framebuffer point on the glass, or a side button.
    func probe(_ point: CGPoint) -> Probe {
        let at = bodyPoint(point)
        // A button is narrow, so it takes the pointer a few points around it too.
        if let placed = buttons.first(where: { $0.frame.insetBy(dx: -4, dy: -4).contains(at) }) {
            return Probe(button: placed.button)
        }
        let x = (at.x - screen.minX) / screen.width, y = (at.y - screen.minY) / screen.height
        let nearest = CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
        let onGlass = (0...1).contains(x) && (0...1).contains(y)
        return Probe(glass: onGlass ? nearest : nil, nearest: nearest)
    }
}
