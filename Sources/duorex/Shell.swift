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
    static func run(_ tool: String, _ arguments: [String], in directory: URL? = nil) async throws -> String {
        let result = try await result(tool, arguments, in: directory)
        guard result.status == 0 else {
            throw Failure(tool: name(of: tool, arguments), reason: result.errors.isEmpty ? "exit status \(result.status)" : result.errors)
        }
        return result.output
    }

    /// What a tool printed and how it ended, for a tool whose output matters when it fails
    /// too. It throws only when the tool could not start.
    static func result(_ tool: String, _ arguments: [String], in directory: URL? = nil) async throws -> (status: Int32, output: String, errors: String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try runAndWait(tool, arguments, in: directory) })
            }
        }
    }

    /// `env` and `xcrun` only find the real tool, which is their first argument.
    private static func name(of tool: String, _ arguments: [String]) -> String {
        let launcher = URL(fileURLWithPath: tool).lastPathComponent
        return ["env", "xcrun"].contains(launcher) ? arguments.first ?? launcher : launcher
    }

    private static func runAndWait(_ tool: String, _ arguments: [String], in directory: URL?) throws -> (status: Int32, output: String, errors: String) {
        let name = name(of: tool, arguments)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
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
        func trimmed(_ data: Data) -> String { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        return (process.terminationStatus, trimmed(text), trimmed(errorText.withLock { $0 }))
    }
}
