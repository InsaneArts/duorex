import AVFoundation

/// Plays the sound of the device as it shuts and as it opens flat. The sounds are made here
/// from a few waves, so duorex ships no sound files.
final class FoldSound {
    /// The user's choice, kept from one run to the next.
    var isMuted: Bool {
        didSet { UserDefaults.standard.set(isMuted, forKey: "muted") }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
    private var buffers: [DeviceMotion.Sound: AVAudioPCMBuffer] = [:]
    private var isConnected = false
    private var idle: Timer?

    init() {
        isMuted = UserDefaults.standard.bool(forKey: "muted")
        guard let format else { return }
        for sound in [DeviceMotion.Sound.shut, .flat] {
            let samples = Self.samples(for: sound, rate: format.sampleRate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else { continue }
            buffer.frameLength = buffer.frameCapacity
            for (index, sample) in samples.enumerated() { channel[index] = sample }
            buffers[sound] = buffer
        }
    }

    /// Plays a sound. `strength` is how hard the device arrived, from 0 to 1.
    /// Returns false when it could not play: muted, or a Mac with no sound output.
    @discardableResult
    func play(_ sound: DeviceMotion.Sound, strength: Double) -> Bool {
        guard !isMuted, let buffer = buffers[sound], start() else { return false }
        player.volume = Float(0.2 + 0.4 * strength)
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
        // An engine that runs keeps the sound output open and the Mac awake. A second after
        // the last sound it has nothing left to play.
        idle?.invalidate()
        idle = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.pause() }
        }
        return true
    }

    /// Starts the engine at the first sound, so a run that makes no sound opens no sound output.
    private func start() -> Bool {
        if engine.isRunning { return true }
        // With no sound output there is no format to play in, and the engine stops the program if it is asked to connect.
        guard let format, engine.outputNode.outputFormat(forBus: 0).channelCount > 0 else { return false }
        if !isConnected {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            isConnected = true
        }
        return (try? engine.start()) != nil
    }

    /// The samples of a sound, from -1 to 1, at `rate` samples a second.
    nonisolated static func samples(for sound: DeviceMotion.Sound, rate: Double) -> [Float] {
        // One contact of two hard parts: a low thump that falls in pitch, and a short knock of noise.
        func contact(pitch: (from: Double, to: Double), thump: Double, knock: Double, lasts: Double) -> [Double] {
            var noise: UInt32 = 0x2545_F491, low = 0.0, phase = 0.0
            return (0..<Int(lasts * rate)).map { index in
                let time = Double(index) / rate
                let frequency = pitch.to + (pitch.from - pitch.to) * exp(-time / 0.02)
                phase += 2 * .pi * frequency / rate
                // The same noise each time, so the sound is the same each time.
                noise = noise &* 1_664_525 &+ 1_013_904_223
                let white = Double(noise >> 8) / Double(1 << 23) - 1
                // Without its deepest part the noise is a knock, not a hiss or a rumble.
                low += (white - low) * 0.25
                let attack = min(time / 0.001, 1)
                return attack * (thump * sin(phase) * exp(-time / (lasts / 5)) + knock * (white - low) * exp(-time / 0.005))
            }
        }
        var wave: [Double]
        switch sound {
        case .shut:
            // The two halves meet, and settle a moment later.
            wave = contact(pitch: (190, 85), thump: 0.9, knock: 0.45, lasts: 0.16)
            for (index, sample) in contact(pitch: (150, 80), thump: 0.3, knock: 0.15, lasts: 0.1).enumerated() {
                let late = index + Int(0.03 * rate)
                if late < wave.count { wave[late] += sample }
            }
        case .flat:
            // The hinge stops: lighter, and higher.
            wave = contact(pitch: (420, 260), thump: 0.5, knock: 0.35, lasts: 0.09)
        }
        // Fade the end to nothing, and use the same headroom for both sounds.
        let fade = Int(0.01 * rate)
        for index in 0..<fade { wave[wave.count - 1 - index] *= Double(index) / Double(fade) }
        let peak = wave.map(abs).max() ?? 1
        return wave.map { Float($0 / peak * 0.9) }
    }
}
