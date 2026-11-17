import AppKit

/// Reads `--name value` pairs and bare flags after the subcommand.
struct Arguments {
    private var values: [String: String] = [:]
    let command: String

    init(_ raw: [String]) {
        var rest = Array(raw.dropFirst())
        command = rest.first.map { $0.hasPrefix("-") ? "view" : $0 } ?? "view"
        if rest.first == command { rest.removeFirst() }
        var index = 0
        while index < rest.count {
            let name = rest[index]
            if name.hasPrefix("--"), index + 1 < rest.count, !rest[index + 1].hasPrefix("--") {
                values[String(name.dropFirst(2))] = rest[index + 1]
                index += 2
            } else {
                values[String(name.drop(while: { $0 == "-" }))] = ""
                index += 1
            }
        }
    }

    func string(_ name: String) -> String? { values[name] }
    func double(_ name: String, default fallback: Double) -> Double { values[name].flatMap(Double.init) ?? fallback }
    func flag(_ name: String) -> Bool { values[name] != nil }
}

let arguments = Arguments(CommandLine.arguments)
var session: Session?

func fail(_ error: any Error) -> Never {
    FileHandle.standardError.write(Data("duorex: \(error)\n".utf8))
    exit(1)
}

func scene() async throws -> DuoScene {
    let scene = try await DuoScene(finish: arguments.string("finish") ?? "Dark")
    if arguments.flag("pattern") {
        scene.setScreen(.cover, texture: try Snapshot.testPattern(label: "COVER", width: 600, height: 1300))
        scene.setScreen(.inner, texture: try Snapshot.testPattern(label: "INNER", width: 1200, height: 1300))
    }
    return scene
}

// The run loop must own the main thread: started from inside a task, it would never drain the main queue.
switch arguments.command {
case "snapshot":
    Task {
        do {
            let pose = DuoScene.Pose(hinge: arguments.double("hinge", default: 180), roll: arguments.double("roll", default: 0),
                                     yaw: arguments.double("yaw", default: 0), pitch: arguments.double("pitch", default: 0))
            let out = URL(fileURLWithPath: arguments.string("out") ?? "duorex.png")
            let gray = arguments.string("backdrop").flatMap(Double.init)
            try await Snapshot.write(scene: try await scene(), pose: pose, width: Int(arguments.double("width", default: 1400)),
                                     height: Int(arguments.double("height", default: 1000)),
                                     backdrop: gray.map { CGColor(gray: $0, alpha: 1) }, to: out)
            print(out.path)
            exit(0)
        } catch { fail(error) }
    }
    dispatchMain()
case "view":
    NSApplication.shared.setActivationPolicy(.accessory)
    Task {
        do {
            session = try Session(scene: try await scene())
            session?.start()
        } catch { fail(error) }
    }
    NSApplication.shared.run()
default:
    FileHandle.standardError.write(Data("usage: duorex [view] [--finish Dark|Light]\n       duorex snapshot [--hinge deg] [--yaw deg] [--pitch deg] [--roll deg] [--pattern] [--out file.png]\n".utf8))
    exit(2)
}
