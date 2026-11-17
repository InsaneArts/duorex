import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Draws a sweep's shots as one picture: a column for each posture and a row for each way of
/// holding the device. Each cell shows the screen upright, the device in that posture, and what it is.
enum ContactSheet {
    private static let cell = CGSize(width: 1500, height: 1180)
    private static let margin: CGFloat = 60
    private static let gap: CGFloat = 40
    private static let header: CGFloat = 150
    /// The strip on the left of a cell that holds the device and the caption.
    private static let strip: CGFloat = 400

    static func write(_ shots: [Sweep.Shot], to url: URL) throws {
        guard let image = image(of: shots),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw DuoError.render("could not draw the contact sheet")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw DuoError.render("could not write \(url.path)") }
    }

    static func image(of shots: [Sweep.Shot]) -> CGImage? {
        let columns = Sweep.postures.count, rows = Sweep.holds.count
        let width = Int(margin * 2 + cell.width * CGFloat(columns) + gap * CGFloat(columns - 1))
        let height = Int(margin * 2 + header + cell.height * CGFloat(rows) + gap * CGFloat(rows - 1))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Work with the origin at the top left, as the layout is written.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        context.setFillColor(CGColor(gray: 0.055, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        text("iPhone Duo · posture sweep", size: 64, weight: .semibold, gray: 1, at: CGPoint(x: margin, y: margin))
        text(Date().formatted(date: .abbreviated, time: .shortened), size: 34, weight: .regular, gray: 0.55, at: CGPoint(x: margin, y: margin + 84))

        for shot in shots {
            guard let column = Sweep.postures.firstIndex(where: { $0.name == shot.posture.name }),
                  let row = Sweep.holds.firstIndex(of: shot.held) else { continue }
            let origin = CGPoint(x: margin + (cell.width + gap) * CGFloat(column), y: margin + header + (cell.height + gap) * CGFloat(row))
            draw(shot, in: CGRect(origin: origin, size: cell), context: context)
        }
        return context.makeImage()
    }

    private static func draw(_ shot: Sweep.Shot, in frame: CGRect, context: CGContext) {
        context.setFillColor(CGColor(gray: 0.105, alpha: 1))
        context.addPath(CGPath(roundedRect: frame, cornerWidth: 36, cornerHeight: 36, transform: nil))
        context.fillPath()

        if let device = shot.device.map(trimmed) {
            // The device, as large as the top of the strip allows.
            let area = CGRect(x: frame.minX + 44, y: frame.minY + 44, width: strip - 88, height: 290)
            let scale = min(area.width / CGFloat(device.width), area.height / CGFloat(device.height))
            let size = CGSize(width: CGFloat(device.width) * scale, height: CGFloat(device.height) * scale)
            place(device, in: CGRect(x: area.minX, y: area.midY - size.height / 2, width: size.width, height: size.height), context: context)
        }
        let left = frame.minX + 44
        text(shot.posture.name, size: 58, weight: .semibold, gray: 1, at: CGPoint(x: left, y: frame.minY + 370))
        let upright = upright(shot.screen, quarterTurns: shot.interface.quarterTurnsToUpright)
        let lines = [
            "held \(shot.held.label)",
            "\(shot.panel.rawValue) screen",
            shot.hinge.map { "hinge \(Int($0.rounded()))°" } ?? "hinge unknown",
            "\(upright.width) × \(upright.height) px",
        ]
        for (index, line) in lines.enumerated() {
            text(line, size: 32, weight: .regular, gray: 0.6, at: CGPoint(x: left, y: frame.minY + 456 + CGFloat(index) * 46))
        }

        // The screen, upright, as large as the rest of the cell allows.
        let area = CGRect(x: frame.minX + strip, y: frame.minY + 40, width: frame.width - strip - 40, height: frame.height - 80)
        let scale = min(area.width / CGFloat(upright.width), area.height / CGFloat(upright.height))
        let size = CGSize(width: CGFloat(upright.width) * scale, height: CGFloat(upright.height) * scale)
        let box = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
        context.saveGState()
        context.addPath(CGPath(roundedRect: box, cornerWidth: 28, cornerHeight: 28, transform: nil))
        context.clip()
        place(upright, in: box, context: context)
        context.restoreGState()
    }

    /// Cuts the transparent border off a picture of the device.
    private static func trimmed(_ image: CGImage) -> CGImage {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }
        // The bitmap's rows run top to bottom, as an image's crop rectangle does.
        return image.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) ?? image
    }

    /// Draws an image the right way up in a context whose origin is at the top left.
    private static func place(_ image: CGImage, in box: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: box.minX, y: box.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: box.size))
        context.restoreGState()
    }

    private static func text(_ string: String, size: CGFloat, weight: NSFont.Weight, gray: CGFloat, at point: CGPoint) {
        NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(white: gray, alpha: 1),
        ]).draw(at: point)
    }

    /// Turns a framebuffer picture clockwise by quarter turns, so the interface in it is upright.
    private static func upright(_ image: CGImage, quarterTurns: Int) -> CGImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let size = turns == 2 ? CGSize(width: width, height: height) : CGSize(width: height, height: width)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        switch turns {
        case 1:
            context.translateBy(x: 0, y: width)
            context.rotate(by: -.pi / 2)
        case 2:
            context.translateBy(x: width, y: height)
            context.rotate(by: .pi)
        default:
            context.translateBy(x: height, y: 0)
            context.rotate(by: .pi / 2)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}
