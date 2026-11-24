import Foundation
import SimHostKit

/// A simulator that duorex can show.
nonisolated struct Device: Equatable {
    var udid: String
    var name: String
    /// The device type, such as com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro.
    var type: String

    /// iPhone Duo is drawn in 3D. Every other iPhone is drawn flat.
    var isDuo: Bool { type == Simulators.duoType }
}

/// Finds, makes and starts the simulator that duorex shows.
enum Simulators {
    nonisolated static let defaultDevice = "duorex Duo"
    nonisolated static let duoType = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"
    /// The iPhones that `duorex devices` offers, in its order. Any other iPhone works by its name or UDID.
    static let models = ["iPhone Duo", "iPhone 18 Pro", "iPhone 18 Pro Max", "iPhone 17 Pro", "iPhone 17 Pro Max",
                         "iPhone 17", "iPhone 17e", "iPhone Air"]

    /// What a name given with --device stands for.
    nonisolated enum Choice: Equatable {
        /// A simulator that exists.
        case existing(Device)
        /// A simulator to make, with this name and device type.
        case make(name: String, type: String)
    }

    /// The simulator a name stands for. `device` is a simulator's name or UDID, or an iPhone
    /// model, such as "iPhone 18 Pro". A model stands for duorex's own simulator of that model,
    /// named "duorex iPhone 18 Pro", which is made the first time. Nil when nothing matches.
    nonisolated static func choose(_ device: String, simulators: [Device], types: [(name: String, identifier: String)]) -> Choice? {
        if let found = simulators.first(where: { $0.udid.caseInsensitiveCompare(device) == .orderedSame || $0.name == device }) {
            return .existing(found)
        }
        // iPhone Duo is duorex's first device, and keeps its first name.
        let own = device == "iPhone Duo" ? defaultDevice : "duorex \(device)"
        if let found = simulators.first(where: { $0.name == own }) { return .existing(found) }
        if device == defaultDevice { return .make(name: defaultDevice, type: duoType) }
        guard let type = types.first(where: { $0.name == device && $0.identifier.contains(".iPhone") }) else { return nil }
        return .make(name: own, type: type.identifier)
    }

    /// The simulator `device` stands for, made when it does not exist yet. It is not started.
    static func find(_ device: String?) async throws -> Device {
        let name = device ?? defaultDevice
        let simulators = try await available()
        switch choose(name, simulators: simulators, types: try await deviceTypes()) {
        case .existing(let found):
            return found
        case .make(let name, let type):
            let udid = try await Shell.run("/usr/bin/xcrun", ["simctl", "create", name, type, try await newestRuntime(for: type)])
            return Device(udid: udid, name: name, type: type)
        case nil:
            throw DuoError.sim("no simulator or iPhone model is named \"\(name)\". `duorex devices` lists the iPhones.")
        }
    }

    /// Starts a simulator that is shut down, and returns once it is booted.
    static func boot(_ udid: String) async throws {
        // Asking CoreSimulator here is quicker than simctl, and loads the frameworks that the
        // screens need anyway.
        if (try? Simulator(udid: udid))?.isBooted == true { return }
        // bootstatus with -b starts a simulator that is shut down, and returns once it is booted.
        let boot = try await Shell.result("/usr/bin/xcrun", ["simctl", "bootstatus", udid, "-b"])
        guard boot.status == 0 else { throw DuoError.sim("the simulator did not start: \(boot.errors.suffix(300))") }
    }

    /// The UDID of a booted simulator. `device` is a name, a UDID or an iPhone model. With no
    /// device, duorex uses its own iPhone Duo, and makes it the first time.
    static func booted(_ device: String?) async throws -> String {
        let found = try await find(device)
        try await boot(found.udid)
        return found.udid
    }

