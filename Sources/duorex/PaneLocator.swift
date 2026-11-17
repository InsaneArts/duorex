import CoreGraphics

/// Works out where the pane is inside its window from the terminal's pointer reports.
///
/// A report carries the pointer's position inside the pane. The system knows where the pointer
/// is on screen. For a pointer that is over the pane, the difference is the pane's origin.
///
/// The origin is fixed for a given layout, so one good measurement is enough. Later reports
/// may only correct it by a few points, and only from a pointer that is still.
nonisolated struct PaneLocator {
    /// The pane's top left corner inside the host window, in points.
    private(set) var origin: CGPoint?
    /// True when `origin` came from a report, false when it is a prediction.
    private(set) var isMeasured = false
    private var lastPointer = CGPoint.zero
    private var lastTime = -Double.infinity

    /// Rex keeps reporting after the pointer leaves the pane, with the position clamped to the
    /// pane's edge. A report this close to the edge says nothing about where the pane is.
    static func isInside(_ local: CGPoint, paneSize: CGSize) -> Bool {
        let margin: CGFloat = 2
        return local.x > margin && local.y > margin && local.x < paneSize.width - margin && local.y < paneSize.height - margin
    }

    /// The window, the pane or the layout changed, so the old measurement no longer holds.
    mutating func layoutChanged(predicted: CGPoint?) {
        isMeasured = false
        if let predicted { origin = predicted }
    }

    /// Whether a report can say where the pane is. Call it for every report, in order.
    /// `pointer` is the pointer on screen, `local` its position in the pane, `time` in seconds.
    mutating func wants(local: CGPoint, pointer: CGPoint, paneSize: CGSize, time: Double) -> Bool {
        let step = hypot(pointer.x - lastPointer.x, pointer.y - lastPointer.y)
        let gap = time - lastTime
        lastPointer = pointer
        lastTime = time
        guard Self.isInside(local, paneSize: paneSize) else { return false }
        // A report lags the pointer by a few milliseconds. Two close reports in a row mean the
        // pointer is slow enough for that lag not to matter.
        return gap < 0.25 && step < (isMeasured ? 0.5 : 1.5)
    }

    /// Takes the origin a wanted report gives. Returns true when the origin changed.
    mutating func measure(_ candidate: CGPoint) -> Bool {
        if isMeasured, let origin {
            let change = hypot(origin.x - candidate.x, origin.y - candidate.y)
            guard change >= 0.5, change < 8 else { return false }
        }
        origin = candidate
        isMeasured = true
        return true
    }
}
