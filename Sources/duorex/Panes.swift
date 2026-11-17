import Foundation

/// The duorex panes that are open, so a command that wants to show the device does not open a
/// second one. Each pane leaves a small file while it runs.
nonisolated enum Panes {
    /// One file for each pane, named by its process and holding the Rex session it is in.
    static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appendingPathComponent("duorex/panes")

    /// Notes that this process is a pane in a Rex session.
    static func opened(in session: String, process: Int32 = getpid(), folder: URL = folder) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(session.utf8).write(to: folder.appendingPathComponent("\(process)"))
    }

    static func closed(process: Int32 = getpid(), folder: URL = folder) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(process)"))
    }

    /// Whether a pane is open in a Rex session. A pane that ended without a word is forgotten here.
    static func isOpen(in session: String, folder: URL = folder, isRunning: (Int32) -> Bool = { kill($0, 0) == 0 }) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { name in
            guard let process = Int32(name), isRunning(process) else {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
                return false
            }
            return (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) == session
        }
    }
}
