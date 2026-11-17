import AppKit
import RealityKit

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

    private let driver: SimDriver
    private let scene: DuoScene

    init(sim: Sim, scene: DuoScene) {
        driver = SimDriver(sim: sim)
        self.scene = scene
    }

    /// Runs the sweep, puts the simulator back the way it was, and returns the shots in order.
    /// `progress` gets a line for each stop. It throws when the simulator does not reach a
    /// posture, and when the task is cancelled. Either way the simulator is put back first.
    func run(progress: (String) -> Void) async throws -> [Shot] {
        let start = try await driver.connect()

        var shots: [Shot] = []
        var hinge = start.hinge
        var failure: DuoError?
        sweep: for held in Self.holds {
            guard await driver.turn(to: held) else {
                failure = .sim("the simulator did not turn. The sweep stopped.")
                break
            }
            for posture in Self.postures {
                let reached = await driver.fold(from: hinge, to: posture.hinge)
                hinge = posture.hinge
                guard reached else {
                    failure = .sim("the simulator did not fold to \(posture.name.lowercased()). The sweep stopped.")
                    break sweep
                }
                guard let screen = await driver.settledScreen() else { break sweep }
                var shot = Shot(posture: posture, held: held, screen: screen,
                                panel: Panel(framebufferWidth: screen.width, height: screen.height),
                                interface: driver.interface, hinge: driver.report?.hingeDegrees)
                shot.device = try? await picture(of: shot)
                shots.append(shot)
                progress("\(posture.name.lowercased()), held \(held.label): \(shot.panel.rawValue) screen, \(screen.width)x\(screen.height)")
            }
        }
        // The way back runs in a task of its own. A cancelled sweep still folds back at a hand's pace.
        let from = hinge
        await Task {
            _ = await driver.turn(to: start.held)
            _ = await driver.fold(from: from, to: start.hinge)
        }.value
        driver.stop()
        try Task.checkCancellation()
        if let failure { throw failure }
        return shots
    }

    /// The device in a shot's posture, with the shot's screen on it.
    private func picture(of shot: Shot) async throws -> CGImage? {
        guard let frame = Frame(device: scene.device, width: 720, height: 560) else { return nil }
        scene.setScreen(shot.panel, texture: try await TextureResource(image: shot.screen, options: .init(semantic: .color)))
        scene.setScreen(shot.panel.other, texture: nil)
        try await scene.draw(Pose(hinge: shot.posture.hinge, roll: shot.held.roll), into: frame)
        return frame.image()
    }
}

extension Orientation {
    /// The name in a caption.
    var label: String {
        switch self {
        case .portrait: "upright"
        case .landscapeLeft: "turned clockwise"
        case .upsideDown: "upside down"
        case .landscapeRight: "turned counterclockwise"
        }
    }

    /// Quarter turns clockwise that show a framebuffer picture with its interface upright.
    var quarterTurnsToUpright: Int {
        Self.allCases.firstIndex(of: self)!
    }
}
