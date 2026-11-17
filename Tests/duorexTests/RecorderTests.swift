import Foundation
import Testing
@testable import duorex

private func scratchFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("duorex-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@MainActor @Test func `a movie replaces an older movie of the same name`() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let movie = folder.appendingPathComponent("clip.mp4")
    try Data("old".utf8).write(to: movie)
    try Recorder.makeRoom(at: movie)
    #expect(!FileManager.default.fileExists(atPath: movie.path))
}

@MainActor @Test func `a movie never replaces a folder`() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let kept = folder.appendingPathComponent("kept.txt")
    try Data("keep me".utf8).write(to: kept)
    #expect(throws: DuoError.self) { try Recorder.makeRoom(at: folder) }
    #expect(FileManager.default.fileExists(atPath: kept.path))
}

@MainActor @Test func `a movie with no name yet is nothing to remove`() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try Recorder.makeRoom(at: folder.appendingPathComponent("new.mp4"))
    #expect(FileManager.default.fileExists(atPath: folder.path))
}
