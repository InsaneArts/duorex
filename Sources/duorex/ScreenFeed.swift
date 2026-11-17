import CoreVideo
import Metal
import RealityKit

/// Puts decoded simulator frames on the device's screens without leaving the GPU.
final class ScreenFeed {
    private let scene: DuoScene
    private let queue: MTLCommandQueue
    private let cache: CVMetalTextureCache
    private var screens: [Panel: (texture: LowLevelTexture, resource: TextureResource, width: Int, height: Int)] = [:]
    private var lit: Set<Panel> = []

    init(scene: DuoScene) throws {
        self.scene = scene
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, scene.device, nil, &cache)
        guard let cache, let queue = scene.device.makeCommandQueue() else { throw DuoError.render("could not set up the screen feed") }
        self.cache = cache
        self.queue = queue
    }

    /// Turns a screen dark, as the real device does with the panel that is not in use.
    func turnOff(_ panel: Panel) {
        guard lit.remove(panel) != nil else { return }
        scene.setScreen(panel, texture: nil)
    }

    /// Copies a frame to its screen and returns the panel it belongs to.
    @discardableResult
    func show(_ frame: CVPixelBuffer) -> Panel? {
        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        let panel = Panel(framebufferWidth: width, height: height)
        var wrapped: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, frame, nil, .bgra8Unorm_srgb, width, height, 0, &wrapped)
        guard let wrapped, let source = CVMetalTextureGetTexture(wrapped), let commands = queue.makeCommandBuffer() else { return nil }
        do {
            if screens[panel].map({ $0.width != width || $0.height != height }) ?? true {
                // A full mip chain keeps text steady when the device is small or tilted.
                let levels = Int(log2(Double(max(width, height)))) + 1
                let texture = try LowLevelTexture(descriptor: .init(pixelFormat: .bgra8Unorm_srgb, width: width, height: height,
                                                                    mipmapLevelCount: levels, textureUsage: [.shaderRead, .renderTarget]))
                screens[panel] = (texture, try TextureResource(from: texture), width, height)
                lit.remove(panel)
            }
            if lit.insert(panel).inserted { scene.setScreen(panel, texture: screens[panel]!.resource) }
            let target = screens[panel]!.texture.replace(using: commands)
            guard let blit = commands.makeBlitCommandEncoder() else { return nil }
            blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, to: target, destinationSlice: 0, destinationLevel: 0, sliceCount: 1, levelCount: 1)
            blit.generateMipmaps(for: target)
            blit.endEncoding()
            // The wrapper must outlive the copy.
            nonisolated(unsafe) let keepAlive = wrapped
            commands.addCompletedHandler { _ in _ = keepAlive }
            commands.commit()
        } catch {
            log.error("screen feed: \(String(describing: error), privacy: .public)")
            return nil
        }
        return panel
    }
}
