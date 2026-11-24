import AppKit
import RealityKit
import simd

/// Draws marks on a screen: flat discs of light that lie just above the glass.
final class MarkLayer {
    /// Add this to the scene. The discs are its children, placed in world space.
    let root = Entity()

    private let mesh = MeshResource.generatePlane(width: 1, height: 1)
    /// The two looks of a mark. A material is slow to make and fast to copy, so they are made once.
    private let looks: [Mark.Look: UnlitMaterial]
    /// The discs are kept and used again. More are made when a frame needs more.
    private var discs: [ModelEntity] = []
    /// The discs draw in the order of the marks, each over the ones before it, however near they are.
    private let order = ModelSortGroup(depthPass: nil)

    /// How far in front of the screen a disc lies, in the model's centimeters. A bent screen is
    /// round at the fold, not sharp, and a disc at the fold must clear that curve.
    private static let lift: Float = 0.15

    init() throws {
        looks = try Dictionary(uniqueKeysWithValues: [Mark.Look.spot, .ring, .finger].map { look in
            guard let picture = look.picture else { throw DuoError.render("could not draw a touch mark") }
            return (look, try Self.material(picture))
        })
    }

    /// Draws `marks` on the screen whose leaves are `leaves`. Each call replaces the marks of the call before.
    func show(_ marks: [Mark], on leaves: [ScreenLeaf]) {
        var used = 0
        // The way the whole screen faces: between its leaves when it is bent.
        let facing = simd_normalize(leaves.map(\.outward).reduce(.zero, +))
        for mark in marks {
            let middle = SIMD2<Float>(Float(mark.point.x), Float(mark.point.y))
            for leaf in leaves {
                let place = leaf.place(middle)
                let radius = Float(mark.radius) * min(simd_length(place.across), simd_length(place.down))
                // The screen bends along a line of one y. A mark on that line has a part on each
                // leaf, and each part is drawn flat on its own leaf. An outer edge of the screen cuts nothing.
                let reach = radius / simd_length(place.down)
                let top = leaf.region.y > 0 ? leaf.region.y : -Float.infinity
                let bottom = leaf.region.y + leaf.region.w < 1 ? leaf.region.y + leaf.region.w : Float.infinity
                let low = max(middle.y - reach, top), high = min(middle.y + reach, bottom)
                guard low < high else { continue }

                if used == discs.count {
                    discs.append(ModelEntity(mesh: mesh, materials: []))
                    discs[used].components.set(ModelSortGroupComponent(group: order, order: Int32(used)))
                    root.addChild(discs[used])
                }
                let disc = discs[used]
                // The disc's own x runs across the framebuffer and its y runs up it, so it faces
                // the way the screen does. From behind the device, it does not show.
                let across = simd_normalize(place.across), normal = leaf.outward
                let rotation = simd_quatf(simd_float3x3(columns: (across, simd_cross(normal, across), normal)))
                let center = place.point + place.down * ((low + high) / 2 - middle.y)
                disc.transform = Transform(scale: SIMD3(radius * 2, (high - low) * simd_length(place.down), 1), rotation: rotation,
                                           translation: center + facing * Self.lift)
                var material = looks[mark.look]!
                material.blending = .transparent(opacity: .init(floatLiteral: Float(mark.opacity)))
                // The part shows its share of the picture, counted from the picture's top.
                let share = (high - low) / (reach * 2)
                material.textureCoordinateTransform = .init(offset: [0, (low - (middle.y - reach)) / (reach * 2)], scale: [1, share])
                disc.model?.materials = [material]
                disc.isEnabled = true
                used += 1
            }
        }
        for disc in discs[used...] { disc.isEnabled = false }
    }

    /// A material that shows a square picture with a clear background.
    private static func material(_ image: CGImage) throws -> UnlitMaterial {
        // Like the screen, a mark is a light: unlit, and outside the tone mapping the body gets.
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: .white, texture: .init(try TextureResource(image: image, options: .init(semantic: .color))))
        material.blending = .transparent(opacity: 1.0)
        // A mark hides behind the device, but never behind another mark.
        material.writesDepth = false
        return material
    }
}

extension Mark.Look {
    /// The colour of a touch that is not the user's own.
    private static let accent = CGColor(srgbRed: 1, green: 0.4, blue: 0.08, alpha: 1)

    /// The look as a square picture with a clear background, 256 pixels each way.
    var picture: CGImage? {
        let size = 256
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let whole = CGRect(x: 0, y: 0, width: size, height: size), side = CGFloat(size)
        switch self {
        case .spot:
            // A white rim inside a dark edge keeps the spot readable on any screen, light or dark.
            context.setFillColor(CGColor(gray: 0, alpha: 0.25))
            context.fillEllipse(in: whole.insetBy(dx: side * 0.02, dy: side * 0.02))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillEllipse(in: whole.insetBy(dx: side * 0.07, dy: side * 0.07))
            context.setFillColor(Self.accent)
            context.fillEllipse(in: whole.insetBy(dx: side * 0.15, dy: side * 0.15))
        case .ring:
            let circle = whole.insetBy(dx: side * 0.09, dy: side * 0.09)
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.2))
            context.setLineWidth(side * 0.13)
            context.strokeEllipse(in: circle)
            context.setStrokeColor(Self.accent)
            context.setLineWidth(side * 0.08)
            context.strokeEllipse(in: circle)
        case .finger:
            // Pale and half clear, so the user sees what is under a finger of their own.
            context.setFillColor(CGColor(gray: 0, alpha: 0.3))
            context.fillEllipse(in: whole.insetBy(dx: side * 0.02, dy: side * 0.02))
            context.setBlendMode(.copy)
            context.setFillColor(CGColor(gray: 1, alpha: 0.6))
            context.fillEllipse(in: whole.insetBy(dx: side * 0.08, dy: side * 0.08))
        }
        return context.makeImage()
    }
}
