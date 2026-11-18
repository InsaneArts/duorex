import CoreGraphics
import CoreVideo
import Foundation
import VideoToolbox

/// Drives a simulator from outside a pane, as a sweep and an agent do: it folds and turns the
/// simulator at a hand's pace, waits until the simulator has done it, and takes its screen.
final class SimDriver {
    private let sim: Sim
    private var frame: CVPixelBuffer?
    private(set) var report: SimWire.Report?

    init(sim: Sim) {
        self.sim = sim
        // The connection can outlive this driver, and a picture can still be on its way.
        sim.onFrame = { [weak self] in self?.frame = $0 }
        sim.onReport = { [weak self] in self?.report = $0 }
    }

    /// The lit screen as the simulator drew it last, or nil before its first picture.
    var screen: CGImage? {
        frame.flatMap(Self.image)
    }

    /// How the interface is turned inside the lit panel's framebuffer.
    var interface: Orientation {
        report.flatMap { Orientation(rawValue: $0.orientation) } ?? .portrait
    }

    func stop() {
        sim.onFrame = nil
        sim.onReport = nil
        sim.stop()
    }

    /// How the device is now, in a few words for an agent: which screen is lit and its size as
    /// the interface sees it, the hinge angle, and how the device is held.
    var summary: String {
        guard let screen, let panel = litPanel else { return "no picture from the simulator yet" }
        let turned = interface.quarterTurnsToUpright % 2 == 1
        let size = turned ? "\(screen.height)x\(screen.width)" : "\(screen.width)x\(screen.height)"
        let hinge = report?.hingeDegrees.map { "hinge \(Int($0.rounded()))" } ?? "hinge unknown"
        let held = report?.duoViewOrientation.flatMap(Orientation.init(rawValue:))?.label ?? "upright"
        return "\(panel.rawValue) screen \(size), \(hinge), held \(held)"
    }

    // MARK: An agent's hands

    /// Taps the lit screen. `point` is on the screen as it shows upright: x runs right and y
    /// runs down, each from 0 to 1.
    func tap(at point: CGPoint) async {
        let place = interface.framebufferPoint(point)
        await send(.touch(.begin, x: place.x, y: place.y, edge: nil))
        try? await Task.sleep(for: .milliseconds(60))
        await send(.touch(.end, x: place.x, y: place.y, edge: nil))
    }

    /// Moves a finger across the lit screen in `seconds`. A swipe that starts at the bottom
    /// edge goes home, as on the device.
    func swipe(from start: CGPoint, to end: CGPoint, seconds: Double) async {
        let first = interface.framebufferPoint(start), last = interface.framebufferPoint(end)
        let edge = interface.homeEdge(atFramebufferPoint: first)
        let steps = max(Int((seconds.isFinite ? min(max(seconds, 0), 10) : 0.25) * 60), 2)
        await send(.touch(.begin, x: first.x, y: first.y, edge: edge))
        for step in 1...steps {
            try? await Task.sleep(for: .milliseconds(16))
            let share = Double(step) / Double(steps)
            await send(.touch(.move, x: first.x + (last.x - first.x) * share, y: first.y + (last.y - first.y) * share, edge: edge))
        }
        await send(.touch(.end, x: last.x, y: last.y, edge: edge))
    }

    /// Presses a hardware button and lets it go.
    func press(_ button: HardwareButton) async {
        await send(.button(button, pressed: true))
        try? await Task.sleep(for: .milliseconds(90))
        await send(.button(button, pressed: false))
    }

    /// Sends a message and returns when it is out, so a command that ends next does not cut it off.
    private func send(_ message: SimWire.Message) async {
        await withCheckedContinuation { continuation in
            sim.send(message) { continuation.resume() }
        }
    }

    /// Connects to the simulator, and returns the pose it is in.
    func connect() async throws -> (hinge: Double, held: Orientation) {
        sim.start()
        guard await wait(seconds: 20, until: { frame != nil && report != nil }) else {
            throw DuoError.sim("the simulator sent no picture. Is it booted?")
        }
        // A server that just started reports the hinge a moment after its first report.
        _ = await wait(seconds: 3) { report?.hingeDegrees != nil }
        return (report?.hingeDegrees ?? (litPanel == .cover ? 0 : 180),
                report?.duoViewOrientation.flatMap(Orientation.init(rawValue:)) ?? .portrait)
    }

