import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A picture of the simulator's screen for an agent to look at: upright, and small enough to
/// read fast. A grid over it gives the agent the numbers that `duorex tap` takes.
enum ScreenShot {
    /// `screen` is the lit panel's framebuffer. `longestSide` limits the picture's size, in pixels.
    static func image(of screen: CGImage, interface: Orientation, longestSide: Int?, grid: Bool) -> CGImage? {
        let upright = ContactSheet.upright(screen, quarterTurns: interface.quarterTurnsToUpright)
        let scale = longestSide.map { min(1, CGFloat($0) / CGFloat(max(upright.width, upright.height))) } ?? 1
        let width = Int(CGFloat(upright.width) * scale), height = Int(CGFloat(upright.height) * scale)
        guard scale < 1 || grid else { return upright }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(upright, in: CGRect(x: 0, y: 0, width: width, height: height))
        if grid { drawGrid(in: context, width: CGFloat(width), height: CGFloat(height)) }
        return context.makeImage()
    }

    static func write(_ image: CGImage, to url: URL) throws {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw DuoError.render("could not write \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw DuoError.render("could not write \(url.path)") }
    }

    /// Where a picture goes when the agent names no file: out of the project, so it leaves
    /// nothing behind there. `kind` begins the file's name.
    static func temporaryFile(_ kind: String) -> URL {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "HHmmss-SSS"
        return FileManager.default.temporaryDirectory.appendingPathComponent("duorex/\(kind)-\(stamp.string(from: Date())).png")
    }

    /// A line at each tenth of the width and of the height, with its number at the top and at the left.
    private static func drawGrid(in context: CGContext, width: CGFloat, height: CGFloat) {
        // The context's origin is at the bottom left. The numbers count from the top, as `tap` does.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let line = max(1, min(width, height) / 700)
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(11, min(width, height) / 55), weight: .semibold)
        func label(_ text: String, at point: CGPoint) {
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
            let size = string.size()
            let box = CGRect(x: point.x, y: point.y - size.height, width: size.width + 6, height: size.height)
            context.setFillColor(CGColor(red: 0.85, green: 0, blue: 0.5, alpha: 0.9))
            context.fill(box)
            string.draw(at: CGPoint(x: box.minX + 3, y: box.minY))
        }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0.6, alpha: 0.55))
        for tenth in 1...9 {
            let share = CGFloat(tenth) / 10
            context.fill(CGRect(x: width * share - line / 2, y: 0, width: line, height: height))
            context.fill(CGRect(x: 0, y: height * (1 - share) - line / 2, width: width, height: line))
        }
        for tenth in 1...9 {
            let share = CGFloat(tenth) / 10, text = String(format: "%.1f", Double(tenth) / 10)
            label(text, at: CGPoint(x: width * share + 2, y: height - 2))
            label(text, at: CGPoint(x: 2, y: height * (1 - share) - 2))
        }
    }
}
