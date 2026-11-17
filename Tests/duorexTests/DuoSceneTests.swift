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
