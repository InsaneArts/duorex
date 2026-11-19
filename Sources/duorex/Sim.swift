import CoreVideo
import Foundation
import IOSurface
import QuartzCore
import SimHostKit

/// One simulator, through simhost: its live screen, its input, and what its other clients do.
///
/// The pictures come straight from the simulator's framebuffers, with no copy and no video.
/// Input goes to the simulator's host, one process that every client of the simulator shares.
/// The host passes on what the other clients do, and tells the device's state.
final class Sim {
    /// A picture of the lit panel. It is the simulator's live framebuffer: copy it at once.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// The simulator's pose changed, or it reported it for the first time.
    var onReport: ((SimWire.Report) -> Void)?
    /// Another client of the simulator did something to it. Most of the time it is an agent.
    var onActivity: ((SimWire.Activity) -> Void)?

    /// The simulator's identifier.
    let device: String

    private var screens: Screens?
    private var host: HostClient?
    private let mailbox = Mailbox()
    private var isDuo = false
    private var state: Wire.State?
    /// The newest picture of each panel, and how its interface is turned.
    private var latest: [SimHostKit.Panel: SimHostKit.Frame] = [:]
    /// A wrapper for each framebuffer, made once. A framebuffer is replaced only when the simulator restarts.
    private var buffers: [IOSurfaceID: CVPixelBuffer] = [:]
    private var activities = SimWire.Activities()
    private var stopped = false
    private var pendingHinge: Double?
    private var hingeTimer: Timer?

    init(udid: String) {
        device = udid
    }

