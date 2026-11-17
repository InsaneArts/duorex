import AppKit

/// One run of duorex in a terminal pane: the pane's input, the device drawn over it, and the simulator behind it.
final class Session {
    private let pane: Pane
    private let stage: StageView
    private let dock: Dock
    private let rex: RexHost?
    private var signals: [DispatchSourceSignal] = []

    /// Hinge angles for the three poses the number keys choose.
    private static let poses: [Character: Double] = ["1": 0, "2": 130, "3": 180]

    init(scene: DuoScene) throws {
        pane = try Pane()
        stage = StageView(scene: scene)
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
            default: break
            }
        case .resized:
            paneResized()
        case .focus:
            break
        }
    }

    private func paneResized() {
        log.notice("pane \(self.pane.size.columns)x\(self.pane.size.rows) cells, \(self.pane.size.pixelWidth)x\(self.pane.size.pixelHeight) px")
        dock.paneResized(pixelWidth: pane.size.pixelWidth, pixelHeight: pane.size.pixelHeight)
        pane.caption("drag the frame to fold  ·  1 2 3 poses  ·  q quit")
    }

    private func quit() -> Never {
        rex?.stop()
        pane.restore()
        exit(0)
    }
}
