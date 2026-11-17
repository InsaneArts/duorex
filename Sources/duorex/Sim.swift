import CoreMedia
import Foundation
import QuartzCore
import VideoToolbox

/// One simulator served by serve-sim: its live screen, its input, and what its other clients do.
/// The bytes on the connections are `SimWire`'s; this type owns the connections and the decoder.
final class Sim: NSObject, URLSessionDataDelegate {
    /// A decoded picture of the lit panel.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// The simulator's pose changed, or it reported it for the first time.
    var onReport: ((SimWire.Report) -> Void)?
    /// Another client of the server did something to the simulator. Most of the time it is an agent.
    var onActivity: ((SimWire.Activity) -> Void)?

    /// The simulator's identifier.
    var device: String { base.lastPathComponent }

    private let base: URL
    private var session: URLSession!
    private var streamTask: URLSessionDataTask?
    private var socket: URLSessionWebSocketTask?
    private var stream = SimWire.Stream()
    private var eventsTask: URLSessionDataTask?
    private var events = SimWire.Events()
    private var sent = SimWire.Sent()
    private var format: CMVideoFormatDescription?
    private var decoder: VTDecompressionSession?
    private var stopped = false
    private var pendingHinge: Double?
    private var hingeTimer: Timer?

    /// `base` is the device's address on the server, such as http://127.0.0.1:3100/helper/<udid>.
    init(base: URL) {
        self.base = base
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        // Everything arrives on the main queue: the work per picture is a copy and a decode call.
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }

    func start() {
        openStream()
        openSocket()
        openEvents()
    }

    func stop() {
        stopped = true
        streamTask?.cancel()
        eventsTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
    }

    // MARK: Input

    /// `sent` runs when the message is out, or at once when there is no connection to send it on.
    func send(_ message: SimWire.Message, sent done: (@MainActor @Sendable () -> Void)? = nil) {
        sent.note(message, time: CACurrentMediaTime())
        guard let socket else {
            if let done { Task { @MainActor in done() } }
            return
        }
        socket.send(.data(message.data)) { error in
            if let error { log.error("input: \(error.localizedDescription, privacy: .public)") }
            if let done { Task { @MainActor in done() } }
        }
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

    // MARK: Connections

    private func openSocket() {
        guard !stopped, var components = URLComponents(url: base.appendingPathComponent("ws"), resolvingAgainstBaseURL: false) else { return }
        components.scheme = "ws"
        let socket = session.webSocketTask(with: components.url!)
        self.socket = socket
        socket.resume()
        receive(on: socket)
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.socket === socket else { return }
                switch result {
                case .success(.data(let message)):
                    if let report = SimWire.report(from: message) { self.onReport?(report) }
                    self.receive(on: socket)
                case .success:
                    self.receive(on: socket)
                case .failure:
                    self.retry { $0.openSocket() }
                }
            }
        }
    }

    private func openStream() {
        guard !stopped else { return }
        stream = SimWire.Stream()
        var request = URLRequest(url: base.appendingPathComponent("stream.avcc"))
        request.timeoutInterval = 3600 * 24
        streamTask = session.dataTask(with: request)
        streamTask?.resume()
    }

    /// The event log is the server's, not the device's: it is at the server's root, and names the device.
    private func openEvents() {
        guard !stopped, var components = URLComponents(url: base.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("api/event-log/events"), resolvingAgainstBaseURL: false) else { return }
        // The stream starts with the events of the past. One is the fewest the server sends.
        components.queryItems = [URLQueryItem(name: "device", value: base.lastPathComponent), URLQueryItem(name: "limit", value: "1")]
        events = SimWire.Events()
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 3600 * 24
        eventsTask = session.dataTask(with: request)
        eventsTask?.resume()
    }

    /// Opens a dropped connection again after a pause, as when the simulator restarts.
    private func retry(_ open: @escaping @MainActor (Sim) -> Void) {
        guard !stopped else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            if let self { open(self) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated {
            if dataTask === eventsTask {
                let now = CACurrentMediaTime()
                for activity in events.read(data) where !sent.claims(activity, time: now) { onActivity?(activity) }
                return
            }
            guard dataTask === streamTask else { return }
            for record in stream.read(data) {
                switch record {
                case .format(let sps, let pps): makeDecoder(sps: sps, pps: pps)
                case .picture(let sample): decode(sample)
                }
            }
            // The completion handler opens a fresh stream.
            if stream.isOutOfStep { dataTask.cancel() }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        MainActor.assumeIsolated {
            if task === eventsTask {
                // A server without an event log never gets one. Any other end is a dropped connection.
                if (task.response as? HTTPURLResponse)?.statusCode != 404 { retry { $0.openEvents() } }
            } else if task === streamTask {
                retry { $0.openStream() }
            }
        }
    }

    // MARK: Decoding

    private func makeDecoder(sps: Data, pps: Data) {
        var format: CMVideoFormatDescription?
        sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let sets = [spsBytes.bindMemory(to: UInt8.self).baseAddress!, ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: sets,
                                                                        parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4,
                                                                        formatDescriptionOut: &format)
            }
        }
        guard let format else { return }
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        decoder = nil
        self.format = format
        let output: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferMetalCompatibilityKey: true]
        VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                     imageBufferAttributes: output as CFDictionary, outputCallback: nil, decompressionSessionOut: &decoder)
    }

    private func decode(_ sample: Data) {
        guard let decoder, let format, !sample.isEmpty else { return }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: sample.count, blockAllocator: nil, customBlockSource: nil,
                                           offsetToData: 0, dataLength: sample.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block else { return }
        sample.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: sample.count) }
        var buffer: CMSampleBuffer?
        var size = sample.count
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
                                  sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer)
        guard let buffer else { return }
        VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: buffer, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { [weak self] _, _, image, _, _ in
            guard let image else { return }
            nonisolated(unsafe) let frame = image
            DispatchQueue.main.async { self?.onFrame?(frame) }
        }
    }
}
