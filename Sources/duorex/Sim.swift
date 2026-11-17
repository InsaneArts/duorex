import CoreMedia
import Foundation
import VideoToolbox

/// One simulator served by serve-sim: its live screen and its input.
/// The wire format is serve-sim's own (0.1.x): a tagged H.264 stream over HTTP and tagged JSON over a WebSocket.
final class Sim: NSObject, URLSessionDataDelegate {
    /// What the simulator reports about its screen and pose.
    struct Config: Decodable {
        var width: Int
        var height: Int
        var orientation: String
        var hingeDegrees: Double?
        var duoViewOrientation: String?
    }

    var onFrame: ((CVPixelBuffer) -> Void)?
    var onConfig: ((Config) -> Void)?

    private let base: URL
    private var session: URLSession!
    private var stream: URLSessionDataTask?
    private var socket: URLSessionWebSocketTask?
    private var buffer = Data()
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
        // Everything arrives on the main queue: the work per frame is a copy and a decode call.
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }

    func start() {
        openStream()
        openSocket()
    }

    func stop() {
        stopped = true
        stream?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
    }

    // MARK: Input

    /// A one-finger touch. `x` and `y` are 0...1 in the active panel's framebuffer.
    /// `edge` marks a system edge swipe, such as the swipe home.
    func touch(_ phase: String, x: Double, y: Double, edge: Int?) {
        var message: [String: Any] = ["type": phase, "x": x, "y": y]
        if let edge { message["edge"] = edge }
        send(0x03, message)
    }

    /// Moves the simulator's hinge. Updates are spaced out so a fold sends a smooth sweep, not a flood.
    func fold(to degrees: Double) {
        pendingHinge = degrees
        guard hingeTimer == nil else { return }
        flushHinge()
        hingeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.pendingHinge == nil {
                    self.hingeTimer?.invalidate()
                    self.hingeTimer = nil
                } else {
                    self.flushHinge()
                }
            }
        }
    }

    private func flushHinge() {
        guard let degrees = pendingHinge else { return }
        pendingHinge = nil
        send(0x0E, ["hinge": (degrees * 10).rounded() / 10])
    }

    func rotate(to orientation: String) { send(0x07, ["orientation": orientation]) }

    /// Presses a named button: "swipe_home", "app_switcher", "lock".
    func press(_ button: String) { send(0x04, ["button": button]) }

    private func send(_ tag: UInt8, _ message: [String: Any]) {
        guard let socket, let json = try? JSONSerialization.data(withJSONObject: message) else { return }
        socket.send(.data(Data([tag]) + json)) { error in
            if let error { log.error("input: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: Socket

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
                case .success(.data(let data)):
                    // 0x82 carries the screen size, the orientation and the hinge angle.
                    if data.first == 0x82, let config = try? JSONDecoder().decode(Config.self, from: data.dropFirst()) { self.onConfig?(config) }
                    self.receive(on: socket)
                case .success:
                    self.receive(on: socket)
                case .failure:
                    self.reconnect(socket: true)
                }
            }
        }
    }

    /// Opens a dropped connection again after a pause, as when the simulator restarts.
    private func reconnect(socket: Bool) {
        guard !stopped else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            if socket { self?.openSocket() } else { self?.openStream() }
        }
    }

    // MARK: Stream

    private func openStream() {
        guard !stopped else { return }
        buffer.removeAll()
        var request = URLRequest(url: base.appendingPathComponent("stream.avcc"))
        request.timeoutInterval = 3600 * 24
        stream = session.dataTask(with: request)
        stream?.resume()
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated {
            guard dataTask === stream else { return }
            buffer.append(data)
            parse()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        MainActor.assumeIsolated {
            guard task === stream else { return }
            reconnect(socket: false)
        }
    }

    /// The stream is a run of `[length: UInt32 big endian][tag: UInt8][payload]`, where length counts the tag.
    private func parse() {
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= 5 {
            let length = buffer[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length >= 1, buffer.endIndex - offset >= 4 + length else { break }
            let payload = buffer[(offset + 5)..<(offset + 4 + length)]
            switch buffer[offset + 4] {
            case 0x01: configure(avcC: Data(payload))
            case 0x02, 0x03: decode(Data(payload))
            default: break   // 0x04 is a JPEG of the screen, sent before the first video frame
            }
            offset += 4 + length
        }
        buffer.removeSubrange(buffer.startIndex..<offset)
    }

    /// Builds a decoder from an avcC record: one SPS and one PPS, with 4-byte NAL lengths.
    private func configure(avcC: Data) {
        let bytes = [UInt8](avcC)
        guard bytes.count > 8 else { return }
        let spsLength = Int(bytes[6]) << 8 | Int(bytes[7])
        let ppsStart = 8 + spsLength + 3
        guard bytes.count >= ppsStart else { return }
        let ppsLength = Int(bytes[ppsStart - 2]) << 8 | Int(bytes[ppsStart - 1])
        guard bytes.count >= ppsStart + ppsLength else { return }
        let sps = Array(bytes[8..<8 + spsLength]), pps = Array(bytes[ppsStart..<ppsStart + ppsLength])

        var format: CMVideoFormatDescription?
        sps.withUnsafeBufferPointer { spsPointer in
            pps.withUnsafeBufferPointer { ppsPointer in
                let sets = [spsPointer.baseAddress!, ppsPointer.baseAddress!]
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
        guard let decoder, let format else { return }
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
