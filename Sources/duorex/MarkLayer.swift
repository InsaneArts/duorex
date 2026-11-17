import AppKit
import RealityKit
import simd

/// Draws marks on a screen: flat discs of light that lie just above the glass.
final class MarkLayer {
    /// Add this to the scene. The discs are its children, placed in world space.
    let root = Entity()

    private let mesh = MeshResource.generatePlane(width: 1, height: 1)
    /// The two looks of a mark. A material is slow to make and fast to copy, so they are made once.
    private let spot: UnlitMaterial
    private let ring: UnlitMaterial
    /// The discs are kept and used again. More are made when a frame needs more.
    private var discs: [ModelEntity] = []

    /// How far above the glass the first disc lies, in the model's centimeters: enough to stay in
    /// front of it at any distance. Each disc lies a little above the one before, so they draw in order.
    private static let lift: Float = 0.03
    /// The colour of a touch that is not the user's own.
    private static let accent = CGColor(srgbRed: 1, green: 0.4, blue: 0.08, alpha: 1)

    init() throws {
        spot = try Self.material { context, size in
            // A white rim inside a dark edge keeps the spot readable on any screen, light or dark.
            let whole = CGRect(x: 0, y: 0, width: size, height: size)
            context.setFillColor(CGColor(gray: 0, alpha: 0.25))
            context.fillEllipse(in: whole.insetBy(dx: size * 0.02, dy: size * 0.02))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillEllipse(in: whole.insetBy(dx: size * 0.07, dy: size * 0.07))
            context.setFillColor(Self.accent)
            context.fillEllipse(in: whole.insetBy(dx: size * 0.15, dy: size * 0.15))
        }
        ring = try Self.material { context, size in
            let circle = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: size * 0.09, dy: size * 0.09)
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.2))
            context.setLineWidth(size * 0.13)
            context.strokeEllipse(in: circle)
            context.setStrokeColor(Self.accent)
            context.setLineWidth(size * 0.08)
            context.strokeEllipse(in: circle)
        }
    }

    /// Draws `marks` on the screen whose leaves are `leaves`. Each call replaces the marks of the call before.
    func show(_ marks: [Mark], on leaves: [ScreenLeaf]) {
        while discs.count < marks.count {
            let disc = ModelEntity(mesh: mesh, materials: [])
            discs.append(disc)
            root.addChild(disc)
        }
        for (index, disc) in discs.enumerated() {
            guard index < marks.count, let leaf = leaves.first(where: { $0.shows(Self.uv(of: marks[index])) }) ?? leaves.first else {
                disc.isEnabled = false
                continue
            }
            let mark = marks[index]
            let place = leaf.place(Self.uv(of: mark))
            // The lit screen faces the camera, and the camera looks along the z axis.
            var normal = simd_normalize(simd_cross(place.across, place.down))
            if normal.z < 0 { normal = -normal }
            let width = Float(mark.radius) * 2 * min(simd_length(place.across), simd_length(place.down))
            disc.transform = Transform(scale: SIMD3(repeating: width), rotation: simd_quatf(from: [0, 0, 1], to: normal),
                                       translation: place.point + normal * Self.lift * (1 + Float(index) * 0.1))
            var material = mark.isRing ? ring : spot
            material.blending = .transparent(opacity: .init(floatLiteral: Float(mark.opacity)))
            disc.model?.materials = [material]
            disc.isEnabled = true
        }
    }

    private static func uv(of mark: Mark) -> SIMD2<Float> {
        SIMD2(Float(mark.point.x), Float(mark.point.y))
    }

    /// A material that shows a square picture with a clear background, drawn by `draw` in a
    /// context of `size` pixels each way.
    private static func material(_ draw: (CGContext, CGFloat) -> Void) throws -> UnlitMaterial {
        let size = 256
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw DuoError.render("could not draw a touch mark") }
        draw(context, CGFloat(size))
        guard let image = context.makeImage() else { throw DuoError.render("could not draw a touch mark") }
        // Like the screen, a mark is a light: unlit, and outside the tone mapping the body gets.
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: .white, texture: .init(try TextureResource(image: image, options: .init(semantic: .color))))
        material.blending = .transparent(opacity: 1.0)
        return material
    }
}