    /// The lit screen as the simulator draws it at each of some hinge angles, held upright.
    /// The simulator is folded and turned for the pictures, and put back after.
    func screens(at hinges: [Double]) async throws -> [CGImage] {
        let start = try await connect()
        var screens: [CGImage] = []
        var hinge = start.hinge
        if await turn(to: .portrait) {
            for target in hinges {
                let moved = hinge != target
                let reached = await fold(from: hinge, to: target)
                // Reached or not, the fold went out. The way back starts from there.
                hinge = target
                guard reached else { break }
                // The interface lays out again after a fold. A panel that just came on is black until the app draws on it.
                if moved { try? await Task.sleep(for: .milliseconds(900)) }
                _ = await wait(seconds: 5) { screen.map { !Self.isBlank($0) } ?? false }
                guard !Task.isCancelled, let screen else { break }
                screens.append(screen)
            }
        }
        let from = hinge
        await Task {
            _ = await turn(to: start.held)
            _ = await fold(from: from, to: start.hinge)
        }.value
        stop()
        try Task.checkCancellation()
        guard screens.count == hinges.count else { throw DuoError.sim("the simulator did not fold for the pictures.") }
        return screens
    }

    /// The lit screen once the interface has laid out again after a fold or a turn. A panel
    /// that just came on is black until the app draws on it.
    func settledScreen() async -> CGImage? {
        try? await Task.sleep(for: .milliseconds(900))
        _ = await wait(seconds: 5) { screen.map { !Self.isBlank($0) } ?? false }
        return Task.isCancelled ? nil : screen
    }

    /// Moves the hinge in small steps, as a hand does. A jump can leave the iOS 27.1 simulator on the wrong screen.
    /// Returns false when the simulator does not report the angle or does not light the right panel.
    func fold(from start: Double, to target: Double) async -> Bool {
        let before = litPanel
        let steps = 14
        for step in 1...steps where start != target {
            let t = Double(step) / Double(steps)
            let eased = t * t * (3 - 2 * t)
            sim.send(.fold(degrees: start + (target - start) * eased))
            try? await Task.sleep(for: .milliseconds(45))
        }
        // When the angle before is a guess, the simulator may not be there. Tell it the angle once.
        if start == target { sim.send(.fold(degrees: target)) }
        guard await wait(seconds: 4, until: { report?.hingeDegrees.map { abs($0 - target) < 10 } ?? false }) else { return false }
        // Near shut the cover is lit, and from a book on the inner screen. Between the two,
        // iOS keeps the panel it had, so either one is right there.
        if let expected = target <= 30 ? Panel.cover : target >= 125 ? .inner : nil {
            guard await wait(seconds: 4, until: { litPanel == expected }) else { return false }
        }
        guard litPanel != before else { return true }
        // The other panel came on. The simulator reports the new panel at once, but how the
        // interface is turned in it only after its next look, up to a second later.
        _ = await wait(seconds: 3) { report?.width.map { abs($0 - (frame.map(CVPixelBufferGetWidth) ?? 0)) <= 2 } ?? false }
        try? await Task.sleep(for: .milliseconds(1300))
        return true
    }

    /// The panel the newest picture shows.
    var litPanel: Panel? {
        frame.map { Panel(framebufferWidth: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0)) }
    }

    /// Returns false when the simulator does not report the turn.
    func turn(to held: Orientation) async -> Bool {
        guard report?.duoViewOrientation != held.rawValue else { return true }
        sim.send(.rotate(held))
        guard await wait(seconds: 4, until: { report?.duoViewOrientation == held.rawValue }) else { return false }
        try? await Task.sleep(for: .milliseconds(700))
        return true
    }

    /// Waits until `condition` holds. Returns false when it does not within `seconds`.
    func wait(seconds: Double, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            // A cancelled task's sleep returns at once, so without this check the loop would spin.
            guard Date() < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    /// True for a picture with nothing in it: every pixel is black.
    private static func isBlank(_ image: CGImage) -> Bool {
        let side = 24
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return false }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: side * side * 4)
        return !stride(from: 0, to: pixels.count, by: 4).contains { max(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) > 10 }
    }

    private static func image(from frame: CVPixelBuffer) -> CGImage? {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(frame, options: nil, imageOut: &image)
        return image
    }
}
