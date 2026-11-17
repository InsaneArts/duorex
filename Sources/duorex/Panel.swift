/// One of the device's two screens. The simulator lights one at a time.
nonisolated enum Panel: String, CaseIterable {
    /// The outer screen, in use while the device is closed.
    case cover
    /// The screen that bends across the hinge.
    case inner

    /// The simulator streams whichever panel is lit. The cover has fewer pixels than the inner screen.
    init(framebufferWidth width: Int, height: Int) {
        self = width * height < 4_000_000 ? .cover : .inner
    }

    var other: Panel { self == .cover ? .inner : .cover }
}
