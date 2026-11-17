import CoreGraphics

/// Works out where the pane is inside its window.
///
/// Nothing reports a pane's place on screen, so it comes from two sources. A pointer report
/// carries the pointer's position inside the pane, and the system knows where the pointer is
/// on screen: for a pointer over the pane, the difference is the pane's origin. Between
/// reports, the origin is predicted from the window's chrome, which a measurement teaches.
///
/// A report is older than the pointer's position on screen, so the two only belong together
/// when the pointer is at rest. The origin is fixed for a given layout, so one measurement is
/// enough. Later ones may only correct it by a few points.
nonisolated struct PaneLocator {
    /// The window chrome above and to the right of the area the panes share, in points.
    /// It stays the same when the window, the pane or the layout changes.
    struct Chrome: Equatable {
        var top: CGFloat
        var right: CGFloat
    }

    /// Everything that decides where the pane is, apart from the chrome.
    struct Layout: Equatable {
        var windowSize = CGSize.zero
        var paneSize = CGSize.zero
        /// The pane's share of the area the panes share, as x, y, width, height in 0...1.
        var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    /// The pane's top left corner inside the host window, in points.
    private(set) var origin: CGPoint?
    /// True when `origin` came from a report, false when it is a prediction.
    private(set) var isMeasured = false
    /// What measurements taught about the window. Save it to place the pane at the next launch.
    private(set) var chrome: Chrome?
    private(set) var layout = Layout()
    /// The last report, with where the pointer was on screen and the time when it arrived.
    private var report: (local: CGPoint, pointer: CGPoint, time: Double)?

    init(chrome: Chrome? = nil) {
        self.chrome = chrome
    }

    /// Rex keeps reporting after the pointer leaves the pane, with the position clamped to the
    /// pane's edge. A report this close to the edge says nothing about where the pane is.
    func isInside(_ local: CGPoint) -> Bool {
        let margin: CGFloat = 2
        return local.x > margin && local.y > margin && local.x < layout.paneSize.width - margin && local.y < layout.paneSize.height - margin
    }

    /// The window, the pane or the layout may have changed. A new layout ends the old
    /// measurement, and the origin becomes the prediction until the pointer measures it again.
    mutating func update(_ layout: Layout) {
        guard layout != self.layout else { return }
        self.layout = layout
        isMeasured = false
        if let predicted { origin = predicted }
    }

    /// The pane moved to a window where nothing measured before still holds.
    mutating func forgetMeasurement() {
        isMeasured = false
    }

    /// Takes a pointer report. Call it for every report, in order.
    /// `local` is the pointer's position in the pane, `pointer` the pointer on screen now, `time` in seconds.
    mutating func reported(local: CGPoint, pointer: CGPoint, time: Double) {
        report = isInside(local) ? (local, pointer, time) : nil
    }

    /// The pointer's position in the pane, once the pointer is at rest there. Ask at every tick.
    /// A terminal reports every move, so a last report that stays the last one is from a pointer
    /// at rest. The pointer must also be where it was then: it can move where the terminal does not see it.
    mutating func restingReport(pointer: CGPoint, time: Double) -> CGPoint? {
        guard let report, time - report.time >= 0.1 else { return nil }
        self.report = nil
        guard hypot(pointer.x - report.pointer.x, pointer.y - report.pointer.y) < 1 else { return nil }
        return report.local
    }

    /// Takes the origin a resting report gives. Returns true when the origin changed.
    mutating func measure(_ candidate: CGPoint) -> Bool {
        if isMeasured, let origin {
            let change = hypot(origin.x - candidate.x, origin.y - candidate.y)
            guard change >= 0.5, change < 8 else { return false }
        }
        origin = candidate
        isMeasured = true
        if let area { chrome = Chrome(top: candidate.y - layout.rect.minY * area.height, right: layout.windowSize.width - (candidate.x - layout.rect.minX * area.width) - area.width) }
        return true
    }

    /// The size of the area the panes share: this pane's size scaled up by its share.
    private var area: CGSize? {
        guard layout.paneSize.width > 1, layout.windowSize.width > 1, layout.rect.width > 0, layout.rect.height > 0 else { return nil }
        return CGSize(width: layout.paneSize.width / layout.rect.width, height: layout.paneSize.height / layout.rect.height)
    }

    /// Where the chrome says the pane is. The pane area sits against the window's right edge and below its top chrome.
    private var predicted: CGPoint? {
        guard let chrome, let area else { return nil }
        let left = layout.windowSize.width - chrome.right - area.width
        return CGPoint(x: left + layout.rect.minX * area.width, y: chrome.top + layout.rect.minY * area.height)
    }
}
