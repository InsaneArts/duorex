import AppKit
import RealityKit

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
var signalSources: [DispatchSourceSignal] = []

func fail(_ error: any Error) -> Never {
    FileHandle.standardError.write(Data("duorex: \(error)\n".utf8))
    exit(1)
}

/// Runs work that moves the simulator, then exits. Ctrl-C stops the work, and the work puts
/// the simulator back before duorex exits.
func untilDone(_ work: @escaping () async throws -> Void) -> Never {
    let working = Task {
        do {
            try await work()
            exit(0)
        } catch is CancellationError {
            exit(130)
        } catch { fail(error) }
    }
    for number in [SIGINT, SIGTERM] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { working.cancel() }
        source.resume()
        signalSources.append(source)
    }
    RunLoop.main.run()
    exit(0)
}

extension Array {
    /// Like `map`, for work that waits. The elements are done in order.
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        for element in self { results.append(try await transform(element)) }
        return results
    }
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
case "version":
    print(Release.version)
case "update":
    Release.update()
case "snapshot":
    Task {
        do {
            var pose = Pose(hinge: arguments.double("hinge", default: 180), roll: arguments.double("roll", default: 0),
                            yaw: arguments.double("yaw", default: 0), pitch: arguments.double("pitch", default: 0))
            if let button = arguments.string("press").flatMap({ name in HardwareButton.allCases.first { $0.rawValue.lowercased() == name.lowercased() } }) {
                pose.press = .init(button: button, depth: 1)
            }
            // "--touch x,y" draws a tap there, and "--touch x,y,x,y" a swipe, each as it looks at "--age" seconds.
            var presence = Presence()
            let touch = (arguments.string("touch") ?? "").split(separator: ",").compactMap { Double($0) }
            if touch.count == 2 { presence.saw(.tap(CGPoint(x: touch[0], y: touch[1])), time: 0) }
            if touch.count == 4 { presence.saw(.drag(from: CGPoint(x: touch[0], y: touch[1]), to: CGPoint(x: touch[2], y: touch[3]), ended: true), time: 0) }
            let out = URL(fileURLWithPath: arguments.string("out") ?? "duorex.png")
            let gray = arguments.string("backdrop").flatMap(Double.init)
            try await Snapshot.write(scene: try await scene(), pose: pose, marks: presence.step(to: arguments.double("age", default: 0.1)),
                                     width: Int(arguments.double("width", default: 1400)),
                                     height: Int(arguments.double("height", default: 1000)),
                                     backdrop: gray.map { CGColor(gray: $0, alpha: 1) }, onStage: arguments.flag("stage"), to: out)
            print(out.path)
            exit(0)
        } catch { fail(error) }
    }
    dispatchMain()
case "strobe":
    untilDone {
        let out = URL(fileURLWithPath: arguments.string("out") ?? "duorex-strobe.png")
        let size = (arguments.string("size") ?? "2560x1440").split(separator: "x").compactMap { Int($0) }
        guard size.count == 2, size.allSatisfy({ (64...8192).contains($0) }) else {
            throw DuoError.render("--size takes a width and a height, such as 2560x1440")
        }
        let scene = try await scene()
        if !arguments.flag("pattern") {
            // The picture shows the app as it is on the open device, on every exposure.
            let address = try await SimServer.address(device: arguments.string("device"), server: arguments.string("server"))
            let screen = try await Sweep(sim: Sim(base: address), scene: scene).screens(at: [180])[0]
            scene.setScreen(.inner, texture: try await TextureResource(image: screen, options: .init(semantic: .color)))
        }
        try await Strobe.write(scene: scene, width: size[0], height: size[1], to: out)
        print(out.path)
    }
