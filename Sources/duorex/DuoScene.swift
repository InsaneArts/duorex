import AppKit
import Metal
import RealityKit

enum DuoError: Error, CustomStringConvertible {
    case model(String)
    case render(String)
    case sim(String)
    case terminal(String)

    var description: String {
        switch self {
        case .model(let reason): "Duo model: \(reason)"
        case .render(let reason): "Render: \(reason)"
        case .sim(let reason): "Simulator: \(reason)"
        case .terminal(let reason): reason
        }
    }
}

/// The 3D iPhone Duo: Apple's model from the selected Xcode, a fold rig, and two live screens.
/// The model lookup, fold rig and screen slots follow serve-sim's DuoRenderer (Apache-2.0).
final class DuoScene {
    let device: MTLDevice
    private let renderer: RealityRenderer
    private let orbit = Entity()
    private let rest = Entity()
    private let subject: Entity
    /// The one skinned mesh the whole device is made of.
    private let body: ModelEntity
    /// The joints of the mesh at each step of the fold, from flat to closed. Posing the joints
    /// from this table, and not from the model's clip, leaves them free for the buttons too.
    private let foldPoses: [[Transform]]
    private let buttons: HardwareButtons
    private let camera = PerspectiveCamera()
    private let slots: [Panel: (entity: ModelEntity, material: Int)]
    private let surfaces: [Panel: ScreenSurface]
    private let flatBounds: BoundingBox
    private(set) var pose = Pose()
    private var aspect: Float = 1

    /// A 36 mm sensor behind a 105 mm lens: enough perspective to read as an object, not a diagram.
    private let fieldOfView: Float = 2 * atan(36 / (2 * 105.0)) * 180 / .pi
    /// The fold clip runs from flat to closed over its first five seconds.
    private static let foldClip = (name: "l_over_r", seconds: 5.0)
    /// The fold is baked in steps of two degrees. Angles in between are blended.
    private static let foldSteps = 90
    /// How near the pointer must be to a button to be on it, as a share of the device's height.
    private static let buttonReach: Float = 0.08
    /// How far past the glass still counts as the frame, in framebuffer units.
    private static let frameWidth: Float = 0.09
    private static let screenMaterials: [Panel: String] = [.cover: "YqugYDOqMSOpqyA", .inner: "CvyXbAGXoolRUYl"]

