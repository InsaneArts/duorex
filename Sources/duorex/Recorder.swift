import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Records the device alone, over a studio backdrop, to a movie file.
///
/// The pane shows the device over the terminal. The movie shows the same device, in the same
/// pose and with the same screens, drawn again at the movie's size and set on a stage.
final class Recorder {
    let url: URL

    private let frame: Frame
    private let stage: CIImage
    private let context: CIContext
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var startTime: Double?
    private var lastTime = -Double.infinity
    private var drawing = false
    /// True from the moment the movie starts to end. No more pictures are taken after that.
    private var closing = false

    init(scene: DuoScene, url: URL, width: Int, height: Int) throws {
        guard let frame = Frame(device: scene.device, width: width, height: height) else { throw DuoError.render("could not create the movie frame") }
        self.frame = frame
        self.url = url
        stage = Stage.image(width: width, height: height)
        context = CIContext(mtlDevice: scene.device)

        try Self.makeRoom(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 8,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 120,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw DuoError.render("could not start the movie: \(writer.error?.localizedDescription ?? "unknown error")") }
        writer.startSession(atSourceTime: .zero)
    }

    /// Removes a movie that has the new one's name. A folder is never removed: `--out` with
    /// its value forgotten names the working directory.
    static func makeRoom(at url: URL) throws {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return }
        guard !isFolder.boolValue else { throw DuoError.render("\(url.path) is a folder. Give --out the name of a movie file.") }
        try FileManager.default.removeItem(at: url)
    }

    /// Adds the scene, as it is posed now, to the movie. Call it after each change, with the time in seconds.
    /// It keeps to 60 pictures a second and draws one picture at a time. Returns false when
    /// this picture has to wait: ask again at the next tick.
    func capture(scene: DuoScene, time: Double) -> Bool {
        guard !closing else { return true }
        guard !drawing, time - lastTime >= 1.0 / 61 else { return false }
        draw(scene, at: time)
        return true
    }

    /// Adds the scene, as it is posed now, at `time`, and returns when that picture is in the
    /// movie. It is for a film that is drawn at its own pace, not at the pace it plays.
    /// It throws when the movie can take no more pictures, as when the disk is full, and when the task is cancelled.
    func add(scene: DuoScene, time: Double) async throws {
        while drawing || !input.isReadyForMoreMediaData {
            // A writer that stopped is never ready again.
            guard writer.status == .writing else {
                throw DuoError.render("could not write the movie: \(writer.error?.localizedDescription ?? "the writer stopped")")
            }
            try Task.checkCancellation()
            try? await Task.sleep(for: .milliseconds(1))
        }
        draw(scene, at: time)
        while drawing { try? await Task.sleep(for: .milliseconds(1)) }
    }

    /// Gives the movie up and deletes what was written of it.
    func cancel() {
        closing = true
        if writer.status == .writing { writer.cancelWriting() }
    }

    /// A time in the movie. Sixtieths of a second are exact in it, so a film's pictures are evenly spaced.
    nonisolated static func time(_ seconds: Double) -> CMTime {
        CMTime(value: CMTimeValue((seconds * 60_000).rounded()), timescale: 60_000)
    }

    /// Ends the movie at `time`, so it lasts as long as the recording did, and writes the file.
    /// Throws when the file could not be written, as when the disk is full.
    func finish(scene: DuoScene, time: Double) async throws {
        guard !closing else { return }
        closing = true
        while drawing { try? await Task.sleep(for: .milliseconds(5)) }
        // One last picture at the end time. Without it the movie would stop at the last change.
        // A movie's pictures must be in order, so it never comes before the one already taken.
        draw(scene, at: max(time, lastTime + 1.0 / 60))
        while drawing { try? await Task.sleep(for: .milliseconds(5)) }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw DuoError.render("could not write the movie: \(writer.error?.localizedDescription ?? "unknown error")")
        }
    }

    private func draw(_ scene: DuoScene, at time: Double) {
        drawing = true
        lastTime = time
        let start = startTime ?? time
        startTime = start
        do {
            try scene.render(into: frame) { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.append(at: time - start)
                    self.drawing = false
                }
            }
        } catch {
            drawing = false
            log.error("record: \(String(describing: error), privacy: .public)")
        }
    }

    private func append(at seconds: Double) {
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        let device = CIImage(ioSurface: frame.surface)
        context.render(Stage.compose(device, over: stage), to: buffer, bounds: stage.extent, colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
        adaptor.append(buffer, withPresentationTime: Self.time(seconds))
    }
}

/// The studio the recorded device stands in: a dark stage with a pool of light, and the shadow the device casts on it.
enum Stage {
    /// The empty stage.
    static func image(width: Int, height: Int) -> CIImage {
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let w = CGFloat(width), h = CGFloat(height)

        // The wall: darkest at the top, a little lighter toward the floor.
        let wall = CIFilter.linearGradient()
        wall.point0 = CGPoint(x: 0, y: h)
        wall.point1 = CGPoint(x: 0, y: 0)
        wall.color0 = CIColor(red: 0.043, green: 0.046, blue: 0.055)
        wall.color1 = CIColor(red: 0.105, green: 0.110, blue: 0.128)

        // A pool of light behind the device, as from a softbox above it.
        let light = CIFilter.radialGradient()
        light.center = CGPoint(x: w / 2, y: h * 0.52)
        light.radius0 = 0
        light.radius1 = Float(max(w, h) * 0.62)
        light.color0 = CIColor(red: 0.36, green: 0.38, blue: 0.44, alpha: 0.55)
        light.color1 = CIColor(red: 0.36, green: 0.38, blue: 0.44, alpha: 0)

        // Darker corners pull the eye to the middle.
        let vignette = CIFilter.radialGradient()
        vignette.center = CGPoint(x: w / 2, y: h / 2)
        vignette.radius0 = Float(min(w, h) * 0.45)
        vignette.radius1 = Float(max(w, h) * 0.78)
        vignette.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        vignette.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0.55)

        // A trace of grain keeps the smooth gradients from showing bands once the movie is compressed.
        let grain = CIFilter.randomGenerator().outputImage!
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.03, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0.03, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0.03, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: -0.015, y: -0.015, z: -0.015, w: 0),
            ])

        let lit = vignette.outputImage!.composited(over: light.outputImage!.composited(over: wall.outputImage!))
        return lit.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: grain]).cropped(to: extent)
    }

    /// The device on the stage. `device` has a transparent background and the stage's size.
    static func compose(_ device: CIImage, over stage: CIImage) -> CIImage {
        let height = stage.extent.height
        // The device's outline in black gives its shadow: one tight and close, one wide and soft.
        func shadow(opacity: CGFloat, blur: CGFloat, drop: CGFloat) -> CIImage {
            device.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
            ])
            .applyingGaussianBlur(sigma: height * blur)
            .transformed(by: CGAffineTransform(translationX: 0, y: -height * drop))
        }
        let wide = shadow(opacity: 0.6, blur: 0.06, drop: 0.05)
        let close = shadow(opacity: 0.5, blur: 0.012, drop: 0.012)
        // The screens light the room: a wide blur of the device, added to the stage, puts the
        // colours of the app on the wall behind it.
        let glow = device.applyingGaussianBlur(sigma: height * 0.11)
            .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.5)])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35])
        let lit = glow.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: stage])
        return device.composited(over: close).composited(over: wide).composited(over: lit).cropped(to: stage.extent)
    }
}
