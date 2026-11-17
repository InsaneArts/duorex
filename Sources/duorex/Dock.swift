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
    var placement = Placement() { didSet { if placement != oldValue { predictOrigin() } } }

    private let panel: NSPanel
    private var host: (window: CGWindowID, pid: pid_t)?
    private var hostBounds = CGRect.zero
    /// The pane's top left corner inside the host window, in points.
    private var origin: CGPoint?
    private var paneSize = CGSize.zero
    /// Window chrome above and to the right of the pane area, learned from pointer reports.
    private var chrome: (top: CGFloat, right: CGFloat)?
    private var lastPointer = CGPoint.zero
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

        let app = hostBundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first } ?? NSWorkspace.shared.frontmostApplication
        if let app, let window = Self.frontWindow(of: app.processIdentifier) {
            host = (window.id, app.processIdentifier)
            hostBounds = window.bounds
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
        paneSize = CGSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
        predictOrigin()
    }

    /// The terminal reported the pointer at `local`, in points from the pane's top left.
    func pointerSeen(at local: CGPoint) {
        let pointer = Self.pointerLocation()
        defer { lastPointer = pointer }
        guard let window = Self.window(under: pointer, excluding: getpid()) else {
            log.notice("no host window under the pointer at \(pointer.x, format: .fixed(precision: 0)), \(pointer.y, format: .fixed(precision: 0))")
            return
        }
        // A report lags the pointer by a few milliseconds, so only a slow pointer gives a true origin.
        let slow = hypot(pointer.x - lastPointer.x, pointer.y - lastPointer.y) < 1.5
        guard origin == nil || host?.window != window.id || slow else { return }
        host = (window.id, window.pid)
        hostBounds = window.bounds
        updateScale()
        let measured = CGPoint(x: pointer.x - local.x - window.bounds.minX, y: pointer.y - local.y - window.bounds.minY)
        if let origin, hypot(origin.x - measured.x, origin.y - measured.y) < 1 { return }
        origin = measured
        log.notice("pane origin in window: \(measured.x, format: .fixed(precision: 1)), \(measured.y, format: .fixed(precision: 1))")
        learnChrome()
        follow()
    }

    // MARK: Following

    private func follow() {
        guard let host, origin != nil, paneSize.width > 1, placement.shown,
              let info = Self.describe(host.window), info.onScreen,
              placement.titleSuffix.map({ suffix in info.title.map { $0.hasSuffix(suffix) } ?? true }) ?? true
        else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        if info.bounds.size != hostBounds.size {
            hostBounds = info.bounds
            predictOrigin()
        }
        hostBounds = info.bounds
        guard let origin else { return }
        let top = hostBounds.minY + origin.y
        let frame = CGRect(x: hostBounds.minX + origin.x, y: Self.primaryHeight() - top - paneSize.height,
                           width: paneSize.width, height: paneSize.height)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        if !panel.isVisible {
            log.notice("showing the device at \(frame.debugDescription, privacy: .public)")
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

    /// The pane area is the window minus its chrome. With the chrome known, a new window size,
    /// pane size or layout gives the new origin without waiting for the pointer.
    private func predictOrigin() {
        guard let chrome, paneSize.width > 1, hostBounds.width > 1, placement.rect.width > 0, placement.rect.height > 0 else { return }
        let areaWidth = paneSize.width / placement.rect.width
        let areaHeight = paneSize.height / placement.rect.height
        let areaLeft = hostBounds.width - chrome.right - areaWidth
        origin = CGPoint(x: areaLeft + placement.rect.minX * areaWidth, y: chrome.top + placement.rect.minY * areaHeight)
    }

    private func learnChrome() {
        guard let origin, let host, paneSize.width > 1, placement.rect.width > 0, placement.rect.height > 0 else { return }
        let areaWidth = paneSize.width / placement.rect.width
        let areaHeight = paneSize.height / placement.rect.height
        let top = origin.y - placement.rect.minY * areaHeight
        let right = hostBounds.width - (origin.x - placement.rect.minX * areaWidth) - areaWidth
        chrome = (top, right)
        UserDefaults.standard.set([Double(top), Double(right)], forKey: Self.chromeKey(host.pid))
    }

    private func updateScale() {
        let center = CGPoint(x: hostBounds.midX, y: Self.primaryHeight() - hostBounds.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }), screen.backingScaleFactor != scale else { return }
        paneSize = CGSize(width: paneSize.width * scale / screen.backingScaleFactor, height: paneSize.height * scale / screen.backingScaleFactor)
        scale = screen.backingScaleFactor
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
