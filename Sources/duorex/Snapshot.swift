import AppKit
import CoreImage
import ImageIO
import Metal
import RealityKit
import UniformTypeIdentifiers

/// Renders one frame to a PNG without opening a window. Used to check the renderer.
enum Snapshot {
    static func write(scene: DuoScene, pose: Pose, marks: [Mark] = [], width: Int, height: Int, backdrop: CGColor? = nil, onStage: Bool = false, to url: URL) async throws {
        guard let frame = Frame(device: scene.device, width: width, height: height) else { throw DuoError.render("could not create the snapshot frame") }
        // A device that is nearly closed shows its cover screen.
        try await scene.draw(pose, marks: marks, on: pose.hinge < 45 ? .cover : .inner, into: frame)
        let staged = onStage ? CIContext(mtlDevice: scene.device).createCGImage(
            Stage.compose(CIImage(ioSurface: frame.surface), over: Stage.image(width: width, height: height)),
            from: CGRect(x: 0, y: 0, width: width, height: height)) : nil
        guard var image = staged ?? frame.image() else { throw DuoError.render("could not encode the snapshot") }
        if let backdrop, let space = image.colorSpace,
           let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.setFillColor(backdrop)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            image = context.makeImage() ?? image
        }
        try writePNG(image, to: url)
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw DuoError.render("could not encode the snapshot") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw DuoError.render("could not write \(url.path)") }
    }

    /// A framebuffer stand-in that shows which way up a screen is.
    static func testPattern(label: String, width: Int, height: Int) throws -> TextureResource {
        try TextureResource(image: try testPatternImage(label: label, width: width, height: height), options: .init(semantic: .color))
    }

    /// The test pattern as a picture.
    static func testPatternImage(label: String, width: Int, height: Int) throws -> CGImage {
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
        return image
    }
}
