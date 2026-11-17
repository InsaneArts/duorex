import AppKit

/// One run of duorex in a terminal pane: the pane's input, the device drawn over it, and the simulator behind it.
final class Session {
    private let pane: Pane
    private let stage: StageView
    private let dock: Dock
    private let feed: ScreenFeed
    private let rex: RexHost?
    private let sound = FoldSound()
    private var sim: Sim?
    private var sync = PoseSync()
    private var signals: [DispatchSourceSignal] = []
    private var status = "starting the simulator…"
    /// The hardware button or the frame under the pointer.
    private var hovered: DeviceMotion.Hover?
    /// What another client of the simulator does now.
    private var activity: SimWire.Activity?
    /// How the interface is turned inside the lit panel's framebuffer.
    private var interface = Orientation.portrait
    /// The edge tag of the touch in progress, when it began as the swipe home.
    private var touchEdge: Int?
    private var framesDecoded = 0

    private var quitting = false

    /// The keys, as lines short enough for a narrow pane. "?" shows the next line.
    private var hint: String {
        [stage.recorder == nil ? "drag frame to fold  ·  1 2 3 poses  ·  ? keys  ·  q quit" : "● recording  ·  ? keys  ·  q stops and saves",
         "r rotate  ·  h home  ·  d dark  ·  + - text  ·  ? more",
         "s slow  ·  w memory warning  ·  m sound  ·  ? back"][hintLine]
    }
    private var hintLine = 0
    /// A word about the key that was just pressed. It gives way to the usual line after a moment.
    private var note: String?
    private var noteTimer: Timer?
    /// Whether duorex made the simulator's animations slow.
    private var slow = false
    private var changing: Task<Void, Never>?
    /// Hinge angles for the three poses the number keys choose.
    private static let poses: [Character: Double] = ["1": 0, "2": 130, "3": 180]

    /// `movie` is where to record the device to, or nil to only show it.
    init(scene: DuoScene, movie: (url: URL, width: Int, height: Int)? = nil) throws {
        pane = try Pane()
        stage = StageView(scene: scene)
        stage.recorder = try movie.map { try Recorder(scene: scene, url: $0.url, width: $0.width, height: $0.height) }
        feed = try ScreenFeed(scene: scene)
        rex = RexHost()
        dock = Dock(stage: stage, hostBundleID: rex == nil ? nil : RexHost.bundleID)
    }

