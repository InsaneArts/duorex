import Testing
@testable import duorex

@Test func `the first word is the subcommand, and no word means the view`() {
    #expect(Arguments(["duorex", "sweep"]).command == "sweep")
    #expect(Arguments(["duorex"]).command == "view")
    #expect(Arguments(["duorex", "--finish", "Light"]).command == "view")
}

@Test func `a name takes the word after it as its value`() {
    let arguments = Arguments(["duorex", "record", "--out", "demo.mp4", "--size", "1080x1080"])
    #expect(arguments.string("out") == "demo.mp4")
    #expect(arguments.string("size") == "1080x1080")
    #expect(arguments.string("device") == nil)
    #expect(arguments.double("hinge", default: 180) == 180)
}

@Test func `plain words stay in order, with names and flags between them`() {
    let arguments = Arguments(["duorex", "swipe", "0.5", "0.9", "--seconds", "0.4", "0.5", "0.2"])
    #expect(arguments.words == ["0.5", "0.9", "0.5", "0.2"])
    #expect(arguments.numbers(4) == [0.5, 0.9, 0.5, 0.2])
    #expect(arguments.numbers(2) == nil)
    #expect(arguments.double("seconds", default: 0) == 0.4)
}

@Test func `a flag takes no value, so the word after it is a plain word`() {
    let arguments = Arguments(["duorex", "screenshot", "--grid", "shot.png"])
    #expect(arguments.flag("grid"))
    #expect(arguments.words == ["shot.png"])
    #expect(!arguments.flag("full"))
}

@Test func `a name with its value forgotten is set but has no value`() {
    let arguments = Arguments(["duorex", "record", "--out"])
    #expect(arguments.flag("out"))
    #expect(arguments.string("out") == nil)
}

@Test func `words that are not numbers are not numbers`() {
    #expect(Arguments(["duorex", "tap", "left", "0.4"]).numbers(2) == nil)
    #expect(Arguments(["duorex", "fold", "book"]).words == ["book"])
}
