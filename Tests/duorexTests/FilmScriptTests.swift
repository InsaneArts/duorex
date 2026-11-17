import Testing
@testable import duorex

private let frames = (0...Int(FilmScript.seconds) * FilmScript.framesPerSecond).map { FilmScript.shot(at: Double($0) / Double(FilmScript.framesPerSecond)) }

@Test func `the film begins with the device shut and ends with it half open`() {
    #expect(frames.first?.pose.hinge == 0)
    #expect(frames.last?.pose.hinge == FilmScript.book)
    #expect(frames.contains { $0.pose.hinge == 180 })
    #expect(frames.allSatisfy { (0...180).contains($0.pose.hinge) })
}

@Test func `nothing in the film jumps from one picture to the next`() {
    for (before, after) in zip(frames, frames.dropFirst()) {
        #expect(abs(after.pose.hinge - before.pose.hinge) < 3)
        #expect(abs(after.pose.yaw - before.pose.yaw) < 0.5)
        #expect(abs(after.pose.pitch - before.pose.pitch) < 0.25)
        #expect(abs(after.zoom - before.zoom) < 0.005)
        #expect(abs(after.innerBrightness - before.innerBrightness) < 0.08)
    }
}

@Test func `the camera keeps moving while the device is still`() {
    // Between the keys the device rests, at shut and at open. The camera does not.
    let shut = FilmScript.shot(at: 0.8), open = FilmScript.shot(at: 5.4)
    #expect(shut.pose.yaw != FilmScript.shot(at: 0.9).pose.yaw)
    #expect(open.zoom != FilmScript.shot(at: 5.5).zoom)
    #expect(shut.pose.hinge == 0 && open.pose.hinge == 180)
}

@Test func `the cover is lit on the shut device and the inner screen on the open one`() {
    #expect(frames.first?.coverBrightness == 1 && frames.first?.innerBrightness == 0)
    let open = FilmScript.shot(at: 5)
    #expect(open.coverBrightness == 0 && open.innerBrightness == 1)
    #expect(frames.last?.innerBrightness == 1)
}

@Test func `the app lays out for the half-open device only at the end`() {
    #expect(!FilmScript.shot(at: 5).showsBook)
    #expect(!FilmScript.shot(at: 3).showsBook)
    #expect(FilmScript.shot(at: 9.5).showsBook)
}