    func start() {
        pane.onEvent = { [unowned self] event in handle(event) }
        pane.start()
        paneResized()
        // The stage works without a simulator too: it folds, makes its sounds and names its parts.
        stage.onEffect = { [unowned self] effect in
            switch effect {
            case .touch(let phase, let point):
                if phase == .begin { touchEdge = interface.homeEdge(atFramebufferPoint: point) }
                sim?.send(.touch(phase, x: point.x, y: point.y, edge: touchEdge))
            case .scroll(let phase, let point):
                sim?.send(.touch(phase, x: point.x, y: point.y, edge: nil))
            case .pinch(let phase, let first, let second):
                sim?.send(.pinch(phase, first, second))
            case .hinge(let degrees):
                sync.userMovedHinge(time: CACurrentMediaTime())
                sim?.fold(to: degrees)
            case .button(let button, let pressed):
                sim?.send(.button(button, pressed: pressed))
            case .sound(let sound, let strength):
                let played = self.sound.play(sound, strength: strength)
                log.debug("sound: \(String(describing: sound), privacy: .public) \(strength, format: .fixed(precision: 2)) played \(played)")
            }
        }
        // The buttons are small and the frame is thin. The line says what a press there takes hold of.
        stage.onHover = { [unowned self] hover in
            hovered = hover
            caption()
        }
        stage.onActivity = { [unowned self] activity in
            self.activity = activity
            caption()
        }
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
        let attached = CACurrentMediaTime()
        let sim = Sim(base: address)
        self.sim = sim
        sim.onFrame = { [unowned self] frame in
            if framesDecoded == 0, status != hint {
                log.info("first picture \(CACurrentMediaTime() - attached, format: .fixed(precision: 2)) s after attaching")
            }
            framesDecoded += 1
            guard let panel = feed.show(frame) else { return }
            if panel != stage.activePanel || status != hint {
                stage.activePanel = panel
                feed.turnOff(panel.other)
                move(sync.panelLit(panel))
                show(hint)
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
        sim.onActivity = { [unowned self] activity in
            log.debug("another client: \(String(describing: activity), privacy: .public)")
            stage.saw(activity)
        }
        sim.start()
    }

    /// Shows a line of text under the device. A new status is news, so it shows at once, whatever else the line said.
    func show(_ status: String) {
        self.status = status
        pane.caption(status)
    }

    /// Writes the line under the device: the button under the pointer, or what an agent does, or the status.
    private func caption() {
        if let note {
            pane.caption(note)
        } else if let hovered {
            switch hovered {
            case .button(let button): pane.caption("\(button.rawValue) button")
            // A drag from the frame folds, and a drag from beside it turns the device. The two are close.
            case .frame: pane.caption(stage.hingeDegrees < 10 ? "drag to open" : "drag to fold")
            }
        } else if let activity {
            pane.caption("● agent  ·  \(Presence.words(for: activity, interface: interface))", accent: true)
        } else {
            pane.caption(status)
        }
    }

    /// Says what a key did, for a moment.
    private func tell(_ text: String) {
        note = text
        noteTimer?.invalidate()
        noteTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [unowned self] _ in
            MainActor.assumeIsolated {
                note = nil
                caption()
            }
        }
        caption()
    }

    /// Changes a setting of the simulator, and says the new value or why it did not change.
    /// A change waits for the one before it, so two quick presses of a key are two changes.
    private func change(_ setting: @escaping (String) async throws -> String) {
        guard let device = sim?.device else { return tell("no simulator") }
        let before = changing
        changing = Task {
            await before?.value
            do { tell(try await setting(device)) } catch { tell("\(error)") }
        }
    }

    /// Shows the keys, as when there is no simulator to wait for.
    func showKeys() {
        show(hint)
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
            let point = dock.point(pixelX: pointer.x, y: pointer.y)
            dock.pointerSeen(at: point)
            // Rex reports the pointer to this pane even when it is over another one, clamped to
            // this pane's edge. Out there, only a drag that began on the device may continue.
            guard dock.contains(point) || stage.isDragging else {
                stage.pointerLeft()
                return
            }
            switch pointer.kind {
            case .down: stage.pointerDown(at: point, option: pointer.option)
            case .move, .drag: stage.pointerMoved(to: point, option: pointer.option, pressed: pointer.kind == .drag)
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
            case "?":
                let shown = status == hint
                hintLine = (hintLine + 1) % 3
                if shown { show(hint) }
            case "d":
                change { "\(try await SimSettings.toggleAppearance(of: $0)) appearance" }
            case "+", "=", "-":
                change { "text size: \(try await SimSettings.stepTextSize(of: $0, larger: key != "-"))" }
            case "s":
                guard let sim else { tell("no simulator"); break }
                slow.toggle()
                sim.send(.slowAnimations(slow))
                tell("slow animations \(slow ? "on" : "off")")
            case "w":
                guard let sim else { tell("no simulator"); break }
                sim.send(.memoryWarning)
                tell("memory warning")
            case "m":
                sound.isMuted.toggle()
                tell(sound.isMuted ? "sound off" : "sound on")
            default: break
            }
        case .resized:
            paneResized()
        }
    }

    private func paneResized() {
        log.info("pane \(self.pane.size.columns)x\(self.pane.size.rows) cells, \(self.pane.size.pixelWidth)x\(self.pane.size.pixelHeight) px")
        dock.paneResized(pixelWidth: pane.size.pixelWidth, pixelHeight: pane.size.pixelHeight)
        caption()
    }

    private func quit() {
        guard !quitting else { return }
        quitting = true
        sim?.stop()
        rex?.stop()
        guard let recorder = stage.recorder else {
            pane.restore()
            exit(0)
        }
        show("saving the movie…")
        Task {
            do {
                try await recorder.finish(scene: stage.scene, time: CACurrentMediaTime())
                pane.restore()
                print(recorder.url.path)
                exit(0)
            } catch {
                pane.restore()
                FileHandle.standardError.write(Data("duorex: \(error)\n".utf8))
                exit(1)
            }
        }
    }
}
