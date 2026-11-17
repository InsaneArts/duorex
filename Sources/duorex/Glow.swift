import CoreImage
import CoreVideo
import IOSurface
import Metal

/// The light that the device's screens throw on what is around them: a small, soft picture of
/// the device, to show stretched under it.
final class Glow {
    private let context: CIContext
    /// The glow is drawn into these in turn, so the one on screen is never the one being drawn.
    private var surfaces: [IOSurface] = []
    private var next = 0

    /// The glow is this many times smaller than the picture it comes from. Soft light has no detail to lose.
    private static let reduction = 8

    init(device: MTLDevice) {
        context = CIContext(mtlDevice: device)
    }

    /// The glow of a picture of the device. Nil when it could not be drawn.
    func surface(for picture: IOSurface) -> IOSurface? {
        let width = max(picture.width / Self.reduction, 1), height = max(picture.height / Self.reduction, 1)
        if surfaces.first.map({ $0.width != width || $0.height != height }) ?? true {
            surfaces = (0..<2).compactMap { _ in
                IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4, .pixelFormat: kCVPixelFormatType_32BGRA])
            }
        }
        guard surfaces.count == 2 else { return nil }
        let target = surfaces[next]
        next = 1 - next
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let small = CIImage(ioSurface: picture)
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / CGFloat(picture.width), y: CGFloat(height) / CGFloat(picture.height)))
        // A wide blur spreads the screens' colours past the device. More colour and less
        // strength make it light on a wall, not a second picture.
        let light = small.applyingGaussianBlur(sigma: Double(height) * 0.085)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.6])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.6, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.6, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.6, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.6),
            ])
            .cropped(to: extent)
        context.render(light, to: target, bounds: extent, colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
        return target
    }
}
