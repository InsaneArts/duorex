import RealityKit
import simd

/// One of the device's four hardware buttons.
nonisolated enum HardwareButton: String, CaseIterable {
    case volumeDown = "Volume down"
    case volumeUp = "Volume up"
    case power = "Power"
    case cameraControl = "Camera control"

    /// The HID usage serve-sim sends for the button: the usage page and the usage.
    var usage: (page: Int, usage: Int) {
        switch self {
        case .volumeDown: (12, 234)
        case .volumeUp: (12, 233)
        case .power: (12, 48)
        case .cameraControl: (65280, 102)
        }
    }

    /// The name of the button's part in Apple's model.
    fileprivate var part: String {
        switch self {
        case .volumeDown: "CmYdOlPKmuMDoXR"
        case .volumeUp: "koDLxoGBdfDshrV"
        case .power: "eMjBYLfkSbgWYfC"
        case .cameraControl: "OLwRWbIGbztiQrw"
        }
    }
}

/// Finds the hardware buttons on the model: where each one is in the current pose, and how to push it in.
/// The lookup of the button parts follows serve-sim's DuoHardwareProjection (Apache-2.0).
final class HardwareButtons {
    private struct Button {
        /// The button's middle, in the mesh's own space.
        var center: SIMD3<Float>
        /// The way the button moves when pressed, in its joint's space, with the length of a full press.
        var push: SIMD3<Float>
        /// The joint the button is bound to, as an index into the entity's joints.
        var joint: Int
        var skeletonJoint: Int
    }

    private let entity: ModelEntity
    private let joints: [MeshResource.Skeleton.Joint]
    private let jointIndices: [Int?]
    private var buttons: [HardwareButton: Button] = [:]

    init(entity: ModelEntity) throws {
        self.entity = entity
        let contents = entity.model!.mesh.contents
        let parts = contents.models.flatMap { Array($0.parts) }
        guard let first = parts.first(where: { $0.id == HardwareButton.volumeDown.part }),
              let skeletonID = first.skeletonID, let skeleton = contents.skeletons[skeletonID] else {
            throw DuoError.model("the hardware buttons are missing")
        }
        joints = skeleton.joints
        jointIndices = joints.map { entity.jointNames.firstIndex(of: $0.name) }
        let bounds = entity.model!.mesh.bounds
        for button in HardwareButton.allCases {
            // Each button is one rigid part: every vertex follows a single joint.
            guard let part = parts.first(where: { $0.id == button.part }), part.skeletonID == skeletonID,
                  let skeletonJoint = part.jointInfluences?.influences.elements.first(where: { $0.weight > 0 })?.jointIndex,
                  let joint = jointIndices[skeletonJoint] else { throw DuoError.model("the \(button.rawValue) button is missing") }
            var low = SIMD3<Float>(repeating: .infinity), high = SIMD3<Float>(repeating: -.infinity)
            for point in part.positions.elements {
                low = simd_min(low, point)
                high = simd_max(high, point)
            }
            let center = (low + high) / 2
            // A button sits on an edge of the device, and goes in toward the middle. Its short
            // side in the plane of the device is the way in, and it travels most of its height.
            let size = high - low
            let inward: SIMD3<Float> = size.x < size.z ? [bounds.center.x > center.x ? 1 : -1, 0, 0] : [0, 0, bounds.center.z > center.z ? 1 : -1]
            let travel = inward * min(size.x, size.z) * 0.7
            let toJoint = joints[skeletonJoint].inverseBindPoseMatrix
            let push = SIMD3(simd_mul(toJoint, SIMD4(travel, 0)).x, simd_mul(toJoint, SIMD4(travel, 0)).y, simd_mul(toJoint, SIMD4(travel, 0)).z)
            buttons[button] = Button(center: center, push: push, joint: joint, skeletonJoint: skeletonJoint)
        }
    }

    /// Pushes a button in by `depth`, from 0 for out to 1 for fully in, in a set of joint transforms.
    func push(_ button: HardwareButton, depth: Float, in pose: inout [Transform]) {
        guard let button = buttons[button], button.joint < pose.count else { return }
        let joint = pose[button.joint]
        pose[button.joint].translation += joint.rotation.act(joint.scale * button.push * depth)
    }

    /// Where each button's middle is in the world, for the pose the model is in now.
    func worldCenters() -> [HardwareButton: SIMD3<Float>] {
        let transforms = entity.jointTransforms
        var global = [simd_float4x4](repeating: matrix_identity_float4x4, count: joints.count)
        for index in joints.indices {
            let local = jointIndices[index].flatMap { $0 < transforms.count ? transforms[$0].matrix : nil } ?? joints[index].restPoseTransform.matrix
            global[index] = joints[index].parentIndex.map { global[$0] * local } ?? local
        }
        let world = entity.transformMatrix(relativeTo: nil)
        return buttons.mapValues { button in
            let point = world * global[button.skeletonJoint] * joints[button.skeletonJoint].inverseBindPoseMatrix * SIMD4(button.center, 1)
            return SIMD3(point.x, point.y, point.z)
        }
    }
}
