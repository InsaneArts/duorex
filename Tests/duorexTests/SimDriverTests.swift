import CoreGraphics
import Testing
@testable import duorex

/// A black screen of the cover's size, with white where `draw` paints.
private func screen(_ draw: (CGContext, CGRect) -> Void) -> CGImage {
    let size = CGRect(x: 0, y: 0, width: 1398, height: 2034)
    let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(size)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    draw(context, size)
    return context.makeImage()!
}

@MainActor @Test func `a black screen with a logo in the middle is a boot screen`() {
    // The Apple logo is about 120 by 145 pixels on the cover screen.
    let logo = screen { context, size in
        context.fillEllipse(in: CGRect(x: size.midX - 60, y: size.midY - 72, width: 120, height: 145))
    }
    #expect(SimDriver.isBootScreen(logo))
    #expect(SimDriver.isBootScreen(screen { _, _ in }))
}

@MainActor @Test func `a home screen is not a boot screen, though its wallpaper is black`() {
    // Two widgets and a row of icons, as on a new simulator.
    let home = screen { context, size in
        context.fill(CGRect(x: 60, y: size.height - 620, width: 480, height: 480))
        context.fill(CGRect(x: 600, y: size.height - 620, width: 480, height: 480))
        for column in 0..<4 { context.fill(CGRect(x: 90 + column * 270, y: Int(size.height) - 900, width: 170, height: 170)) }
    }
    #expect(!SimDriver.isBootScreen(home))
}
