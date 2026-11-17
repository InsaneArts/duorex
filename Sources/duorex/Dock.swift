import AppKit

/// A click-through window that covers the terminal pane and follows its host window.
/// The terminal keeps the pointer and the keyboard, so the pane stays a normal Rex pane.
///
/// Nothing reports where a pane is on screen. Each pointer report from the terminal carries the
/// pointer's position inside the pane, and the system knows where the pointer is on screen: the
/// difference is the pane's origin. Between reports the origin is predicted from the window size.
final class Dock {
    /// What the multiplexer says about this pane. The defaults fit a terminal with one pane.
    struct Placement: Equatable {
        /// The pane's share of the window's pane area, as x, y, width, height in 0...1.
        var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        var shown = true
        /// When set, the host window's title must end with it for the pane to count as shown.
        var titleSuffix: String?
    }

    let stage: StageView
    var placement = Placement() { didSet { if placement.rect != oldValue.rect { layoutChanged() } } }

    private let panel: NSPanel
    private var host: (window: CGWindowID, pid: pid_t)?
    private var hostBounds = CGRect.zero
    /// Set when the host is known by its app, as Rex is. The pane is then only looked for in that app.
    private var pinnedHost: pid_t?
    private var locator = PaneLocator()
    private var paneSize = CGSize.zero
    /// Window chrome above and to the right of the pane area, learned from pointer reports.
    private var chrome: (top: CGFloat, right: CGFloat)?
    private var timer: Timer?
    private var activation: NSObjectProtocol?

    /// Pixels per point on the host window's screen.
    private(set) var scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2

