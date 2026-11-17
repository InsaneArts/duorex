import CoreGraphics
import Foundation
import RealityKit

/// Image-based lighting for the device: a dark studio with a few softboxes.
/// It is drawn in code so no lighting asset ships with duorex.
enum StudioLight {
    private struct Softbox {
        var azimuth: Float, elevation: Float      // center, degrees
        var width: Float, height: Float           // angular size, degrees
        var intensity: Float
    }

    private static let softboxes = [
        Softbox(azimuth: -55, elevation: 38, width: 70, height: 46, intensity: 9),    // key, upper left
        Softbox(azimuth: 70, elevation: 12, width: 50, height: 70, intensity: 3.2),   // fill, right
        Softbox(azimuth: 0, elevation: 84, width: 360, height: 30, intensity: 4.5),   // overhead strip
        Softbox(azimuth: 180, elevation: 15, width: 120, height: 50, intensity: 5),   // rim, behind
        Softbox(azimuth: 0, elevation: -6, width: 150, height: 90, intensity: 0.55),  // soft front card
    ]

    static func environment() throws -> EnvironmentResource {
        let width = 512, height = 256
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            let elevation = (0.5 - (Float(y) + 0.5) / Float(height)) * 180
            for x in 0..<width {
                let azimuth = ((Float(x) + 0.5) / Float(width) - 0.5) * 360
                // A faint gradient keeps the unlit side of the device from going to black.
                var value = 0.05 + 0.12 * max(0, elevation / 90)
                for box in softboxes {
                    var delta = abs(azimuth - box.azimuth)
                    if delta > 180 { delta = 360 - delta }
                    let horizontal = falloff(delta, half: box.width / 2)
                    let vertical = falloff(abs(elevation - box.elevation), half: box.height / 2)
                    value += box.intensity * horizontal * vertical
                }
                let offset = (y * width + x) * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value * 1.03   // a slightly cool studio
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: width * 16,
                                  space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw DuoError.model("could not build the studio lighting") }
        return try EnvironmentResource(equirectangular: image)
    }

    /// 1 inside the box, easing to 0 across a soft edge.
    private static func falloff(_ distance: Float, half: Float) -> Float {
        let edge = half * 0.45
        let t = min(max((half + edge - distance) / (2 * edge), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
