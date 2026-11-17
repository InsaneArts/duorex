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
        sim.onFrame = { [unowned self] in frame = $0 }
        sim.onReport = { [unowned self] in report = $0 }
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
        sim.stop()
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
                guard await fold(from: hinge, to: target) else { break }
                hinge = target
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
        let expected = target < 90 ? Panel.cover : .inner
        guard await wait(seconds: 4, until: { report?.hingeDegrees.map { abs($0 - target) < 10 } ?? false }),
              await wait(seconds: 4, until: { litPanel == expected }) else { return false }
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
