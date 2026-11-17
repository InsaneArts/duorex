import AppKit
import Metal
import RealityKit

enum DuoError: Error, CustomStringConvertible {
    case model(String)
    case render(String)
    case sim(String)

    var description: String {
        switch self {
        case .model(let reason): "Duo model: \(reason)"
        case .render(let reason): "Render: \(reason)"
        case .sim(let reason): "Simulator: \(reason)"
        }
    }
}

/// The 3D iPhone Duo: Apple's model from the selected Xcode, a fold rig, and two live screens.
/// The model lookup, fold rig and screen slots follow serve-sim's DuoRenderer (Apache-2.0).
final class DuoScene {
    enum Panel: String { case cover, inner }

    /// How the device sits in front of the camera. Angles are in degrees.
    struct Pose: Equatable {
        var hinge: Double = 180   // 0 is closed, 180 is flat
        var roll: Double = 0      // rotation about the view axis
        var yaw: Double = 0       // tilt left and right
        var pitch: Double = 0     // tilt up and down
    }

    /// A point on a screen, 0...1 in that panel's framebuffer with the origin at the top left.
    struct ScreenHit {
        var panel: Panel
        var point: CGPoint
    }

    let device: MTLDevice
    private let renderer: RealityRenderer
    private let orbit = Entity()
    private let rest = Entity()
    private let subject: Entity
    private let fold: AnimationPlaybackController
    private let camera = PerspectiveCamera()
    private let slots: [Panel: (entity: ModelEntity, material: Int)]
    private let surfaces: [Panel: ScreenSurface]
    private let flatBounds: BoundingBox
    private var outputs: [ObjectIdentifier: RealityRenderer.CameraOutput] = [:]
    private(set) var pose = Pose()
    private var aspect: Float = 1

    /// A 36 mm sensor behind a 105 mm lens: enough perspective to read as an object, not a diagram.
    private let fieldOfView: Float = 2 * atan(36 / (2 * 105.0)) * 180 / .pi
    /// The fold clip runs from flat to closed over its first five seconds.
    private static let foldClip = (name: "l_over_r", seconds: 5.0)
    private static let screenMaterials: [Panel: String] = [.cover: "YqugYDOqMSOpqyA", .inner: "CvyXbAGXoolRUYl"]

    /// Apple's Duo model inside the selected Xcode. It is read in place and never copied.
    static func modelURL() throws -> URL {
        let developer: String
        if let override = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            developer = override
        } else {
            let select = Process()
            select.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
            select.arguments = ["-p"]
            let pipe = Pipe()
            select.standardOutput = pipe
            try select.run()
            select.waitUntilExit()
            developer = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
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
        let catalog = try await Entity.ConfigurationCatalog(from: Self.modelURL())
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

        fold = subject.playAnimation(clip, transitionDuration: 0, startsPaused: true)
        for panel in [Panel.cover, .inner] { setScreen(panel, texture: nil) }
        apply(pose)
    }

    /// Shows `texture` on a screen, or turns the screen off with nil.
    func setScreen(_ panel: Panel, texture: TextureResource?) {
        guard let slot = slots[panel] else { return }
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = texture.map { .init(tint: .white, texture: .init($0)) } ?? .init(tint: .black)
        slot.entity.model?.materials[slot.material] = material
    }

    func apply(_ pose: Pose) {
        self.pose = pose
        let hinge = min(max(pose.hinge, 0), 180)
        let raise = Float((180 - hinge) * .pi / 180)
        // Turn the device so both leaves face the camera equally while it is partly open.
        let bisect = simd_quatf(angle: -min(raise, Float(hinge * .pi / 180)) / 2, axis: [0, 1, 0])
        fold.time = (180 - hinge) / 180 * Self.foldClip.seconds
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

    /// Renders the scene into `texture`. `whenScheduled` runs once the GPU work is queued.
    func render(into texture: MTLTexture, deltaTime: TimeInterval, whenScheduled: (@Sendable () -> Void)? = nil, onComplete: (@Sendable () -> Void)? = nil) throws {
        let newAspect = Float(texture.width) / Float(texture.height)
        if newAspect != aspect {
            aspect = newAspect
            frameCamera()
        }
        let key = ObjectIdentifier(texture)
        if outputs[key] == nil {
            if outputs.count > 8 { outputs.removeAll() }
            outputs[key] = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
        }
        try renderer.updateAndRender(deltaTime: deltaTime, cameraOutput: outputs[key]!,
                                     whenScheduled: { _ in whenScheduled?() }, onComplete: { _ in onComplete?() })
    }

    /// The screen point under a view position. `point` is 0...1 with the origin at the top left.
    /// `reach` is how far past the glass still counts, in framebuffer units: 0 for a tap,
    /// a bezel width to find the frame, infinity to follow a drag that left the screen.
    func screenHit(at point: CGPoint, panel: Panel, reach: Float = 0) -> ScreenHit? {
        guard let surface = surfaces[panel] else { return nil }
        let tangent = tan(fieldOfView * .pi / 360)
        let direction = simd_normalize(SIMD3<Float>((Float(point.x) * 2 - 1) * aspect * tangent, (1 - Float(point.y) * 2) * tangent, -1))
        let hits = surface.worldLeaves().compactMap { $0.intersect(origin: camera.position, direction: direction) }
        guard let nearest = hits.min(by: { ($0.outside, $0.distance) < ($1.outside, $1.distance) }), nearest.outside <= reach else { return nil }
        return ScreenHit(panel: panel, point: CGPoint(x: CGFloat(nearest.uv.x), y: CGFloat(nearest.uv.y)))
    }

    /// Backs the camera off so the device fills the view at any tilt, and closes in as it folds.
    private func frameCamera() {
        let open = Float(min(max(pose.hinge, 0), 180) / 180)
        let width = flatBounds.extents.x * (0.5 + 0.5 * open)
        let radius = simd_length(SIMD2(width, flatBounds.extents.y)) / 2
        let vertical = fieldOfView * .pi / 360
        let narrow = aspect >= 1 ? vertical : atan(tan(vertical) * aspect)
        camera.position = [0, 0, radius * 1.12 / sin(narrow)]
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
