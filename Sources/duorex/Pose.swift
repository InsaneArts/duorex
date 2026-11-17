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
    /// True when the half that does not fold stays in one place, as on a table. Otherwise the
    /// device turns and moves aside as it folds, so that it faces the camera in every posture.
    var isAnchored = false

    struct Press: Equatable {
        var button: HardwareButton
        var depth: Double
    }
}
