import CoreVideo
import IOSurface
import Metal
import Testing
@testable import duorex

/// A clear picture, 800 by 600, with a solid red square of 200 in its middle.
private func picture() throws -> IOSurface {
    let surface = try #require(IOSurface(properties: [.width: 800, .height: 600, .bytesPerElement: 4, .pixelFormat: kCVPixelFormatType_32BGRA]))
    surface.lock(options: [], seed: nil)
    defer { surface.unlock(options: [], seed: nil) }
    let bytes = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
    for row in 0..<600 {
        for column in 0..<800 {
            let inside = (200..<400).contains(row) && (300..<500).contains(column)
            let pixel = bytes + row * surface.bytesPerRow + column * 4
            pixel[0] = 0
            pixel[1] = 0
            pixel[2] = inside ? 255 : 0
            pixel[3] = inside ? 255 : 0
        }
    }
    return surface
}

/// The blue, green, red and alpha of one pixel.
private func pixel(_ surface: IOSurface, column: Int, row: Int) -> [UInt8] {
    surface.lock(options: .readOnly, seed: nil)
    defer { surface.unlock(options: .readOnly, seed: nil) }
    let bytes = surface.baseAddress.assumingMemoryBound(to: UInt8.self) + row * surface.bytesPerRow + column * 4
    return [bytes[0], bytes[1], bytes[2], bytes[3]]
}

@MainActor @Test func `the glow is a small picture that spreads the colour past its source`() throws {
    let glow = Glow(device: try #require(MTLCreateSystemDefaultDevice()))
    let light = try #require(glow.surface(for: try picture()))
    #expect(light.width == 100 && light.height == 75)
    // In the middle of the square the light is red.
    let middle = pixel(light, column: 50, row: 37)
    #expect(middle[2] > 80 && middle[0] < 30)
    // The square ends at column 62. Ten columns on, some of its red is still there.
    let beside = pixel(light, column: 72, row: 37)
    #expect(beside[3] > 4 && beside[2] > beside[0])
    #expect(beside[3] < middle[3])
    // A far corner stays clear.
    #expect(pixel(light, column: 2, row: 2)[3] < 3)
}

@MainActor @Test func `one glow is never drawn into the surface that was given out last`() throws {
    let glow = Glow(device: try #require(MTLCreateSystemDefaultDevice()))
    let source = try picture()
    let first = try #require(glow.surface(for: source)), second = try #require(glow.surface(for: source))
    #expect(first !== second)
}
