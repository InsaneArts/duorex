import CoreGraphics
import Foundation
import RealityKit

/// What a film shows at one moment: the device's pose, how near the camera is, and how bright each screen is.
nonisolated struct FilmShot: Equatable {
    var pose: Pose
    var zoom: Double
    var coverBrightness: Double
    var innerBrightness: Double
    /// True while the inner screen shows the app as it lays out on a half-open device.
    var showsBook: Bool
}

/// The script of the film: ten seconds with no hand on the device. It turns while shut, opens
/// as it comes round to the front, the camera moves in on the app, and it folds to a book.
nonisolated enum FilmScript {
    private struct Key {
        var time: Double, hinge: Double, yaw: Double, pitch: Double, zoom: Double
    }

    /// The hinge angle of the half-open device at the end.
    static let book = 130.0
    static let seconds = 10.0
    static let framesPerSecond = 60

    private static let keys = [
        Key(time: 0.0, hinge: 0, yaw: -40, pitch: 10, zoom: 0.74),
        Key(time: 1.6, hinge: 0, yaw: -16, pitch: 6, zoom: 0.8),
        Key(time: 4.2, hinge: 180, yaw: 9, pitch: -4, zoom: 0.84),
        Key(time: 6.6, hinge: 180, yaw: -12, pitch: -8, zoom: 0.93),
        Key(time: 8.6, hinge: book, yaw: 16, pitch: -6, zoom: 0.86),
        Key(time: 10.0, hinge: book, yaw: 10, pitch: -4, zoom: 0.89),
    ]

    static func shot(at time: Double) -> FilmShot {
        let time = min(max(time, 0), seconds)
        let next = keys.firstIndex { $0.time > time } ?? keys.count - 1
        let from = keys[max(next - 1, 0)], to = keys[next]
        let share = to.time > from.time ? (time - from.time) / (to.time - from.time) : 1
        // The hinge eases from stop to stop. The camera never stops: it runs through each key
        // on a curve, so the film is one move and not six.
        let eased = share * share * (3 - 2 * share)
        let hinge = from.hinge + (to.hinge - from.hinge) * eased
        func curve(_ value: (Key) -> Double) -> Double {
            let before = value(keys[max(next - 2, 0)]), after = value(keys[min(next + 1, keys.count - 1)])
            let a = value(from), b = value(to), t = share
            return 0.5 * (2 * a + (b - before) * t + (2 * before - 5 * a + 4 * b - after) * t * t + (3 * a - before - 3 * b + after) * t * t * t)
        }
        // The cover goes dark as the device opens, and the app comes up on the inner screen.
        func ramp(_ value: Double, from low: Double, to high: Double) -> Double { min(max((value - low) / (high - low), 0), 1) }
        return FilmShot(pose: Pose(hinge: hinge, yaw: curve(\.yaw), pitch: curve(\.pitch)), zoom: curve(\.zoom),
                        coverBrightness: 1 - ramp(hinge, from: 35, to: 80), innerBrightness: ramp(hinge, from: 40, to: 95),
                        showsBook: time > 6.6 && hinge < 158)
    }
}

/// Makes the film: it takes the app's screens from the simulator, draws each picture of the
/// script, and writes the movie. It draws at its own pace, so every picture is in the movie.
final class Film {
    private let scene: DuoScene

    init(scene: DuoScene) {
        self.scene = scene
    }

    /// `screens` are the cover of the shut device, the inner screen of the open one, and the
    /// inner screen of the half-open one. `progress` gets the share that is done, from 0 to 1.
    func write(screens: (cover: TextureResource, open: TextureResource, book: TextureResource), to url: URL, width: Int, height: Int,
               progress: (Double) -> Void) async throws {
        let recorder = try Recorder(scene: scene, url: url, width: width, height: height)
        let frames = Int(FilmScript.seconds) * FilmScript.framesPerSecond
        for index in 0..<frames {
            try Task.checkCancellation()
            let time = Double(index) / Double(FilmScript.framesPerSecond)
            let shot = FilmScript.shot(at: time)
            scene.setScreen(.cover, texture: screens.cover, brightness: shot.coverBrightness)
            scene.setScreen(.inner, texture: shot.showsBook ? screens.book : screens.open, brightness: shot.innerBrightness)
            scene.zoom = Float(shot.zoom)
            scene.apply(shot.pose)
            await recorder.add(scene: scene, time: time)
            if index % FilmScript.framesPerSecond == 0 { progress(Double(index) / Double(frames)) }
        }
        try await recorder.finish(scene: scene, time: FilmScript.seconds)
    }
}
