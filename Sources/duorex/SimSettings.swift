import Foundation

/// The settings of a simulator that `simctl` changes.
nonisolated enum SimSettings {
    /// Switches between the light and the dark appearance. Returns the name of the new one.
    static func toggleAppearance(of udid: String) async throws -> String {
        let next = try await ui(udid, "appearance") == "dark" ? "light" : "dark"
        _ = try await ui(udid, "appearance", next)
        return next
    }

    /// Makes the text one size larger or smaller. Returns the name of the new size, such as "extra-large".
    static func stepTextSize(of udid: String, larger: Bool) async throws -> String {
        _ = try await ui(udid, "content_size", larger ? "increment" : "decrement")
        return try await ui(udid, "content_size")
    }

    private static func ui(_ udid: String, _ arguments: String...) async throws -> String {
        try await Shell.run("/usr/bin/xcrun", ["simctl", "ui", udid] + arguments)
    }
}
