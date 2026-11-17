import AppKit

/// One run of duorex in a terminal pane: the pane's input, the device drawn over it, and the simulator behind it.
final class Session {
    private let pane: Pane
    private let stage: StageView
    private let dock: Dock
    private let feed: ScreenFeed
    private let rex: RexHost?
    private var sim: Sim?
    private var signals: [DispatchSourceSignal] = []
    private var status = "starting the simulator…"
    /// The simulator's interface orientation, which decides where the home swipe starts.
    private var orientation = "portrait"
    private var touchEdge: Int?
    private var hingeKnown = false
    private var lastHingeSent = Date.distantPast

    private static let hint = "drag the frame to fold  ·  1 2 3 poses  ·  h home  ·  q quit"
    /// Hinge angles for the three poses the number keys choose.
    private static let poses: [Character: Double] = ["1": 0, "2": 130, "3": 180]

    init(scene: DuoScene) throws {
        pane = try Pane()
        stage = StageView(scene: scene)
        feed = try ScreenFeed(scene: scene)
        rex = RexHost()
        dock = Dock(stage: stage, hostBundleID: rex == nil ? nil : RexHost.bundleID)
    }

    func start() {
        pane.onEvent = { [unowned self] event in handle(event) }
        pane.start()
        paneResized()
        rex?.onChange = { [unowned self] placement in dock.placement = placement }
        rex?.start()

        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [unowned self] in quit() }
            source.resume()
            signals.append(source)
        }
    }

    /// Connects the device to a simulator on serve-sim.
    func attach(to address: URL) {
        let sim = Sim(base: address)
        self.sim = sim
        sim.onFrame = { [unowned self] frame in
            guard let panel = feed.show(frame) else { return }
            if panel != stage.activePanel || status != Self.hint {
                stage.activePanel = panel
                feed.turnOff(panel == .cover ? .inner : .cover)
                // Until the simulator reports its hinge, the lit panel says whether it is open.
                if !hingeKnown { stage.follow(hinge: panel == .cover ? 0 : 180, animated: false) }
                show(Self.hint)
            }
            stage.setNeedsRender()
        }
        sim.onConfig = { [unowned self] config in
            orientation = config.orientation
            guard let hinge = config.hingeDegrees else { return }
            // The simulator echoes the user's own fold a moment late. Only a change from elsewhere is news.
            let external = Date().timeIntervalSince(lastHingeSent) > 1 && abs(hinge - stage.hingeDegrees) > 3
            if !hingeKnown || external { stage.follow(hinge: hinge, animated: hingeKnown) }
            hingeKnown = true
        }
        stage.onTouch = { [unowned self] phase, hit in
            if phase == .begin { touchEdge = Self.homeEdge(at: hit.point, orientation: orientation) }
            sim.touch(phase.rawValue, x: hit.point.x, y: hit.point.y, edge: touchEdge)
        }
        stage.onHinge = { [unowned self] degrees in
            lastHingeSent = Date()
            hingeKnown = true
            sim.fold(to: degrees)
        }
        sim.start()
    }

    /// Shows a line of text under the device.
    func show(_ status: String) {
        self.status = status
        pane.caption(status)
    }

    /// A touch that starts in the bottom 7% of the interface is the swipe home. serve-sim wants it
    /// tagged with the framebuffer edge it starts from: 1 left, 2 top, 3 bottom, 4 right.
    private static func homeEdge(at point: CGPoint, orientation: String) -> Int? {
        let (edge, depth): (Int, Double) = switch orientation {
        case "landscape_left": (4, point.x)
        case "landscape_right": (1, 1 - point.x)
        case "portrait_upside_down": (2, 1 - point.y)
        default: (3, point.y)
        }
        return depth >= 0.93 ? edge : nil
    }

    private func handle(_ event: Pane.Event) {
        switch event {
        case .pointer(let pointer):
            let point = CGPoint(x: pointer.x / dock.scale, y: pointer.y / dock.scale)
            dock.pointerSeen(at: point)
            switch pointer.kind {
            case .down: stage.pointerDown(at: point, option: pointer.option)
            case .move, .drag: stage.pointerMoved(to: point)
            case .up: stage.pointerUp(at: point)
            case .wheel(let lines): stage.scroll(at: point, lines: lines)
            }
        case .key(let key):
            switch key {
            case "q", "\u{03}", "\u{04}": quit()
            case "1", "2", "3": stage.fold(to: Self.poses[key]!)
            case "[": stage.fold(to: stage.hingeDegrees - 10)
            case "]": stage.fold(to: stage.hingeDegrees + 10)
            case "h": sim?.press("swipe_home")
            default: break
            }
        case .resized:
            paneResized()
        case .focus:
            break
        }
    }

    private func paneResized() {
        log.info("pane \(self.pane.size.columns)x\(self.pane.size.rows) cells, \(self.pane.size.pixelWidth)x\(self.pane.size.pixelHeight) px")
        dock.paneResized(pixelWidth: pane.size.pixelWidth, pixelHeight: pane.size.pixelHeight)
        pane.caption(status)
    }

    private func quit() -> Never {
        sim?.stop()
        rex?.stop()
        pane.restore()
        exit(0)
    }
}
