import CoreGraphics
import CoreVideo
import IOSurface
import Metal

/// A picture the scene draws into. It is an IOSurface, so a layer can show it and an image can
/// be read from it, in the pixel format and the colour space the renderer writes.
final class Frame {
    let surface: IOSurface
    let texture: MTLTexture
    var width: Int { texture.width }
    var height: Int { texture.height }

    init?(device: MTLDevice, width: Int, height: Int) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        guard width > 0, height > 0,
              let surface = IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4, .pixelFormat: kCVPixelFormatType_32BGRA]),
              let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else { return nil }
        // RealityRenderer writes Display P3 colours.
        if let space = Self.colorSpace.copyPropertyList() { IOSurfaceSetValue(surface, kIOSurfaceColorSpace, space) }
        self.surface = surface
        self.texture = texture
    }

    /// The picture as an image, with a transparent background. Read it once the scene has finished drawing.
    func image() -> CGImage? {
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let data = Data(bytes: surface.baseAddress, count: surface.bytesPerRow * height)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: surface.bytesPerRow,
                       space: Self.colorSpace, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
}