    /// Apple's Duo model inside the selected Xcode. It is read in place and never copied.
    static func modelURL() async throws -> URL {
        let developer = if let chosen = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] { chosen } else { try await Shell.run("/usr/bin/xcode-select", ["-p"]) }
        let url = URL(fileURLWithPath: developer)
            .appendingPathComponent("../SharedFrameworks/DeviceKit.framework/Versions/A/PlugIns/CoreDevicePopDeviceKitExtension.devicekitplugin/Contents/Resources/V68.usdz")
            .standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DuoError.model("not found at \(url.path). duorex needs Xcode 27.1 or later.")
        }
        return url
    }

    /// `finish` is the model's color configuration: "Dark" or "Light".
    init(finish: String = "Dark") async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw DuoError.render("no Metal device") }
        self.device = device
        renderer = try RealityRenderer()
        let catalog = try await Entity.ConfigurationCatalog(from: try await Self.modelURL())
        let loaded = try await Entity(from: catalog, configurations: ["color": finish])
        subject = loaded.findEntity(named: "root") ?? loaded
        guard let clip = subject.availableAnimations.first(where: { $0.name == Self.foldClip.name && $0.definition.duration.isFinite }) else {
            throw DuoError.model("the fold animation is missing")
        }
        var slots: [Panel: (entity: ModelEntity, material: Int)] = [:]
        for (panel, name) in Self.screenMaterials {
            guard let slot = Self.slot(in: subject, material: name) else { throw DuoError.model("the \(panel.rawValue) screen is missing") }
            slots[panel] = slot
        }
        self.slots = slots
        // The inner framebuffer is authored a quarter turn from its mesh coordinates.
        try Self.rotateCoordinates(on: slots[.inner]!.entity, material: slots[.inner]!.material)
        surfaces = [
            .cover: try ScreenSurface(entity: slots[.cover]!.entity, material: slots[.cover]!.material, split: false),
            .inner: try ScreenSurface(entity: slots[.inner]!.entity, material: slots[.inner]!.material, split: true),
        ]

        subject.removeFromParent()
        rest.addChild(subject)
        orbit.addChild(rest)
        rest.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        subject.position -= subject.visualBounds(relativeTo: rest).center
        flatBounds = subject.visualBounds(relativeTo: orbit)
        renderer.entities.append(orbit)

        camera.camera.fieldOfViewInDegrees = fieldOfView
        camera.camera.near = 0.01
        camera.camera.far = 100
        renderer.entities.append(camera)
        renderer.activeCamera = camera
        renderer.lighting.resource = try StudioLight.environment()
        renderer.cameraSettings.antialiasing = .multisample4X
        renderer.cameraSettings.colorBackground = .color(CGColor(red: 0, green: 0, blue: 0, alpha: 0))

        let body = slots[.inner]!.entity
        self.body = body
        buttons = try HardwareButtons(entity: body)
        let playback = subject.playAnimation(clip, transitionDuration: 0, startsPaused: true)
        var poses: [[Transform]] = []
        for step in 0...Self.foldSteps {
            playback.time = Double(step) / Double(Self.foldSteps) * Self.foldClip.seconds
            // The clip's pose reaches the joints one update after its time changes.
            try renderer.update(1.0 / 60)
            try renderer.update(1.0 / 60)
            poses.append(body.jointTransforms)
        }
        // A stopped clip lets go of the joints only at the next update. Until then it undoes a pose set by hand.
        playback.stop()
        try renderer.update(1.0 / 60)
        foldPoses = poses
        for panel in [Panel.cover, .inner] { setScreen(panel, texture: nil) }
        apply(pose)
    }

    /// Shows `texture` on a screen, or turns the screen off with nil.
    func setScreen(_ panel: Panel, texture: TextureResource?) {
        guard let slot = slots[panel] else { return }
        // The screen is a light source: unlit, and outside the tone mapping the body gets.
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        if let texture {
            // Trilinear and anisotropic filtering keep text readable on a tilted leaf.
            let sampler = MTLSamplerDescriptor()
            sampler.minFilter = .linear
            sampler.magFilter = .linear
            sampler.mipFilter = .linear
            sampler.maxAnisotropy = 8
            material.color = .init(tint: .white, texture: .init(texture, sampler: .init(sampler)))
        } else {
            material.color = .init(tint: .black)
        }
        slot.entity.model?.materials[slot.material] = material
    }

    func apply(_ pose: Pose) {
        self.pose = pose
        let hinge = min(max(pose.hinge, 0), 180)
        let raise = Float((180 - hinge) * .pi / 180)
        // Turn the device so both leaves face the camera equally while it is partly open.
        let bisect = simd_quatf(angle: -min(raise, Float(hinge * .pi / 180)) / 2, axis: [0, 1, 0])
        let step = (180 - hinge) / 180 * Double(Self.foldSteps)
        let lower = min(Int(step), Self.foldSteps - 1)
        var joints = Self.blend(foldPoses[lower], foldPoses[lower + 1], Float(step - Double(lower)))
        if let press = pose.press { buttons.push(press.button, depth: Float(press.depth), in: &joints) }
        body.jointTransforms = joints
        rest.orientation = bisect * simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        // Keep the folded shape centered: the hinge moves off center as one leaf lifts.
        let half = flatBounds.extents.x / 2
        let lifted = simd_quatf(angle: raise, axis: [0, 1, 0]).act([-half, 0, 0])
        let xs = [lifted, .zero, SIMD3<Float>(half, 0, 0)].map { bisect.act($0).x }
        rest.position.x = -(xs.min()! + xs.max()!) / 2
        orbit.orientation = simd_quatf(angle: Float(pose.yaw * .pi / 180), axis: [0, 1, 0])
            * simd_quatf(angle: Float(pose.pitch * .pi / 180), axis: [1, 0, 0])
            * simd_quatf(angle: Float(pose.roll * .pi / 180), axis: [0, 0, 1])
        frameCamera()
    }

    /// Draws `pose` into `frame`, and returns when the picture is ready.
    func draw(_ pose: Pose, into frame: Frame) async throws {
        apply(pose)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try render(into: frame) { continuation.resume() }
            } catch { continuation.resume(throwing: error) }
        }
    }

    /// Draws one frame of the current pose. `onComplete` runs when the picture is ready, on any thread.
    func render(into frame: Frame, onComplete: @escaping @Sendable () -> Void) throws {
        let newAspect = Float(frame.width) / Float(frame.height)
        if newAspect != aspect {
            aspect = newAspect
            frameCamera()
        }
        try renderer.updateAndRender(deltaTime: 1.0 / 60, cameraOutput: frame.output, onComplete: { _ in onComplete() })
    }

    /// What the scene has under a point of the view. `point` is 0...1 with the origin at the top left.
    func probe(at point: CGPoint, panel: Panel) -> Probe {
        let tangent = tan(fieldOfView * .pi / 360)
        // A button is small, so the pointer only has to be near it. The nearest one wins.
        let overButtons = buttons.worldCenters().map { button, center -> (button: HardwareButton, distance: Float) in
            let depth = camera.position.z - center.z
            let x = 0.5 + center.x / (depth * tangent * aspect) / 2, y = 0.5 - center.y / (depth * tangent) / 2
            return (button, hypot((x - Float(point.x)) * aspect, y - Float(point.y)))
        }
        // The reach is measured on the device as drawn, so it stays the same part of the frame in any pane.
        let reach = Self.buttonReach * flatBounds.extents.y / (camera.position.z * tangent * 2)
        let button = overButtons.filter { $0.distance <= reach }.min { $0.distance < $1.distance }?.button
        guard let surface = surfaces[panel] else { return Probe(button: button) }
        let direction = simd_normalize(SIMD3<Float>((Float(point.x) * 2 - 1) * aspect * tangent, (1 - Float(point.y) * 2) * tangent, -1))
        let hits = surface.worldLeaves().compactMap { $0.intersect(origin: camera.position, direction: direction) }
        guard let nearest = hits.min(by: { ($0.outside, $0.distance) < ($1.outside, $1.distance) }) else { return Probe(button: button) }
        let onScreen = CGPoint(x: CGFloat(nearest.uv.x), y: CGFloat(nearest.uv.y))
        // On the glass the pointer touches the screen, however near a button is.
        let onGlass = nearest.outside == 0
        return Probe(glass: onGlass ? onScreen : nil, nearest: onScreen,
                     onFrame: !onGlass && nearest.outside <= Self.frameWidth, button: onGlass ? nil : button)
    }

    /// Backs the camera off until the device, as it is folded and turned now, just fits the view.
    /// The camera follows a fold or a turn, so the device stays as large as the view allows.
    private func frameCamera() {
        let open = Float(min(max(pose.hinge, 0), 180) / 180)
        let width = flatBounds.extents.x * (0.5 + 0.5 * open), height = flatBounds.extents.y
        // The box the device covers once it is turned about the view axis.
        let turn = Float(pose.roll * .pi / 180)
        let across = abs(cos(turn)) * width + abs(sin(turn)) * height
        let up = abs(sin(turn)) * width + abs(cos(turn)) * height
        let tangent = tan(fieldOfView * .pi / 360)
        // The margin leaves room for a tilt. Half folded, a leaf swings toward the camera and looks larger.
        let margin = 1.22 + 0.16 * sin(open * .pi)
        camera.position = [0, 0, max(up / 2 / tangent, across / 2 / (tangent * aspect)) * margin]
    }

    /// The joints part of the way from one pose to another.
    private static func blend(_ from: [Transform], _ to: [Transform], _ amount: Float) -> [Transform] {
        zip(from, to).map { a, b in
            Transform(scale: simd_mix(a.scale, b.scale, SIMD3(repeating: amount)),
                      rotation: simd_slerp(a.rotation, b.rotation, amount),
                      translation: simd_mix(a.translation, b.translation, SIMD3(repeating: amount)))
        }
    }

    private static func slot(in entity: Entity, material name: String) -> (entity: ModelEntity, material: Int)? {
        if let model = entity as? ModelEntity, let index = model.model?.materials.firstIndex(where: { $0.name == name }) { return (model, index) }
        for child in entity.children { if let found = slot(in: child, material: name) { return found } }
        return nil
    }

    private static func rotateCoordinates(on entity: ModelEntity, material: Int) throws {
        guard let model = entity.model else { return }
        var contents = model.mesh.contents
        contents.models = .init(contents.models.map { mesh in
            var mesh = mesh
            mesh.parts = .init(mesh.parts.map { part in
                guard part.materialIndex == material, let coordinates = part.textureCoordinates else { return part }
                var part = part
                part.textureCoordinates = .init(coordinates.elements.map { SIMD2<Float>(1 - $0.y, $0.x) })
                return part
            })
            return mesh
        })
        try model.mesh.replace(with: contents)
        entity.model = model
    }
}
