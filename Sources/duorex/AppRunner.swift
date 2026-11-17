import Foundation

/// Builds an Xcode project for a simulator, puts the app on it and starts it.
nonisolated enum AppRunner {
    /// A built app, ready for a simulator.
    struct App: Equatable {
        /// The path of the `.app` folder.
        var path: String
        var bundleID: String
    }

    // MARK: Reading what xcodebuild says

    /// The workspace or the project in a folder, as xcodebuild's arguments. A workspace wins:
    /// a project that has one is built through it.
    static func container(in directory: URL) throws -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.sorted() ?? []
        if let workspace = names.first(where: { $0.hasSuffix(".xcworkspace") }) { return ["-workspace", workspace] }
        if let project = names.first(where: { $0.hasSuffix(".xcodeproj") }) { return ["-project", project] }
        throw DuoError.sim("there is no Xcode project in \(directory.path). Build the app yourself and give it with --app.")
    }

    /// The scheme to build, from the answer of `xcodebuild -list -json`. Without a wanted
    /// one, it is the only scheme, or the one named like the project.
    static func scheme(fromList json: Data, wanted: String?) throws -> String {
        let list = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
        let container = (list?["workspace"] ?? list?["project"]) as? [String: Any]
        let schemes = container?["schemes"] as? [String] ?? []
        if let wanted {
            guard schemes.contains(wanted) else { throw DuoError.sim("there is no scheme \"\(wanted)\". The schemes are: \(schemes.joined(separator: ", ")).") }
            return wanted
        }
        if schemes.count == 1 { return schemes[0] }
        if let name = container?["name"] as? String, schemes.contains(name) { return name }
        guard !schemes.isEmpty else { throw DuoError.sim("the project has no scheme to build.") }
        throw DuoError.sim("the project has \(schemes.count) schemes: \(schemes.joined(separator: ", ")). Choose one with --scheme.")
    }

    /// The app that a scheme builds, from the answer of `xcodebuild -showBuildSettings -json`.
    static func product(fromSettings json: Data, scheme: String) throws -> App {
        let targets = (try? JSONSerialization.jsonObject(with: json)) as? [[String: Any]] ?? []
        let apps = targets.filter { ($0["buildSettings"] as? [String: Any])?["PRODUCT_TYPE"] as? String == "com.apple.product-type.application" }
        // A scheme can build more than one app, as with a watch app. The one named like the scheme is the one to run.
        guard let target = apps.first(where: { $0["target"] as? String == scheme }) ?? apps.last,
              let settings = target["buildSettings"] as? [String: Any],
              let folder = settings["TARGET_BUILD_DIR"] as? String, let name = settings["WRAPPER_NAME"] as? String,
              let bundleID = settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String
        else { throw DuoError.sim("the scheme \"\(scheme)\" does not build an app.") }
        return App(path: folder + "/" + name, bundleID: bundleID)
    }

    /// The errors in what a failed build printed, each once, without the build's other lines.
    static func errors(in output: String) -> [String] {
        var seen = Set<String>()
        return output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("error:") && seen.insert($0).inserted }
    }

    // MARK: Building and starting

    /// Builds the project in `directory` for the simulator and returns its app.
    static func build(in directory: URL, scheme wanted: String?, udid: String, progress: (String) -> Void) async throws -> App {
        let container = try container(in: directory)
        func xcodebuild(_ arguments: [String]) async throws -> (status: Int32, output: String, errors: String) {
            try await Shell.result("/usr/bin/xcrun", ["xcodebuild"] + arguments, in: directory)
        }
        let list = try await xcodebuild(["-list", "-json"] + container)
        let scheme = try scheme(fromList: Data(list.output.utf8), wanted: wanted)
        let target = container + ["-scheme", scheme, "-configuration", "Debug", "-destination", "platform=iOS Simulator,id=\(udid)"]
        progress("building \(scheme)")
        let build = try await xcodebuild(["build", "-quiet"] + target)
        guard build.status == 0 else {
            let errors = errors(in: build.output + "\n" + build.errors)
            throw DuoError.sim("the build failed.\n" + (errors.isEmpty ? String((build.output + "\n" + build.errors).suffix(1500)) : errors.prefix(12).joined(separator: "\n")))
        }
        let settings = try await xcodebuild(["-showBuildSettings", "-json"] + target)
        return try product(fromSettings: Data(settings.output.utf8), scheme: scheme)
    }

    /// An app that is built already, at the path of its `.app` folder.
    static func app(at path: String) throws -> App {
        let info = URL(fileURLWithPath: path).appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String
        else { throw DuoError.sim("\(path) is not a built app: it has no Info.plist with a bundle identifier.") }
        return App(path: path, bundleID: bundleID)
    }

    /// Puts the app on the simulator and starts it, in place of a copy that is running.
    static func start(_ app: App, on udid: String) async throws {
        _ = try await Shell.run("/usr/bin/xcrun", ["simctl", "install", udid, app.path])
        _ = try await Shell.run("/usr/bin/xcrun", ["simctl", "launch", "--terminate-running-process", udid, app.bundleID])
    }
}