    /// Connects to the simulator, and again whenever the connection ends.
    func start() {
        guard !stopped else { return }
        let device = device
        let launch = [Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0], "host", device]
        let mailbox = mailbox
        // Loading Xcode's frameworks, and starting a host that is not running, take a moment.
        Task.detached { [weak self] in
            do {
                let simulator = try Simulator(udid: device)
                // Before anything arrives: what arrives is read by whether this is a Duo.
                await MainActor.run { self?.isDuo = simulator.isDuo }
                let host = try HostClient(udid: device, name: "duorex", launch: launch, onMessage: { message in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(message) } }
                }, onClose: {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.lost() } }
                })
                let screens = try Screens(simulator: simulator) { frame in
                    if mailbox.put(frame) { DispatchQueue.main.async { MainActor.assumeIsolated { self?.drain() } } }
                }
                await MainActor.run {
                    guard let self, !self.stopped else { host.close(); screens.stop(); return }
                    self.host = host
                    self.screens = screens
                }
            } catch {
                log.error("simulator: \(String(describing: error), privacy: .public)")
                try? await Task.sleep(for: .seconds(1))
                await self?.start()
            }
        }
    }

    func stop() {
        stopped = true
        host?.close()
        screens?.stop()
        hingeTimer?.invalidate()
    }

    /// The host went away, as when the simulator restarts. A new connection starts a new host.
    private func lost() {
        host?.close()
        screens?.stop()
        host = nil
        screens = nil
        latest = [:]
        buffers = [:]
        guard !stopped else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
    }

    // MARK: Input

    /// `sent` runs when the message is out, or at once when there is no connection to send it on.
    func send(_ message: SimWire.Message, sent done: (@MainActor @Sendable () -> Void)? = nil) {
        host?.send(input(for: message))
        if let done { Task { @MainActor in done() } }
    }

    /// Moves the simulator's hinge. Angles are spaced 50 ms apart, so a fold sends a smooth sweep, not a flood.
    func fold(to degrees: Double) {
        pendingHinge = degrees
        guard hingeTimer == nil else { return }
        sendPendingHinge()
        hingeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.pendingHinge == nil {
                    self.hingeTimer?.invalidate()
                    self.hingeTimer = nil
                } else {
                    self.sendPendingHinge()
                }
            }
        }
    }

    private func sendPendingHinge() {
        guard let degrees = pendingHinge else { return }
        pendingHinge = nil
        send(.fold(degrees: degrees))
    }

    private func input(for message: SimWire.Message) -> Wire.Input {
        switch message {
        case .touch(let phase, let x, let y, let edge):
            .touch(Self.phase(phase), x: Float(x), y: Float(y), screen: litScreen, edge: UInt8(edge ?? 0))
        case .pinch(let phase, let first, let second):
            .pinch(Self.phase(phase), x1: Float(first.x), y1: Float(first.y), x2: Float(second.x), y2: Float(second.y), screen: litScreen)
        case .fold(let degrees):
            .fold(degrees: degrees, milliseconds: 0)
        case .rotate(let orientation):
            .orientation(SimHostKit.Orientation(orientation))
        case .button(let button, let pressed):
            .button(page: UInt32(button.usage.page), usage: UInt32(button.usage.usage), down: pressed)
        case .type(let text):
            .type(text)
        case .slowAnimations(let slow):
            .slowAnimations(slow)
        case .memoryWarning:
            .memoryWarning
        }
    }

    private static func phase(_ phase: DeviceMotion.TouchPhase) -> Wire.Phase {
        switch phase {
        case .begin: .down
        case .move: .move
        case .end: .up
        }
    }

    // MARK: What the simulator tells

    /// The panel that shows the interface. Until SpringBoard tells it, the hinge decides, as it
    /// does on the device most of the time.
    private var litScreen: Wire.Screen {
        guard isDuo else { return .main }
        if let lit = state?.lit { return lit }
        return (state?.hinge ?? 0) < 90 ? .duoCover : .duoInner
    }

    private var litPanel: SimHostKit.Panel {
        switch litScreen {
        case .duoCover: .duoCover
        case .duoInner: .duoInner
        case .main: latest.keys.first ?? .duoCover
        }
    }

    private func received(_ message: Wire.Message) {
        switch message {
        case .state(let new):
            let lit = litPanel
            state = new
            report()
            // A panel that lights up may have no new picture for a while. Show the one it has.
            if litPanel != lit, let frame = latest[litPanel] { show(frame) }
        case .event(let client, _, _, let input):
            if let activity = activities.read(input, from: client) { onActivity?(activity) }
        default:
            break
        }
    }

    private func drain() {
        for frame in mailbox.take() {
            let turned = latest[frame.panel]?.orientation != frame.orientation
            latest[frame.panel] = frame
            guard frame.panel == litPanel else { continue }
            if turned { report() }
            show(frame)
        }
    }

    private func show(_ frame: SimHostKit.Frame) {
        let id = IOSurfaceGetID(frame.surface)
        if buffers[id] == nil {
            var buffer: Unmanaged<CVPixelBuffer>?
            CVPixelBufferCreateWithIOSurface(nil, frame.surface, nil, &buffer)
            buffers[id] = buffer?.takeRetainedValue()
        }
        if let buffer = buffers[id] { onFrame?(buffer) }
    }

    private func report() {
        guard let state else { return }
        let interface = latest[litPanel].map { Orientation($0.orientation) } ?? .portrait
        onReport?(SimWire.Report(width: litPanel.width, orientation: interface.rawValue, hingeDegrees: state.hinge,
                                 duoViewOrientation: isDuo ? Orientation(state.held).rawValue : nil))
    }
}

/// The newest picture of each panel, from the screens' queue to the main thread. While the main
/// thread is busy, newer pictures replace older ones, so it never falls behind the simulator.
private nonisolated final class Mailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [SimHostKit.Panel: SimHostKit.Frame] = [:]

    /// Returns true when the main thread must be told: the box was empty.
    func put(_ frame: SimHostKit.Frame) -> Bool {
        lock.withLock {
            defer { frames[frame.panel] = frame }
            return frames.isEmpty
        }
    }

    func take() -> [SimHostKit.Frame] {
        lock.withLock {
            defer { frames = [:] }
            return Array(frames.values)
        }
    }
}

nonisolated extension Orientation {
    init(_ orientation: SimHostKit.Orientation) {
        switch orientation {
        case .portrait: self = .portrait
        case .upsideDown: self = .upsideDown
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        }
    }
}

nonisolated extension SimHostKit.Orientation {
    init(_ orientation: Orientation) {
        switch orientation {
        case .portrait: self = .portrait
        case .upsideDown: self = .upsideDown
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        }
    }
}
