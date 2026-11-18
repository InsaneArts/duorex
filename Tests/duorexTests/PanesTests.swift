import Foundation
import Testing
@testable import duorex

/// A folder of its own for each test.
private func folder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("duorex-panes-\(UUID().uuidString)")
}

@Test func `a pane that is open is found in its own session only`() {
    let folder = folder()
    #expect(!Panes.isOpen(in: "work", folder: folder))
    Panes.opened(in: "work", process: 4242, folder: folder)
    #expect(Panes.isOpen(in: "work", folder: folder) { $0 == 4242 })
    #expect(!Panes.isOpen(in: "play", folder: folder) { $0 == 4242 })
}

@Test func `a pane that closed is not found`() {
    let folder = folder()
    Panes.opened(in: "work", process: 4242, folder: folder)
    Panes.closed(process: 4242, folder: folder)
    #expect(!Panes.isOpen(in: "work", folder: folder) { _ in true })
}

@Test func `a pane whose process is gone is forgotten`() {
    let folder = folder()
    Panes.opened(in: "work", process: 4242, folder: folder)
    #expect(!Panes.isOpen(in: "work", folder: folder) { _ in false })
    // Its file is gone too, so a new process with the same number is not taken for it.
    #expect(!Panes.isOpen(in: "work", folder: folder) { _ in true })
}

@Test func `a file whose process is alive but is not duorex is not a pane`() {
    let folder = folder()
    // The pane died without a word, and another program got its process number: this test's own, here.
    Panes.opened(in: "work", process: getpid(), folder: folder)
    #expect(!Panes.isOpen(in: "work", folder: folder))
}
