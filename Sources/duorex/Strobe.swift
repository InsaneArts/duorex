import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

/// One still picture of the device at several fold angles at once, like a strobe photo of a
/// door that swings: the half that does not fold lies still, and the other half shows at each angle.
enum Strobe {
    /// The fold angles of the exposures, from flat to upright. Past upright, the half that
    /// folds would hide the app on the half that lies still.
    static let hinges: [Double] = [180, 166, 152, 138, 124, 110, 96]

    /// The device as it lies for the picture: on its back, seen from the front and from above.
    private static func pose(hinge: Double) -> Pose {
        Pose(hinge: hinge, roll: 24, pitch: -52, isAnchored: true)
    }

    static func image(scene: DuoScene, width: Int, height: Int) async throws -> CGImage {
        guard let frame = Frame(device: scene.device, width: width, height: height) else { throw DuoError.render("could not create the strobe frame") }
        let poses = hinges.map(pose)
        var exposures: [CIImage] = []
        for pose in poses {
            try await scene.draw(pose, framing: poses, into: frame)
            // The frame is drawn again for the next exposure, so each picture is copied out.
            guard let picture = frame.image() else { throw DuoError.render("could not read an exposure") }
            exposures.append(CIImage(cgImage: picture))
        }
        // The flat device is the picture's ground: it stands on the stage with its shadow.
        var picture = Stage.compose(exposures[0], over: Stage.image(width: width, height: height))
        // Each later flash lies over the ones before it, as the half that folds comes up toward
        // the camera. The first ones are faint and the last is solid: the device moved from flat to there.
        for (index, exposure) in exposures.enumerated().dropFirst() {
            let share = CGFloat(index - 1) / CGFloat(exposures.count - 2)
            let opacity = 0.3 + 0.7 * share * share
            picture = exposure.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: opacity, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: opacity, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: opacity, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
            ]).composited(over: picture)
        }
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        guard let result = CIContext(mtlDevice: scene.device).createCGImage(picture.cropped(to: extent), from: extent) else {
            throw DuoError.render("could not draw the strobe picture")
        }
        return result
    }

    static func write(scene: DuoScene, width: Int, height: Int, to url: URL) async throws {
        let image = try await image(scene: scene, width: width, height: height)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw DuoError.render("could not write \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw DuoError.render("could not write \(url.path)") }
    }
}
