import RealityKit
import simd

/// One flat half of a screen, as three skinned points with their framebuffer coordinates.
nonisolated struct ScreenLeaf {
    var a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>
    var uvA: SIMD2<Float>, uvB: SIMD2<Float>, uvC: SIMD2<Float>
    /// The part of the framebuffer this leaf shows, as x, y, width, height in 0...1.
    var region: SIMD4<Float>

    /// Where a ray meets this leaf, in framebuffer coordinates, with the distance along the ray.
    func intersect(origin: SIMD3<Float>, direction: SIMD3<Float>) -> (uv: SIMD2<Float>, distance: Float)? {
        let e1 = b - a, e2 = c - a
        let normal = simd_cross(e1, e2)
        let facing = simd_dot(direction, normal)
        guard abs(facing) > 1e-9 else { return nil }
        let distance = simd_dot(a - origin, normal) / facing
        guard distance > 0 else { return nil }
        let w = origin + direction * distance - a
        let d11 = simd_dot(e1, e1), d12 = simd_dot(e1, e2), d22 = simd_dot(e2, e2)
        let w1 = simd_dot(w, e1), w2 = simd_dot(w, e2)
        let det = d11 * d22 - d12 * d12
        guard abs(det) > 1e-18 else { return nil }
        let alpha = (d22 * w1 - d12 * w2) / det, beta = (d11 * w2 - d12 * w1) / det
        let uv = uvA + (uvB - uvA) * alpha + (uvC - uvA) * beta
        guard uv.x >= region.x, uv.x <= region.x + region.z, uv.y >= region.y, uv.y <= region.y + region.w else { return nil }
        return (uv, distance)
    }
}

/// Follows a screen's mesh through the fold animation.
/// The sampling and skinning follow serve-sim's DuoScreenProjection (Apache-2.0).
final class ScreenSurface {
    private struct Sample {
        let position: SIMD3<Float>
        let uv: SIMD2<Float>
        let influences: [MeshJointInfluence]
    }

    private let entity: ModelEntity
    private let joints: [MeshResource.Skeleton.Joint]
    private let jointIndices: [Int?]
    private let leaves: [(samples: [Sample], region: SIMD4<Float>)]

    /// `split` is true for the inner screen, which bends across the hinge into two leaves.
    init(entity: ModelEntity, material: Int, split: Bool) throws {
        self.entity = entity
        let contents = entity.model!.mesh.contents
        guard let part = contents.models.flatMap({ Array($0.parts) }).first(where: { $0.materialIndex == material }),
              let coordinates = part.textureCoordinates,
              let skeletonID = part.skeletonID, let skeleton = contents.skeletons[skeletonID],
              let influences = part.jointInfluences else { throw DuoError.model("a screen has no skinned mesh") }
        joints = skeleton.joints
        jointIndices = skeleton.joints.map { entity.jointNames.firstIndex(of: $0.name) }
        let positions = Array(part.positions.elements), uvs = Array(coordinates.elements)
        let weights = Array(influences.influences.elements)
        let perVertex = weights.count / positions.count
        let samples = positions.indices.map { index in
            Sample(position: positions[index], uv: SIMD2(uvs[index].x, 1 - uvs[index].y),
                   influences: Array(weights[(index * perVertex)..<((index + 1) * perVertex)]))
        }
        let regions: [SIMD4<Float>] = split ? [SIMD4(0, 0.5, 1, 0.5), SIMD4(0, 0, 1, 0.5)] : [SIMD4(0, 0, 1, 1)]
        leaves = try regions.map { region in
            let candidates = split ? samples.filter { $0.uv.y > region.y + 0.02 && $0.uv.y < region.y + region.w - 0.02 } : samples
            let targets = [SIMD2<Float>(0.15, 0.2), SIMD2<Float>(0.85, 0.2), SIMD2<Float>(0.15, 0.8)]
            let picked = targets.compactMap { target in
                let uv = SIMD2(target.x, region.y + target.y * region.w)
                return candidates.min { simd_distance_squared($0.uv, uv) < simd_distance_squared($1.uv, uv) }
            }
            let u = picked.count == 3 ? picked[1].uv - picked[0].uv : .zero
            let v = picked.count == 3 ? picked[2].uv - picked[0].uv : .zero
            guard abs(u.x * v.y - u.y * v.x) > 0.000001 else { throw DuoError.model("a screen mesh is degenerate") }
            return (picked, region)
        }
    }

    /// The leaves in world space for the pose the model is in now.
    func worldLeaves() -> [ScreenLeaf] {
        let transforms = entity.jointTransforms
        var global = [simd_float4x4](repeating: matrix_identity_float4x4, count: joints.count)
        for index in joints.indices {
            let local = jointIndices[index].flatMap { $0 < transforms.count ? transforms[$0].matrix : nil } ?? joints[index].restPoseTransform.matrix
            global[index] = joints[index].parentIndex.map { global[$0] * local } ?? local
        }
        let skin = joints.indices.map { global[$0] * joints[$0].inverseBindPoseMatrix }
        let world = entity.transformMatrix(relativeTo: nil)
        func position(_ sample: Sample) -> SIMD3<Float> {
            var point = SIMD4<Float>(repeating: 0)
            for influence in sample.influences where influence.weight > 0 {
                point += (skin[influence.jointIndex] * SIMD4(sample.position, 1)) * influence.weight
            }
            let p = world * point
            return SIMD3(p.x, p.y, p.z)
        }
        return leaves.map { leaf in
            let s = leaf.samples
            return ScreenLeaf(a: position(s[0]), b: position(s[1]), c: position(s[2]), uvA: s[0].uv, uvB: s[1].uv, uvC: s[2].uv, region: leaf.region)
        }
    }
}
