import Foundation

/// The release this build is, and the way to get a newer one.
enum Release {
    /// Matches the release tag: version 0.1.0 is tagged v0.1.0.
    static let version = "0.1.0"

    /// Where `install.sh` keeps the source it builds from.
    private static var source: URL {
        if let custom = ProcessInfo.processInfo.environment["DUOREX_SRC"] { return URL(fileURLWithPath: custom) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/duorex/src")
    }

    /// Runs the installer again. It fetches the newest release and rebuilds only when there is one.
    static func update() -> Never {
        let installer = source.appendingPathComponent("install.sh").path
        guard FileManager.default.isReadableFile(atPath: installer) else {
            FileHandle.standardError.write(Data("""
            duorex was not installed with install.sh, so it cannot update itself. Install it with:
              curl -fsSL https://raw.githubusercontent.com/tornikegomareli/duorex/main/install.sh | sh

            """.utf8))
            exit(1)
        }
        execv("/bin/sh", ["/bin/sh", installer].map { strdup($0) } + [nil])
        FileHandle.standardError.write(Data("duorex: could not run \(installer)\n".utf8))
        exit(1)
    }
}
