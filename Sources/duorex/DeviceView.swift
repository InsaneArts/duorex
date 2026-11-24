import AppKit

/// What a session needs of the view that draws the device: iPhone Duo in 3D, or another iPhone flat.
/// Pointer positions are in view points with the origin at the top left.
protocol DeviceView: NSView {
    /// What the user's motion asks of the simulator.
    var onEffect: ((DeviceMotion.Effect) -> Void)? { get set }
    /// The pointer came to rest on a hardware button, or left it.
    var onHover: ((HardwareButton?) -> Void)? { get set }
    /// Another client of the simulator did something, or has been quiet for a moment.
    var onActivity: ((SimWire.Activity?) -> Void)? { get set }
    /// True while a press that began on the device is still held.
    var isDragging: Bool { get }
    /// Whether the screen lights the pane around the device.
    var glows: Bool { get set }
    /// Frames drawn since the last reading, for the frame rate in the debug log.
    var framesDrawn: Int { get }
    func resetFrameCount()
    /// Asks for a new frame, as when a screen changed.
    func setNeedsRender()

    func pointerDown(at point: CGPoint, option: Bool)
    /// `pressed` is whether the terminal says that a button is down.
    func pointerMoved(to point: CGPoint, option: Bool, pressed: Bool)
    func pointerUp(at point: CGPoint)
    /// The pointer left the pane.
    func pointerLeft()
    /// One wheel step. Positive `lines` scrolls the content down.
    func scroll(at point: CGPoint, lines: Double)

    /// Animates the device to a roll, in degrees.
    func rotate(to degrees: Double)
    /// Takes something another client did to the simulator. Its touches show on the screen.
    func saw(_ activity: SimWire.Activity)
}

extension StageView: DeviceView {}
