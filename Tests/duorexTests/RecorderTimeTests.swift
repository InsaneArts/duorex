import CoreMedia
import Testing
@testable import duorex

@Test func `each picture of a film is one sixtieth of a second after the one before`() {
    let times = (0...600).map { Recorder.time(Double($0) / 60) }
    for (before, after) in zip(times, times.dropFirst()) {
        #expect(CMTimeSubtract(after, before) == CMTime(value: 1, timescale: 60))
    }
    #expect(times.last == CMTime(value: 10, timescale: 1))
}
