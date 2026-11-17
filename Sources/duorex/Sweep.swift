import AppKit
import CoreVideo
import RealityKit
import VideoToolbox

/// Folds the simulator through its postures and both ways of holding it, and saves one
/// picture of them all. It answers "does my layout hold on a Duo?" in a few seconds.
final class Sweep {
    /// One stop of the sweep.
    struct Posture {
        var name: String
        var hinge: Double
    }

    /// One captured stop.
    struct Shot {
        var posture: Posture
        var held: Orientation
        /// The lit panel's framebuffer, as the simulator drew it.
        var screen: CGImage
        var panel: Panel
        /// How the interface is turned inside the framebuffer.
        var interface: Orientation
        /// The hinge angle the simulator reported.
        var hinge: Double?
        /// The device in this posture, with the screen on it.
        var device: CGImage?
    }

    static let postures = [Posture(name: "Closed", hinge: 0), Posture(name: "Book", hinge: 130), Posture(name: "Open", hinge: 180)]
    static let holds = [Orientation.portrait, .landscapeLeft]

    private let sim: Sim
    private let scene: DuoScene
    private var frame: CVPixelBuffer?
    private var report: SimWire.Report?

    init(sim: Sim, scene: DuoScene) {
        self.sim = sim
        self.scene = scene
        sim.onFrame = { [unowned self] in frame = $0 }
        sim.onReport = { [unowned self] in report = $0 }
    }

    /// Runs the sweep, puts the simulator back the way it was, and returns the shots in order.
    /// `progress` gets a line for each stop.
    func run(progress: (String) -> Void) async throws -> [Shot] {
        sim.start()
        guard await wait(seconds: 20, until: { frame != nil && report != nil }), let first = report, let firstFrame = frame else {
            throw DuoError.sim("the simulator sent no picture. Is it booted?")
        }
        let startPanel = Panel(framebufferWidth: CVPixelBufferGetWidth(firstFrame), height: CVPixelBufferGetHeight(firstFrame))
        let startHinge = first.hingeDegrees ?? (startPanel == .cover ? 0 : 180)
        let startHeld = first.duoViewOrientation.flatMap(Orientation.init(rawValue:)) ?? .portrait

        var shots: [Shot] = []
        var hinge = startHinge
        for held in Self.holds {
            await turn(to: held)
            for posture in Self.postures {
                await fold(from: hinge, to: posture.hinge)
                hinge = posture.hinge
                // The interface lays out again after the fold. Give it time to finish.
                try await Task.sleep(for: .milliseconds(900))
                // A panel that just came on is black until the app draws on it.
                _ = await wait(seconds: 5) { frame.flatMap(Self.image).map { !Self.isBlank($0) } ?? false }
                guard let frame, let screen = Self.image(from: frame) else { continue }
                var shot = Shot(posture: posture, held: held, screen: screen,
                                panel: Panel(framebufferWidth: screen.width, height: screen.height),
                                interface: report.flatMap { Orientation(rawValue: $0.orientation) } ?? .portrait,
                                hinge: report?.hingeDegrees)
                shot.device = try? await picture(of: shot)
                shots.append(shot)
                progress("\(posture.name.lowercased()), held \(held.label): \(shot.panel.rawValue) screen, \(screen.width)x\(screen.height)")
            }
        }
        await turn(to: startHeld)
        await fold(from: hinge, to: startHinge)
        sim.stop()
        return shots
    }

    /// Moves the hinge in small steps, as a hand does. A jump can leave the iOS 27.1 simulator on the wrong screen.
    private func fold(from start: Double, to target: Double) async {
        let steps = 14
        for step in 1...steps where start != target {
            let t = Double(step) / Double(steps)
            let eased = t * t * (3 - 2 * t)
            sim.send(.fold(degrees: start + (target - start) * eased))
            try? await Task.sleep(for: .milliseconds(45))
        }
        _ = await wait(seconds: 4) { report?.hingeDegrees.map { abs($0 - target) < 10 } ?? false }
        let before = litPanel
        let expected = target < 90 ? Panel.cover : .inner
        _ = await wait(seconds: 4) { litPanel == expected }
        guard litPanel != before else { return }
        // The other panel came on. The simulator reports the new panel at once, but how the
        // interface is turned in it only after its next look, up to a second later.
        _ = await wait(seconds: 3) { report?.width.map { abs($0 - (frame.map(CVPixelBufferGetWidth) ?? 0)) <= 2 } ?? false }
        try? await Task.sleep(for: .milliseconds(1300))
    }

    /// The panel the newest picture shows.
    private var litPanel: Panel? {
        frame.map { Panel(framebufferWidth: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0)) }
    }

    private func turn(to held: Orientation) async {
        guard report?.duoViewOrientation != held.rawValue else { return }
        sim.send(.rotate(held))
        _ = await wait(seconds: 4) { report?.duoViewOrientation == held.rawValue }
        try? await Task.sleep(for: .milliseconds(700))
    }

    /// Waits until `condition` holds. Returns false when it does not within `seconds`.
    private func wait(seconds: Double, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    /// The device in a shot's posture, with the shot's screen on it.
    private func picture(of shot: Shot) async throws -> CGImage? {
        guard let frame = Frame(device: scene.device, width: 720, height: 560) else { return nil }
        scene.setScreen(shot.panel, texture: try await TextureResource(image: shot.screen, options: .init(semantic: .color)))
        scene.setScreen(shot.panel.other, texture: nil)
        try await scene.draw(Pose(hinge: shot.posture.hinge, roll: shot.held.roll), into: frame)
        return frame.image()
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

extension Orientation {
    /// The name in a caption.
    var label: String {
        switch self {
        case .portrait: "upright"
        case .landscapeLeft: "turned left"
        case .upsideDown: "upside down"
        case .landscapeRight: "turned right"
        }
    }

    /// Quarter turns clockwise that show a framebuffer picture with its interface upright.
    var quarterTurnsToUpright: Int {
        Self.allCases.firstIndex(of: self)!
    }
}
