import Foundation

/// A damped spring toward a target. It gives folds and tilts weight instead of easing curves.
nonisolated struct Spring {
    var value: Double
    var target: Double
    var velocity = 0.0
    /// Seconds for one undamped oscillation. Smaller is snappier.
    var response: Double
    /// 1 stops without overshoot. Lower values bounce.
    var damping: Double

    init(_ value: Double, response: Double = 0.45, damping: Double = 0.85) {
        self.value = value
        self.target = value
        self.response = response
        self.damping = damping
    }

    /// Pins the spring to a value, as while the user is dragging.
    mutating func hold(_ value: Double) {
        self.value = value
        target = value
        velocity = 0
    }

    /// Advances the spring. Returns true while it is still moving.
    mutating func step(_ dt: Double) -> Bool {
        guard abs(target - value) > 0.001 || abs(velocity) > 0.01 else {
            value = target
            velocity = 0
            return false
        }
        let omega = 2 * Double.pi / response
        // Small fixed substeps keep a stiff spring stable on a slow frame.
        let steps = max(1, Int((dt / 0.004).rounded(.up)))
        let h = dt / Double(steps)
        for _ in 0..<steps {
            let acceleration = omega * omega * (target - value) - 2 * damping * omega * velocity
            velocity += acceleration * h
            value += velocity * h
        }
        return true
    }
}
