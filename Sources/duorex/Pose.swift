/// How the device sits in front of the camera. Angles are in degrees.
nonisolated struct Pose: Equatable {
    /// 0 is closed, 180 is flat.
    var hinge: Double = 180
    /// Rotation about the view axis.
    var roll: Double = 0
    /// Tilt left and right.
    var yaw: Double = 0
    /// Tilt up and down.
    var pitch: Double = 0
    /// The hardware button that is pushed in, and how far: 0 is out, 1 is fully in.
    var press: Press?

    struct Press: Equatable {
        var button: HardwareButton
        var depth: Double
    }
}
