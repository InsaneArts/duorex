import Foundation

/// Finds or starts serve-sim for a simulator.
enum SimServer {
    /// The serve-sim release duorex was written against. Its wire format is not a public API.
    static let package = "serve-sim@0.1.49"
    static let defaultDevice = "duorex Duo"
    private static let duoType = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"

    /// The device's address on a running server, such as http://127.0.0.1:3100/helper/<udid>.
    /// `server` attaches to a server that is already running. Otherwise one is found or started.
    static func address(device: String?, server: String?) async throws -> URL {
        let udid = try await udid(for: device ?? defaultDevice, create: device == nil)
        if let server, let url = URL(string: server) { return url.appendingPathComponent("helper").appendingPathComponent(udid) }
        let running = try await runningPort(udid)
        let port = if let running { running } else { try await startServer(udid) }
        return URL(string: "http://127.0.0.1:\(port)/helper/\(udid)")!
    }

    private static func udid(for device: String, create: Bool) async throws -> String {
        if UUID(uuidString: device) != nil { return device }
        let list = try await Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "--json"])
        let devices = (try? JSONSerialization.jsonObject(with: Data(list.utf8)) as? [String: Any])?["devices"] as? [String: [[String: Any]]] ?? [:]
        if let found = devices.values.joined().first(where: { $0["name"] as? String == device }), let udid = found["udid"] as? String { return udid }
        guard create else { throw DuoError.sim("no simulator is named \"\(device)\"") }
        return try await Shell.run("/usr/bin/xcrun", ["simctl", "create", device, duoType, try await newestDuoRuntime()])
    }

    private static func newestDuoRuntime() async throws -> String {
        let list = try await Shell.run("/usr/bin/xcrun", ["simctl", "list", "runtimes", "available", "--json"])
        let runtimes = (try? JSONSerialization.jsonObject(with: Data(list.utf8)) as? [String: Any])?["runtimes"] as? [[String: Any]] ?? []
        let fitting = runtimes.filter { runtime in
            (runtime["supportedDeviceTypes"] as? [[String: Any]] ?? []).contains { $0["identifier"] as? String == duoType }
        }
        let newest = fitting.max { ($0["version"] as? String ?? "").compare($1["version"] as? String ?? "", options: .numeric) == .orderedAscending }
        guard let identifier = newest?["identifier"] as? String else {
            throw DuoError.sim("no installed iOS runtime supports iPhone Duo. Install iOS 27.1 or later in Xcode.")
        }
        return identifier
    }

    /// serve-sim records each server it runs in a state file.
    private static func runningPort(_ udid: String) async throws -> Int? {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("serve-sim/server-\(udid).json")
        guard let data = try? Data(contentsOf: state),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = json["pid"] as? Int, let port = json["port"] as? Int, kill(pid_t(pid), 0) == 0 else { return nil }
        return port
    }

    private static func startServer(_ udid: String) async throws -> Int {
        let arguments = ["--detach", udid, "--port", "3100"]
        // An installed serve-sim wins. Otherwise npx fetches the release duorex was written against.
        let output: String
        if let installed = try? await Shell.run("/usr/bin/env", ["serve-sim"] + arguments) {
            output = installed
        } else {
            let npx = try await Shell.result("/usr/bin/env", ["npx", "--yes", package] + arguments)
            // env exits with 127 when it finds no npx on the PATH.
            guard npx.status != 127 else { throw DuoError.sim("serve-sim needs Node.js, and npx is not on your PATH. Install Node.js, then run duorex again.") }
            guard npx.status == 0 else { throw DuoError.sim("serve-sim did not start: \(npx.errors.suffix(300))") }
            output = npx.output
        }
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let port = json["port"] as? Int else { throw DuoError.sim("serve-sim did not start: \(output.suffix(300))") }
        return port
    }
}
