import AppKit

/// One run of duorex in a terminal pane: the pane's input, the device drawn over it, and the simulator behind it.
final class Session {
    private let pane: Pane
    private let stage: StageView
    private let dock: Dock
    private let feed: ScreenFeed
    private let rex: RexHost?
    private var sim: Sim?
    private var sync = PoseSync()
    private var signals: [DispatchSourceSignal] = []
    private var status = "starting the simulator…"
    /// How the interface is turned inside the lit panel's framebuffer.
    private var interface = Orientation.portrait
    /// The edge tag of the touch in progress, when it began as the swipe home.
    private var touchEdge: Int?
    private var framesDecoded = 0

    private static let hint = "drag the frame to fold  ·  1 2 3 poses  ·  r rotate  ·  h home  ·  q quit"
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
        // `log stream --level debug --predicate 'process == "duorex"'` shows the frame rates.
        let rates = Timer(timeInterval: 2, repeats: true) { [unowned self] _ in
            MainActor.assumeIsolated {
                log.debug("decoded \(self.framesDecoded / 2) fps, drawn \(self.stage.framesDrawn / 2) fps")
                framesDecoded = 0
                stage.resetFrameCount()
            }
        }
        RunLoop.main.add(rates, forMode: .common)
    }

    /// Connects the device to a simulator on serve-sim.
    func attach(to address: URL) {
        log.info("simulator at \(address.absoluteString, privacy: .public)")
        let sim = Sim(base: address)
        self.sim = sim
        sim.onFrame = { [unowned self] frame in
            framesDecoded += 1
            guard let panel = feed.show(frame) else { return }
            if panel != stage.activePanel || status != Self.hint {
                stage.activePanel = panel
                feed.turnOff(panel.other)
                move(sync.panelLit(panel))
                show(Self.hint)
            }
            stage.setNeedsRender()
        }
        sim.onReport = { [unowned self] report in
            interface = Orientation(rawValue: report.orientation) ?? .portrait
            let now = CACurrentMediaTime()
            if let held = report.duoViewOrientation.flatMap(Orientation.init(rawValue:)),
               let turned = sync.simulatorReported(held: held, time: now) {
                stage.rotate(to: turned.roll)
            }
            if let hinge = report.hingeDegrees {
                move(sync.simulatorReported(hinge: hinge, shown: stage.hingeDegrees, time: now))
            }
        }
        stage.onEffect = { [unowned self] effect in
            switch effect {
            case .touch(let phase, let point):
                if phase == .begin { touchEdge = interface.homeEdge(atFramebufferPoint: point) }
                sim.send(.touch(phase, x: point.x, y: point.y, edge: touchEdge))
            case .scroll(let phase, let point):
                sim.send(.touch(phase, x: point.x, y: point.y, edge: nil))
            case .hinge(let degrees):
                sync.userMovedHinge(time: CACurrentMediaTime())
                sim.fold(to: degrees)
            }
        }
        sim.start()
    }

    /// Shows a line of text under the device.
    func show(_ status: String) {
        self.status = status
        pane.caption(status)
    }

    /// Does what the sync decided about a hinge angle from the simulator.
    private func move(_ action: PoseSync.HingeAction) {
        switch action {
        case .snap(let degrees): stage.follow(hinge: degrees, animated: false)
        case .follow(let degrees): stage.follow(hinge: degrees, animated: true)
        case .ignore: break
        }
    }

    /// Goes home the way a finger does: a quick swipe up from the bottom edge of the interface.
    /// serve-sim's own home button does not reach the Duo.
    private func swipeHome() {
        guard let sim else { return }
        let steps = 12
        let start = interface.framebufferPoint(CGPoint(x: 0.5, y: 0.985))
        let edge = interface.homeEdge(atFramebufferPoint: start)
        for step in 0...steps {
            let point = interface.framebufferPoint(CGPoint(x: 0.5, y: 0.985 - 0.5 * Double(step) / Double(steps)))
            let phase: DeviceMotion.TouchPhase = step == 0 ? .begin : step == steps ? .end : .move
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.016) {
                sim.send(.touch(phase, x: point.x, y: point.y, edge: edge))
            }
        }
    }

    private func handle(_ event: Pane.Event) {
        switch event {
        case .pointer(let pointer):
            let point = CGPoint(x: pointer.x / dock.scale, y: pointer.y / dock.scale)
            dock.pointerSeen(at: point)
            // Rex reports the pointer to this pane even when it is over another one, clamped to
            // this pane's edge. Out there, only a drag that began on the device may continue.
            guard dock.contains(point) || stage.isDragging else {
                stage.pointerLeft()
                return
            }
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
            case "h": swipeHome()
            case "r":
                let held = sync.userTurned(time: CACurrentMediaTime())
                stage.rotate(to: held.roll)
                sim?.send(.rotate(held))
            default: break
            }
        case .resized:
            paneResized()
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
