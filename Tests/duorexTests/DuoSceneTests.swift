import CoreGraphics
import Foundation
import Testing
@testable import duorex

/// These tests use Apple's model of the device, so they run only where Xcode has it.
private func hasModel() async -> Bool {
    (try? await DuoScene.modelURL()) != nil
}

/// What a grid of points over a square view finds.
@MainActor private func probes(_ scene: DuoScene, panel: Panel) -> [Probe] {
    (0..<60).flatMap { row in
        (0..<60).map { column in
            scene.probe(at: CGPoint(x: (Double(column) + 0.5) / 60, y: (Double(row) + 0.5) / 60), aspect: 1, panel: panel)
        }
    }
}

@MainActor @Test(.enabled("needs the Duo model in Xcode") { await hasModel() })
func `a half-shut device has a frame to take hold of, though its lit screen faces away`() async throws {
    let scene = try await DuoScene()
    // Below 90 degrees the simulator lights the cover, which is then on the far side.
    scene.apply(Pose(hinge: 75))
    let found = probes(scene, panel: .cover)
    #expect(found.contains { $0.onFrame })
    // The cover cannot be touched through the back of the device.
    #expect(!found.contains { $0.glass != nil })
}

@MainActor @Test(.enabled("needs the Duo model in Xcode") { await hasModel() })
func `an open device is touched on its inner screen and held by its frame`() async throws {
    let scene = try await DuoScene()
    scene.apply(Pose(hinge: 180))
    let found = probes(scene, panel: .inner)
    #expect(found.contains { $0.glass != nil })
    #expect(found.contains { $0.onFrame })
    // From behind, there is no glass to touch.
    scene.apply(Pose(hinge: 180, yaw: 180))
    #expect(!probes(scene, panel: .inner).contains { $0.glass != nil })
}

@MainActor @Test(.enabled("needs the Duo model in Xcode") { await hasModel() })
func `a strobe picture has the asked size and shows the half that folds above the half that lies still`() async throws {
    let scene = try await DuoScene()
    scene.setScreen(.inner, texture: try Snapshot.testPattern(label: "INNER", width: 1200, height: 1300))
    let image = try await Strobe.image(scene: scene, width: 640, height: 360)
    #expect(image.width == 640 && image.height == 360)
    // The stage alone is dark. The device and its exposures are not.
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = try #require(CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 64 * 4, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 36))
    let pixels = UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self), count: 64 * 36 * 4)
    // The memory's first row is the picture's top row.
    func lit(rows: Range<Int>) -> Int {
        rows.reduce(0) { count, row in
            count + (0..<64).filter { column in
                let index = (row * 64 + column) * 4
                return max(pixels[index], pixels[index + 1], pixels[index + 2]) > 90
            }.count
        }
    }
    // The upright half reaches into the top part of the picture, and the flat half fills the lower part.
    #expect(lit(rows: 4..<14) > 4)
    #expect(lit(rows: 18..<32) > 30)
    #expect(lit(rows: 0..<2) == 0)
}

@MainActor @Test(.enabled("needs the Duo model in Xcode") { await hasModel() }, .timeLimit(.minutes(1)))
func `a film that is stopped leaves the movie that was there before, and nothing half written`() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("duorex-film-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let movie = folder.appendingPathComponent("keep.mp4")
    try Data("the movie from before".utf8).write(to: movie)
    let scene = try await DuoScene()
    let pattern = try Snapshot.testPattern(label: "X", width: 600, height: 600)
    let filming = Task {
        try await Film(scene: scene).write(screens: (pattern, pattern, pattern), to: movie, width: 640, height: 360) { _ in }
    }
    try await Task.sleep(for: .milliseconds(150))
    filming.cancel()
    await #expect(throws: CancellationError.self) { try await filming.value }
    #expect(try Data(contentsOf: movie) == Data("the movie from before".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["keep.mp4"])
}

@MainActor @Test(.enabled("needs the Duo model in Xcode") { await hasModel() }, .timeLimit(.minutes(1)))
func `a movie that can take no more pictures says so, and does not wait for ever`() async throws {
    let movie = FileManager.default.temporaryDirectory.appendingPathComponent("duorex-stop-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: movie) }
    let scene = try await DuoScene()
    let recorder = try Recorder(scene: scene, url: movie, width: 320, height: 240)
    try await recorder.add(scene: scene, time: 0)
    recorder.cancel()
    await #expect(throws: DuoError.self) { try await recorder.add(scene: scene, time: 1.0 / 60) }
}
