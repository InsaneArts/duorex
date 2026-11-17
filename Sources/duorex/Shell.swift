import Foundation
import Synchronization

/// Runs a command-line tool and returns what it printed.
nonisolated enum Shell {
    /// The tool could not start, or it exited with an error.
    struct Failure: Error, CustomStringConvertible {
        var tool: String
        /// What the tool wrote to standard error, or why it could not start.
        var reason: String

        var description: String { "\(tool) failed: \(reason.suffix(300))" }
    }

    /// The tool's standard output, without the trailing newline. Standard error goes only into the failure.
    static func run(_ tool: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try runAndWait(tool, arguments) })
            }
        }
    }

    private static func runAndWait(_ tool: String, _ arguments: [String]) throws -> String {
        let launcher = URL(fileURLWithPath: tool).lastPathComponent
        // `env` and `xcrun` only find the real tool, which is their first argument.
        let name = ["env", "xcrun"].contains(launcher) ? arguments.first ?? launcher : launcher
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw Failure(tool: name, reason: error.localizedDescription) }

        // Both pipes are read to the end before the wait. A child that fills a pipe nobody
        // reads blocks on its next write and never exits.
        let errorText = Mutex(Data())
        let reading = DispatchGroup()
        DispatchQueue.global().async(group: reading) {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            errorText.withLock { $0 = data }
        }
        let text = output.fileHandleForReading.readDataToEndOfFile()
        reading.wait()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let reason = String(decoding: errorText.withLock { $0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(tool: name, reason: reason.isEmpty ? "exit status \(process.terminationStatus)" : reason)
        }
        return String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
