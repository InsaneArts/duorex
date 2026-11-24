import AppKit

/// How Simulator.app draws a device: Xcode's chrome around the screen, with the side buttons,
/// the screen's shape and the Dynamic Island.
///
/// Sizes are in points, with the origin at the top left of the device's body. The chrome comes
/// from the device type in CoreSimulator and from its bundle in /Library/Developer/DeviceKit/Chrome.
final class DeviceChrome {
    /// A side button, drawn under the bezel so that only its outer part shows.
    struct Button {
        let button: HardwareButton
        let image: NSImage
        let pressedImage: NSImage
        /// Where it lies in the body's points. It can reach outside the body.
        let frame: CGRect
    }

    /// The screen in pixels, as the framebuffer has it.
    let screenPixels: CGSize
    /// The screen in the body's points.
    let screen: CGRect
    /// The body, without the buttons.
    let body: CGSize
    /// Room around the body that the buttons reach into, in points.
    let margin: CGFloat
    let buttons: [Button]
    /// The screen's shape, drawn to the screen's size: rounded corners, and on some models a notch.
    let mask: NSImage?
    /// The Dynamic Island, drawn at the top of the screen, at its own size.
    let sensorBar: NSImage?
    /// The radius of the body's corners, for its shadow.
    let cornerRadius: CGFloat
    private let slices: [String: NSImage]

    /// The chrome of the device type at `typeBundle`, a .simdevicetype bundle.
    init(typeBundle: URL) throws {
        let resources = typeBundle.appendingPathComponent("Contents/Resources")
        guard let capabilities = NSDictionary(contentsOf: resources.appendingPathComponent("capabilities.plist")) as? [String: Any],
              let displays = (capabilities["capabilities"] as? [String: Any] ?? capabilities)["displays"] as? [[String: Any]],
              let display = displays.first(where: { $0["displayType"] as? String == "integrated" && ($0["hasDigitizer"] as? Bool ?? false) }),
              let width = (display["width"] as? NSNumber)?.doubleValue, let height = (display["height"] as? NSNumber)?.doubleValue,
              let scale = (display["scale"] as? NSNumber)?.doubleValue, scale > 0,
              let chromeID = display["chromeIdentifier"] as? String
        else { throw DuoError.render("this device type has no screen that duorex can draw") }
        let profile = NSDictionary(contentsOf: resources.appendingPathComponent("profile.plist")) as? [String: Any] ?? [:]
        guard let chromeFolder = Self.chromeFolder(chromeID),
              let data = try? Data(contentsOf: chromeFolder.appendingPathComponent("chrome.json")),
              let chrome = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = chrome["images"] as? [String: Any], let sizing = images["sizing"] as? [String: Double]
        else { throw DuoError.render("Xcode has no chrome \(chromeID) to draw this device with") }

        func image(_ name: String?) -> NSImage? {
            name.flatMap { NSImage(contentsOf: chromeFolder.appendingPathComponent("\($0).pdf")) }
        }
        var slices: [String: NSImage] = [:]
        for part in ["topLeft", "top", "topRight", "right", "bottomRight", "bottom", "bottomLeft", "left", "screen"] {
            guard let image = image(images[part] as? String) else { throw DuoError.render("the chrome \(chromeID) has no \(part) image") }
            slices[part] = image
        }
        self.slices = slices
        screenPixels = CGSize(width: width, height: height)
        let left = sizing["leftWidth"] ?? 0, top = sizing["topHeight"] ?? 0
        screen = CGRect(x: left, y: top, width: width / scale, height: height / scale)
        body = CGSize(width: screen.width + left + (sizing["rightWidth"] ?? 0), height: screen.height + top + (sizing["bottomHeight"] ?? 0))
        let padding = images["devicePadding"] as? [String: Double] ?? [:]
        margin = padding.values.max() ?? 0
        cornerRadius = ((chrome["paths"] as? [String: Any])?["simpleOutsideBorder"] as? [String: Any])?["cornerRadiusX"] as? Double ?? 0

        // The usage tells the button. A button whose usage duorex does not know is left out.
        var buttons: [Button] = []
        for input in chrome["inputs"] as? [[String: Any]] ?? [] {
            guard input["type"] as? String == "button",
                  let page = input["usagePage"] as? Int, let usage = input["usage"] as? Int,
                  let button = HardwareButton.allCases.first(where: { $0.usage == (page, usage) }),
                  let up = image(input["image"] as? String),
                  let offset = (input["offsets"] as? [String: Any])?["normal"] as? [String: Double]
            else { continue }
            let down = image(input["imageDown"] as? String) ?? up
            let size = up.size, x = offset["x"] ?? 0, y = offset["y"] ?? 0
            // The offset is where the button's inner edge lies, measured into the body from the edge it sits on.
            let frame = switch input["anchor"] as? String {
            case "right": CGRect(x: body.width + x, y: y, width: size.width, height: size.height)
            case "top": CGRect(x: x, y: y - size.height, width: size.width, height: size.height)
            case "bottom": CGRect(x: x, y: body.height + y, width: size.width, height: size.height)
            default: CGRect(x: x - size.width, y: y, width: size.width, height: size.height)
            }
            buttons.append(Button(button: button, image: up, pressedImage: down, frame: frame))
        }
        self.buttons = buttons

        let resource = { (name: String?) in name.flatMap { NSImage(contentsOf: resources.appendingPathComponent("\($0).pdf")) } }
        mask = resource(profile["framebufferMask"] as? String ?? display["framebufferMaskIdentifier"] as? String)
        sensorBar = resource(profile["sensorBarImage"] as? String)
    }

