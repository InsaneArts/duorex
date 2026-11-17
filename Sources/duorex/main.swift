import CoreGraphics
import Foundation

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

do {
    switch arguments.command {
    case "snapshot":
        let scene = try await DuoScene(finish: arguments.string("finish") ?? "Dark")
        if arguments.flag("pattern") {
            scene.setScreen(.cover, texture: try Snapshot.testPattern(label: "COVER", width: 600, height: 1300))
            scene.setScreen(.inner, texture: try Snapshot.testPattern(label: "INNER", width: 1200, height: 1300))
        }
        let pose = DuoScene.Pose(hinge: arguments.double("hinge", default: 180), roll: arguments.double("roll", default: 0),
                                 yaw: arguments.double("yaw", default: 0), pitch: arguments.double("pitch", default: 0))
        let out = URL(fileURLWithPath: arguments.string("out") ?? "duorex.png")
        let gray = arguments.string("backdrop").flatMap(Double.init)
        try await Snapshot.write(scene: scene, pose: pose, width: Int(arguments.double("width", default: 1400)),
                                 height: Int(arguments.double("height", default: 1000)),
                                 backdrop: gray.map { CGColor(gray: $0, alpha: 1) }, to: out)
        print(out.path)
    default:
        FileHandle.standardError.write(Data("usage: duorex snapshot [--hinge deg] [--yaw deg] [--pitch deg] [--roll deg] [--finish Dark|Light] [--pattern] [--out file.png]\n".utf8))
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("duorex: \(error)\n".utf8))
    exit(1)
}