    init(stage: StageView, hostBundleID: String?) {
        self.stage = stage
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = stage

        let known = hostBundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
        pinnedHost = known?.processIdentifier
        if let app = known ?? NSWorkspace.shared.frontmostApplication, let window = Self.frontWindow(of: app.processIdentifier) {
            host = (window.id, app.processIdentifier)
            hostBounds = window.bounds
            updateScale()
            let saved = UserDefaults.standard.array(forKey: Self.chromeKey(app.processIdentifier)) as? [Double]
            if let saved, saved.count == 2 { chrome = (CGFloat(saved[0]), CGFloat(saved[1])) }
        }
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restack() }
        }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The pane's size changed. Sizes are in pixels, as the terminal reports them.
    func paneResized(pixelWidth: Int, pixelHeight: Int) {
        let size = CGSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
        guard size != paneSize else { return }
        paneSize = size
        layoutChanged()
    }

    /// Whether a pane position is inside the pane, and not on the edge the terminal clamps to.
    func contains(_ local: CGPoint) -> Bool { PaneLocator.isInside(local, paneSize: paneSize) }

    /// The terminal reported the pointer at `local`, in points from the pane's top left.
    func pointerSeen(at local: CGPoint) {
        let pointer = Self.pointerLocation()
        guard locator.wants(local: local, pointer: pointer, paneSize: paneSize, time: CACurrentMediaTime()),
              let window = Self.window(under: pointer, excluding: getpid()) else { return }
        // A found pane can move to another window of its app, but never to another app.
        if let expected = locator.isMeasured ? host?.pid : pinnedHost, window.pid != expected { return }
        if window.id != host?.window { locator.layoutChanged(predicted: nil) }
        host = (window.id, window.pid)
        hostBounds = window.bounds
        // On a screen with another scale, `local` was converted with the wrong one. The next report is right.
        guard !updateScale() else { return }
        guard locator.measure(CGPoint(x: pointer.x - local.x - window.bounds.minX, y: pointer.y - local.y - window.bounds.minY)),
              let origin = locator.origin else { return }
        log.info("pane origin in window: \(origin.x, format: .fixed(precision: 1)), \(origin.y, format: .fixed(precision: 1))")
        learnChrome()
        follow()
    }

    // MARK: Following

    private func follow() {
        guard let host, locator.origin != nil, paneSize.width > 1, placement.shown,
              let info = Self.describe(host.window), info.onScreen,
              placement.titleSuffix.map({ suffix in info.title.map { $0.hasSuffix(suffix) } ?? true }) ?? true
        else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        let resized = info.bounds.size != hostBounds.size
        hostBounds = info.bounds
        if resized { layoutChanged() }
        guard let origin = locator.origin else { return }
        let top = hostBounds.minY + origin.y
        let frame = CGRect(x: hostBounds.minX + origin.x, y: Self.primaryHeight() - top - paneSize.height,
                           width: paneSize.width, height: paneSize.height)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        if !panel.isVisible {
            log.info("showing the device at \(frame.debugDescription, privacy: .public)")
            panel.orderFrontRegardless()
            restack()
            stage.setNeedsRender()
        }
    }

    /// Keeps the device directly above the host window, and no higher than it has to be.
    private func restack() {
        guard let host, panel.isVisible else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == host.pid {
            // The host raises its window on every click. Floating stays above it without a flicker.
            panel.level = .floating
        } else {
            panel.level = .normal
            panel.order(.above, relativeTo: Int(host.window))
        }
    }

    // MARK: Predicting the origin

    /// The window, the pane or the layout changed. The measured origin no longer holds, so the
    /// device goes where the chrome predicts until the pointer gives a new measurement.
    private func layoutChanged() {
        locator.layoutChanged(predicted: predictedOrigin())
    }

    /// The pane area is the window minus its chrome. With the chrome known, the window size,
    /// pane size and layout give the origin without waiting for the pointer.
    private func predictedOrigin() -> CGPoint? {
        guard let chrome, paneSize.width > 1, hostBounds.width > 1, placement.rect.width > 0, placement.rect.height > 0 else { return nil }
        let areaWidth = paneSize.width / placement.rect.width
        let areaHeight = paneSize.height / placement.rect.height
        let areaLeft = hostBounds.width - chrome.right - areaWidth
        return CGPoint(x: areaLeft + placement.rect.minX * areaWidth, y: chrome.top + placement.rect.minY * areaHeight)
    }

    private func learnChrome() {
        guard let origin = locator.origin, let host, paneSize.width > 1, placement.rect.width > 0, placement.rect.height > 0 else { return }
        let areaWidth = paneSize.width / placement.rect.width
        let areaHeight = paneSize.height / placement.rect.height
        let top = origin.y - placement.rect.minY * areaHeight
        let right = hostBounds.width - (origin.x - placement.rect.minX * areaWidth) - areaWidth
        chrome = (top, right)
        UserDefaults.standard.set([Double(top), Double(right)], forKey: Self.chromeKey(host.pid))
    }

    /// Takes the scale of the screen the host window is on. Returns true when it changed.
    @discardableResult
    private func updateScale() -> Bool {
        let center = CGPoint(x: hostBounds.midX, y: Self.primaryHeight() - hostBounds.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }), screen.backingScaleFactor != scale else { return false }
        paneSize = CGSize(width: paneSize.width * scale / screen.backingScaleFactor, height: paneSize.height * scale / screen.backingScaleFactor)
        scale = screen.backingScaleFactor
        return true
    }

    // MARK: Window server

    private static func chromeKey(_ pid: pid_t) -> String {
        "chrome." + (NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "terminal")
    }

    /// Height of the primary screen. Quartz measures from its top, AppKit from its bottom.
    private static func primaryHeight() -> CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// The pointer in Quartz coordinates: points from the top left of the primary screen.
    private static func pointerLocation() -> CGPoint {
        let location = NSEvent.mouseLocation
        return CGPoint(x: location.x, y: primaryHeight() - location.y)
    }

    private static func onScreenWindows() -> [(id: CGWindowID, pid: pid_t, bounds: CGRect)] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { entry in
            guard entry[kCGWindowLayer as String] as? Int == 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = (entry[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  bounds.width > 100, bounds.height > 100 else { return nil }
            return (id, pid, bounds)
        }
    }

    private static func frontWindow(of pid: pid_t) -> (id: CGWindowID, bounds: CGRect)? {
        onScreenWindows().first { $0.pid == pid }.map { ($0.id, $0.bounds) }
    }

    /// The frontmost ordinary window under a point, front to back.
    private static func window(under point: CGPoint, excluding pid: pid_t) -> (id: CGWindowID, pid: pid_t, bounds: CGRect)? {
        onScreenWindows().first { $0.pid != pid && $0.bounds.contains(point) }
    }

    private static func describe(_ window: CGWindowID) -> (bounds: CGRect, onScreen: Bool, title: String?)? {
        // The array holds raw window IDs, not numbers.
        var ids = [UnsafeRawPointer(bitPattern: UInt(window))]
        let list = CGWindowListCreateDescriptionFromArray(CFArrayCreate(nil, &ids, 1, nil)) as? [[String: Any]]
        guard let entry = list?.first,
              let bounds = (entry[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }) else { return nil }
        // The title is only readable with the Screen Recording permission.
        return (bounds, entry[kCGWindowIsOnscreen as String] as? Bool ?? false, entry[kCGWindowName as String] as? String)
    }
}
