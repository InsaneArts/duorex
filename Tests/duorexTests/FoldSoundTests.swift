import Testing
@testable import duorex

@Test func `each sound is short, starts at once and ends in silence`() {
    for sound in [DeviceMotion.Sound.shut, .flat] {
        let samples = FoldSound.samples(for: sound, rate: 44_100)
        #expect(samples.count > 2_000 && samples.count < 44_100 / 4)
        let peak = samples.map(abs).max() ?? 0
        #expect(peak > 0.5 && peak <= 1)
        // Most of the sound is in its first 40 milliseconds.
        let early = samples.prefix(1_764).reduce(0) { $0 + $1 * $1 }, whole = samples.reduce(0) { $0 + $1 * $1 }
        #expect(early / whole > 0.6)
        #expect(abs(samples.first ?? 1) < 0.05)
        #expect(samples.suffix(50).allSatisfy { abs($0) < 0.02 })
    }
}

@Test func `the shut is deeper than the click of the open device`() {
    // A deeper sound crosses zero less often.
    func crossings(_ samples: [Float]) -> Int {
        zip(samples, samples.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
    }
    let shut = FoldSound.samples(for: .shut, rate: 44_100), flat = FoldSound.samples(for: .flat, rate: 44_100)
    #expect(Double(crossings(shut)) / Double(shut.count) < Double(crossings(flat)) / Double(flat.count))
}

@Test func `a sound is the same each time it is made`() {
    #expect(FoldSound.samples(for: .shut, rate: 44_100) == FoldSound.samples(for: .shut, rate: 44_100))
}