    /// The lines of `duorex devices`: each model, with duorex's simulator of it if there is one.
    static func listing() async throws -> String {
        let simulators = try await available()
        let types = try await deviceTypes()
        let states = try await bootedUDIDs()
        let rows: [(String, String)] = models.compactMap { model in
            switch choose(model, simulators: simulators, types: types) {
            case .existing(let device): (model, "\(device.name), \(states.contains(device.udid) ? "booted" : "shut down")")
            case .make: (model, "made on first use")
            case nil: nil   // this Xcode does not have the model
            }
        }
        let width = rows.map(\.0.count).max() ?? 0
        return rows.map { $0.0.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.1 }.joined(separator: "\n")
            + "\n\nduorex --device \"iPhone 18 Pro\" shows that model. A simulator's own name or UDID works too."
    }

    // MARK: simctl

    private static func available() async throws -> [Device] {
        let list = try await Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "--json"])
        let runtimes = (try? JSONSerialization.jsonObject(with: Data(list.utf8)) as? [String: Any])?["devices"] as? [String: [[String: Any]]] ?? [:]
        return runtimes.values.joined().compactMap { entry in
            guard let udid = entry["udid"] as? String, let name = entry["name"] as? String else { return nil }
            return Device(udid: udid, name: name, type: entry["deviceTypeIdentifier"] as? String ?? "")
        }
    }

    private static func bootedUDIDs() async throws -> Set<String> {
        let list = try await Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "booted", "--json"])
        let runtimes = (try? JSONSerialization.jsonObject(with: Data(list.utf8)) as? [String: Any])?["devices"] as? [String: [[String: Any]]] ?? [:]
        return Set(runtimes.values.joined().compactMap { $0["udid"] as? String })
    }

    private static func deviceTypes() async throws -> [(name: String, identifier: String)] {
        try await typeList().map { ($0.name, $0.identifier) }
    }

    private static func typeList() async throws -> [(name: String, identifier: String, bundle: URL?)] {
        let list = try await Shell.run("/usr/bin/xcrun", ["simctl", "list", "devicetypes", "--json"])
        let types = (try? JSONSerialization.jsonObject(with: Data(list.utf8)) as? [String: Any])?["devicetypes"] as? [[String: Any]] ?? []
        return types.compactMap { type in
            guard let name = type["name"] as? String, let identifier = type["identifier"] as? String else { return nil }
            return (name, identifier, (type["bundlePath"] as? String).map { URL(fileURLWithPath: $0) })
        }
    }

    /// The device type bundle of a device type, such as com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro.
    static func typeBundle(_ type: String) async throws -> URL {
        guard let bundle = try await typeList().first(where: { $0.identifier == type })?.bundle else {
            throw DuoError.sim("Xcode has no device type \(type)")
        }
        return bundle
    }

    /// The device type that a name stands for, without making a simulator: the type of a
    /// simulator of that name, or the iPhone model of that name.
    static func type(of device: String) async throws -> String {
        let simulators = try await available()
        switch choose(device, simulators: simulators, types: try await deviceTypes()) {
        case .existing(let found): return found.type
        case .make(_, let type): return type
        case nil: throw DuoError.sim("no simulator or iPhone model is named \"\(device)\". `duorex devices` lists the iPhones.")
        }
    }

    private static func newestRuntime(for type: String) async throws -> String {
        let list = try await Shell.run("/usr/bin/xcrun", ["simctl", "list", "runtimes", "available", "--json"])
        let runtimes = (try? JSONSerialization.jsonObject(with: Data(list.utf8)) as? [String: Any])?["runtimes"] as? [[String: Any]] ?? []
        let fitting = runtimes.filter { runtime in
            (runtime["supportedDeviceTypes"] as? [[String: Any]] ?? []).contains { $0["identifier"] as? String == type }
        }
        let newest = fitting.max { ($0["version"] as? String ?? "").compare($1["version"] as? String ?? "", options: .numeric) == .orderedAscending }
        guard let identifier = newest?["identifier"] as? String else {
            throw DuoError.sim(type == duoType ? "no installed iOS runtime supports iPhone Duo. Install iOS 27.1 or later in Xcode."
                                               : "no installed iOS runtime supports this iPhone. Install a newer iOS in Xcode.")
        }
        return identifier
    }
}