case "film":
    untilDone {
        let out = URL(fileURLWithPath: arguments.string("out") ?? "duorex-film.mp4")
        let size = (arguments.string("size") ?? "1920x1080").split(separator: "x").compactMap { Int($0) }
        guard size.count == 2, size.allSatisfy({ (64...4096).contains($0) && $0 % 2 == 0 }) else {
            throw DuoError.render("--size takes a width and a height, both even, such as 1920x1080")
        }
        let scene = try await DuoScene(finish: arguments.string("finish") ?? "Dark")
        var screens: [CGImage]
        if arguments.flag("pattern") {
            // No simulator: the test patterns stand in for the app.
            screens = []
        } else {
            let address = try await SimServer.address(device: arguments.string("device"), server: arguments.string("server"))
            print("taking the app's screens from the simulator")
            screens = try await Sweep(sim: Sim(base: address), scene: scene).screens(at: [0, 180, FilmScript.book])
        }
        let textures: [TextureResource] = try await screens.isEmpty
            ? [Snapshot.testPattern(label: "COVER", width: 600, height: 1300), Snapshot.testPattern(label: "INNER", width: 1200, height: 1300),
               Snapshot.testPattern(label: "BOOK", width: 1200, height: 1300)]
            : screens.asyncMap { try await TextureResource(image: $0, options: .init(semantic: .color)) }
        try await Film(scene: scene).write(screens: (textures[0], textures[1], textures[2]), to: out, width: size[0], height: size[1]) { share in
            print("drawing: \(Int(share * 100))%")
        }
        print(out.path)
    }
case "sweep":
    untilDone {
        // Find out now that the sheet can be saved, not after the sweep.
        let out = URL(fileURLWithPath: arguments.string("out") ?? "duorex-sweep.png")
        guard FileManager.default.isWritableFile(atPath: out.deletingLastPathComponent().path) else {
            throw DuoError.render("cannot write to \(out.deletingLastPathComponent().path)")
        }
        let scene = try await DuoScene(finish: arguments.string("finish") ?? "Dark")
        let address = try await SimServer.address(device: arguments.string("device"), server: arguments.string("server"))
        let shots = try await Sweep(sim: Sim(base: address), scene: scene).run { print($0) }
        try ContactSheet.write(shots, to: out)
        print(out.path)
    }
case "view", "record":
    NSApplication.shared.setActivationPolicy(.accessory)
    Task {
        do {
            var movie: (url: URL, width: Int, height: Int)?
            if arguments.command == "record" {
                // The time on the user's clock, in a form that sorts by name.
                let stamp = DateFormatter()
                stamp.locale = Locale(identifier: "en_US_POSIX")
                stamp.dateFormat = "yyyyMMdd-HHmmss"
                let folder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: ".")
                let size = (arguments.string("size") ?? "1920x1080").split(separator: "x").compactMap { Int($0) }
                guard size.count == 2, size.allSatisfy({ (64...4096).contains($0) && $0 % 2 == 0 }) else {
                    throw DuoError.render("--size takes a width and a height, both even, such as 1920x1080")
                }
                movie = (arguments.string("out").map { URL(fileURLWithPath: $0) } ?? folder.appendingPathComponent("duorex-\(stamp.string(from: Date())).mp4"), size[0], size[1])
            }
            let running = try Session(scene: try await scene(), movie: movie)
            session = running
            running.start()
            guard !arguments.flag("pattern") else { return running.showKeys() }
            do {
                running.attach(to: try await SimServer.address(device: arguments.string("device"), server: arguments.string("server")))
            } catch {
                running.show("\(error)")
            }
        } catch { fail(error) }
    }
    NSApplication.shared.run()
default:
    FileHandle.standardError.write(Data("usage: duorex [view] [--device name|udid] [--server url] [--finish Dark|Light]\n       duorex record [--out movie.mp4] [--size 1920x1080]\n       duorex sweep [--out sheet.png] [--device name|udid] [--server url]\n       duorex strobe [--out poster.png] [--size 2560x1440]\n       duorex film [--out film.mp4] [--size 1920x1080]\n       duorex update\n       duorex version\n".utf8))
    exit(2)
}
