/// Keeps the device on screen and the simulator in the same pose. Either side can move first:
/// the user folds the device on screen, or an agent folds the simulator.
nonisolated struct PoseSync {
    /// What the device on screen does about a hinge angle from the simulator.
    enum HingeAction: Equatable {
        /// Jump there. This is the first the device hears of the simulator's pose.
        case snap(Double)
        /// Animate there. Something other than the user moved the simulator.
        case follow(Double)
        /// Stay. The report is the echo of the user's own fold, or changes nothing.
        case ignore
    }

    /// How the simulator says the device is held.
    private(set) var held = Orientation.portrait
    /// The hinge angle the simulator last reported, in degrees.
    private(set) var reportedHinge: Double?
    private var hingeKnown = false
    private var lastHingeSent = -Double.infinity
    private var lastTurn = -Double.infinity

    /// The user moved the hinge on screen at `time`, and the new angle went to the simulator.
    mutating func userMovedHinge(time: Double) {
        lastHingeSent = time
        hingeKnown = true
    }

    /// The simulator reported its hinge angle. `shown` is the angle on screen.
    mutating func simulatorReported(hinge: Double, shown: Double, time: Double) -> HingeAction {
        reportedHinge = hinge
        guard hingeKnown else {
            hingeKnown = true
            return .snap(hinge)
        }
        // The simulator reports the user's own fold back a moment late. Only a change from elsewhere is news.
        let echo = time - lastHingeSent <= 1
        return !echo && abs(hinge - shown) > 3 ? .follow(hinge) : .ignore
    }

    /// The simulator lit a panel. Until it reports a hinge angle, the lit panel says whether it is open.
    func panelLit(_ panel: Panel) -> HingeAction {
        hingeKnown ? .ignore : .snap(panel == .cover ? 0 : 180)
    }

    /// The user asked for the next quarter turn at `time`. Returns how the device is held now.
    mutating func userTurned(time: Double) -> Orientation {
        held = held.next
        lastTurn = time
        return held
    }

    /// The simulator reported how the device is held. Returns the new orientation, or nil when nothing changes.
    mutating func simulatorReported(held reported: Orientation, time: Double) -> Orientation? {
        // A report sent before the simulator took the user's turn would turn the device back.
        guard reported != held, time - lastTurn > 1.5 else { return nil }
        held = reported
        return reported
    }
}
