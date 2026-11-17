import AppKit
import ImageIO
import Metal
import RealityKit
import UniformTypeIdentifiers

/// Renders one frame to a PNG without opening a window. Used to check the renderer.
enum Snapshot {
    static func write(scene: DuoScene, pose: Pose, width: Int, height: Int, backdrop: CGColor? = nil, to url: URL) async throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = scene.device.makeTexture(descriptor: descriptor) else { throw DuoError.render("could not create the snapshot texture") }
        scene.apply(pose)
        // The fold rig settles one update after its time changes, so draw a few frames.
        for _ in 0..<3 {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                do {
                    try scene.render(into: texture, deltaTime: 1.0 / 60, onComplete: { continuation.resume() })
                } catch { continuation.resume(throwing: error) }
            }
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        // RealityRenderer writes Display P3 colors.
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.displayP3),
              var image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw DuoError.render("could not encode the snapshot") }
        if let backdrop, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.setFillColor(backdrop)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            image = context.makeImage() ?? image
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw DuoError.render("could not write \(url.path)") }
    }

    /// A framebuffer stand-in that shows which way up a screen is.
    static func testPattern(label: String, width: Int, height: Int) throws -> TextureResource {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw DuoError.render("could not draw the test pattern") }
        let w = CGFloat(width), h = CGFloat(height)
        let colors = [CGColor(red: 0.10, green: 0.25, blue: 0.75, alpha: 1), CGColor(red: 0.85, green: 0.30, blue: 0.45, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: nil)!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
        // A white block marks the top left corner; a yellow one marks the top right.
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: h - h * 0.08, width: w * 0.2, height: h * 0.08))
        context.setFillColor(CGColor(red: 1, green: 0.9, blue: 0, alpha: 1))
        context.fill(CGRect(x: w - w * 0.1, y: h - h * 0.08, width: w * 0.1, height: h * 0.08))
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let text = NSAttributedString(string: label, attributes: [.font: NSFont.boldSystemFont(ofSize: h * 0.09), .foregroundColor: NSColor.white])
        text.draw(at: CGPoint(x: w * 0.08, y: h * 0.45))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { throw DuoError.render("could not draw the test pattern") }
        return try TextureResource(image: image, options: .init(semantic: .color))
    }
}
