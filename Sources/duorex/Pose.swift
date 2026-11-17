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
}