    /// The bundle of a chrome, such as com.apple.dt.devicekit.chrome.phone11.
    private static func chromeFolder(_ identifier: String) -> URL? {
        let root = URL(fileURLWithPath: "/Library/Developer/DeviceKit/Chrome")
        let named = root.appendingPathComponent("\(identifier.split(separator: ".").last ?? "").devicechrome/Contents/Resources")
        if FileManager.default.fileExists(atPath: named.appendingPathComponent("chrome.json").path) { return named }
        // A bundle named otherwise is found by the identifier in its chrome.json.
        let bundles = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return bundles.map { $0.appendingPathComponent("Contents/Resources") }.first { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("chrome.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return json["identifier"] as? String == identifier
        }
    }

    // MARK: Drawing

    /// The body, with its bezel and the black under the screen, as a picture `scale` pixels to a point.
    func bodyImage(scale: CGFloat) -> CGImage? {
        draw(size: body, scale: scale) { [self] in
            NSDrawNinePartImage(CGRect(origin: .zero, size: body), slices["topLeft"]!, slices["top"]!, slices["topRight"]!,
                                slices["left"]!, slices["screen"]!, slices["right"]!,
                                slices["bottomLeft"]!, slices["bottom"]!, slices["bottomRight"]!, .sourceOver, 1, true)
        }
    }

    /// A picture of `image` at its own size, `scale` pixels to a point.
    static func picture(of image: NSImage, scale: CGFloat) -> CGImage? {
        draw(size: image.size, scale: scale) { put(image, in: CGRect(origin: .zero, size: image.size)) }
    }

    /// The screen's shape at the screen's size, `scale` pixels to a point: opaque where the screen shows.
    func maskImage(scale: CGFloat) -> CGImage? {
        guard let mask else { return nil }
        return Self.draw(size: screen.size, scale: scale) { [self] in Self.put(mask, in: CGRect(origin: .zero, size: screen.size)) }
    }

    /// The whole device with `screen` on it, `scale` pixels to a point, with room around the
    /// body for the buttons. For a picture of the device without a window.
    func picture(screen content: CGImage?, scale: CGFloat) -> CGImage? {
        let mask = maskImage(scale: scale)
        return draw(size: CGSize(width: body.width + margin * 2, height: body.height + margin * 2), scale: scale) { [self] in
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.translateBy(x: margin, y: margin)
            // The buttons first: the bezel covers their inner part.
            for button in buttons { Self.put(button.image, in: button.frame) }
            NSDrawNinePartImage(CGRect(origin: .zero, size: body), slices["topLeft"]!, slices["top"]!, slices["topRight"]!,
                                slices["left"]!, slices["screen"]!, slices["right"]!,
                                slices["bottomLeft"]!, slices["bottom"]!, slices["bottomRight"]!, .sourceOver, 1, true)
            if let content {
                context.saveGState()
                // A CGImage draws with its first row at the bottom, so it is turned over into this top-down context.
                context.translateBy(x: screen.minX, y: screen.maxY)
                context.scaleBy(x: 1, y: -1)
                let area = CGRect(origin: .zero, size: screen.size)
                if let mask { context.clip(to: area, mask: mask) }
                context.draw(content, in: area)
                context.restoreGState()
            }
            if let sensorBar { Self.put(sensorBar, in: CGRect(x: screen.midX - sensorBar.size.width / 2, y: screen.minY, width: sensorBar.size.width, height: sensorBar.size.height)) }
        }
    }

    /// Draws an image the right way up in a context whose origin is at the top left.
    private static func put(_ image: NSImage, in rect: CGRect) {
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func draw(size: CGSize, scale: CGFloat, _ drawing: () -> Void) -> CGImage? {
        Self.draw(size: size, scale: scale, drawing)
    }

    /// Draws with AppKit into a new picture, with the origin at the top left.
    private static func draw(size: CGSize, scale: CGFloat, _ drawing: () -> Void) -> CGImage? {
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        drawing()
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
