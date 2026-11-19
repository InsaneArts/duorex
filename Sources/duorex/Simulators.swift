import Foundation

/// Finds, makes and starts the simulator that duorex shows.
enum Simulators {
    static let defaultDevice = "duorex Duo"
    private static let duoType = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"

    /// The UDID of a booted simulator. `device` is a name or a UDID. With no device, duorex
    /// uses its own, and makes it the first time.
    static func booted(_ device: String?) async throws -> String {
        let udid = try await udid(for: device ?? defaultDevice, create: device == nil)
        // bootstatus with -b starts a simulator that is shut down, and returns once it is booted.
        let boot = try await Shell.result("/usr/bin/xcrun", ["simctl", "bootstatus", udid, "-b"])
        guard boot.status == 0 else { throw DuoError.sim("the simulator did not start: \(boot.errors.suffix(300))") }
        return udid
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
}
