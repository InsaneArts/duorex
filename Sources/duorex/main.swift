import AppKit
import RealityKit

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

/// Runs one command of an agent on the simulator: it connects, does the work and says what
/// the work says. The last line is always how the device is after it, so a path that the work
/// gives stands alone on its line.
func onSimulator(_ work: @escaping (SimDriver) async throws -> String) -> Never {
    untilDone {
        let address = try await SimServer.address(device: arguments.string("device"), server: arguments.string("server"))
        let driver = SimDriver(sim: Sim(base: address))
        _ = try await driver.connect()
        print(try await work(driver))
        print(driver.summary)
        driver.stop()
    }
}

/// Gives the app a moment after a touch, so a screenshot that comes next is not of a button half pressed.
func settle() async {
    try? await Task.sleep(for: .milliseconds(450))
}

/// Opens a duorex pane beside this one, unless one is open or this is not Rex. Returns what it did, in a few words.
func showPane(device: String) async throws -> String {
    guard let session = RexHost.session else { return "this is not a Rex pane. Run duorex in a pane to watch." }
    guard !Panes.isOpen(in: session) else { return "the duorex pane is open" }
    let binary = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? "duorex"
    let server = arguments.string("server").map { ["--server", $0] } ?? []
    _ = try await RexHost.openPane(running: [binary, "--device", device] + server)
    // The pane says that it is open as soon as it starts. Wait for that, so the next command does not open another.
    for _ in 0..<40 where !Panes.isOpen(in: session) { try? await Task.sleep(for: .milliseconds(100)) }
    return Panes.isOpen(in: session) ? "opened a duorex pane beside this one" : "asked Rex for a duorex pane, but duorex did not start in it"
}

/// Ends duorex with how to use a command. Arguments are checked before the simulator is asked for anything.
func wrongUse(_ text: String) -> Never {
    fail(DuoError.terminal("usage: duorex \(text)"))
}

/// Finds out that a picture or a movie can be saved before the simulator is moved for it.
func mustBeWritable(_ url: URL) throws {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
        throw DuoError.render("cannot write to \(url.deletingLastPathComponent().path)")
    }
}

func scene() async throws -> DuoScene {
    let scene = try await DuoScene(finish: arguments.string("finish") ?? "Dark")
    scene.isWireframe = arguments.flag("wireframe")
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
case "run":
    untilDone {
        let address = try await SimServer.address(device: arguments.string("device"), server: arguments.string("server"))
        let device = address.lastPathComponent
        let app: AppRunner.App
        if let path = arguments.string("app") {
            app = try AppRunner.app(at: path)
        } else {
            let folder = URL(fileURLWithPath: arguments.words.first ?? FileManager.default.currentDirectoryPath)
            app = try await AppRunner.build(in: folder, scheme: arguments.string("scheme"), udid: device) { print($0) }
        }
        // Ctrl-C during the build ends the run here. It does not go on to start the app.
        try Task.checkCancellation()
        print("starting \(app.bundleID)")
        try await AppRunner.start(app, on: device)
        if !arguments.flag("no-pane") {
            // The app runs. A pane that did not open is said, and is no reason to fail.
            do { print(try await showPane(device: device)) } catch { print("could not open a duorex pane: \(error)") }
        }
        let driver = SimDriver(sim: Sim(base: address))
        _ = try await driver.connect()
        _ = await driver.settledScreen()
        print("running")
        print(driver.summary)
        driver.stop()
    }
case "open":
    untilDone {
        let address = try await SimServer.address(device: arguments.string("device"), server: arguments.string("server"))
        print(try await showPane(device: address.lastPathComponent))
    }
case "screenshot":
    onSimulator { driver in
        guard let screen = driver.screen,
              let image = ScreenShot.image(of: screen, interface: driver.interface, longestSide: arguments.flag("full") ? nil : 1568, grid: arguments.flag("grid"))
        else { throw DuoError.sim("the simulator sent no picture.") }
        let out = arguments.string("out").map { URL(fileURLWithPath: $0) } ?? arguments.words.first.map { URL(fileURLWithPath: $0) } ?? ScreenShot.temporaryFile("screen")
        try ScreenShot.write(image, to: out)
        return out.path
    }
case "tap":
    guard let point = arguments.numbers(2), point.allSatisfy({ (0...1).contains($0) }) else { wrongUse("tap X Y, each from 0 to 1 on the newest screenshot") }
    onSimulator { driver in
        await driver.tap(at: CGPoint(x: point[0], y: point[1]))
        await settle()
        return "tapped \(point[0]) \(point[1])"
    }
case "swipe":
    let seconds = arguments.double("seconds", default: 0.25)
    guard let points = arguments.numbers(4), points.allSatisfy({ (0...1).contains($0) }), seconds.isFinite, (0...10).contains(seconds) else {
        wrongUse("swipe X1 Y1 X2 Y2 [--seconds 0.25], each point from 0 to 1 on the newest screenshot")
    }
    onSimulator { driver in
        await driver.swipe(from: CGPoint(x: points[0], y: points[1]), to: CGPoint(x: points[2], y: points[3]), seconds: seconds)
        await settle()
        return "swiped \(points[0]) \(points[1]) to \(points[2]) \(points[3])"
    }
case "home":
    onSimulator { driver in
        await driver.swipe(from: CGPoint(x: 0.5, y: 0.985), to: CGPoint(x: 0.5, y: 0.5), seconds: 0.2)
        await settle()
        return "went home"
    }
case "fold":
    let postures = ["shut": 0.0, "closed": 0, "book": 130, "open": 180]
    guard let word = arguments.words.first, let target = postures[word] ?? Double(word), (0...180).contains(target) else {
        wrongUse("fold closed|book|open, or an angle from 0 to 180")
    }
    onSimulator { driver in
        let start = driver.report?.hingeDegrees ?? (driver.litPanel == .cover ? 0 : 180)
        guard await driver.fold(from: start, to: target) else {
            try Task.checkCancellation()
            throw DuoError.sim("the simulator did not fold to \(Int(target)) degrees.")
        }
        _ = await driver.settledScreen()
        return "folded to \(Int(target))"
    }
case "rotate":
    let holds: [String: Orientation] = ["upright": .portrait, "clockwise": .landscapeLeft, "upside-down": .upsideDown, "counterclockwise": .landscapeRight]
    guard let held = arguments.words.first.flatMap({ holds[$0] }) else { wrongUse("rotate upright|clockwise|upside-down|counterclockwise") }
    onSimulator { driver in
        guard await driver.turn(to: held) else {
            try Task.checkCancellation()
            throw DuoError.sim("the simulator did not turn.")
        }
        _ = await driver.settledScreen()
        return "held \(held.label)"
    }
case "press":
    let buttons: [String: HardwareButton] = ["power": .power, "volume-up": .volumeUp, "volume-down": .volumeDown, "camera": .cameraControl]
    guard let button = arguments.words.first.flatMap({ buttons[$0] }) else { wrongUse("press power|volume-up|volume-down|camera") }
    onSimulator { driver in
        await driver.press(button)
        await settle()
        return "pressed \(button.rawValue.lowercased())"
    }
case "strobe":
    untilDone {
        let out = URL(fileURLWithPath: arguments.string("out") ?? "duorex-strobe.png")
        let size = (arguments.string("size") ?? "2560x1440").split(separator: "x").compactMap { Int($0) }
        guard size.count == 2, size.allSatisfy({ (64...8192).contains($0) }) else {
            throw DuoError.render("--size takes a width and a height, such as 2560x1440")
        }
        try mustBeWritable(out)
        let scene = try await scene()
        if !arguments.flag("pattern") {
            // The picture shows the app as it is on the open device, on every exposure.
            let address = try await SimServer.address(device: arguments.string("device"), server: arguments.string("server"))
            let screen = try await SimDriver(sim: Sim(base: address)).screens(at: [180])[0]
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
        try mustBeWritable(out)
        let scene = try await scene()
        var screens: [CGImage]
        if arguments.flag("pattern") {
            // No simulator: the test patterns stand in for the app.
            screens = []
        } else {
            let address = try await SimServer.address(device: arguments.string("device"), server: arguments.string("server"))
            print("taking the app's screens from the simulator")
            screens = try await SimDriver(sim: Sim(base: address)).screens(at: [0, 180, FilmScript.book])
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
        // With no name, the sheet goes out of the project, so a sweep leaves nothing behind there.
        let out = arguments.string("out").map { URL(fileURLWithPath: $0) } ?? ScreenShot.temporaryFile("sweep")
        try mustBeWritable(out)
        let scene = try await DuoScene(finish: arguments.string("finish") ?? "Dark")
        let address = try await SimServer.address(device: arguments.string("device"), server: arguments.string("server"))
        let shots = try await Sweep(sim: Sim(base: address), scene: scene).run { print($0) }
        try ContactSheet.write(shots, to: out)
        print(out.path)
    }
case "view", "record":
    // Before anything slow, so a command that wants a pane sees this one at once.
    if let session = RexHost.session { Panes.opened(in: session) }
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
    FileHandle.standardError.write(Data("""
    usage: duorex [view] [--device name|udid] [--server url] [--finish Dark|Light] [--wireframe]

    for an agent:
      duorex run [folder] [--scheme name] [--app path.app]   build the app, start it, and open the pane
      duorex screenshot [file.png] [--grid] [--full]         the screen, upright
      duorex tap X Y                                         X and Y from 0 to 1, as in the screenshot
      duorex swipe X1 Y1 X2 Y2 [--seconds 0.25]
      duorex home
      duorex fold closed|book|open|DEGREES
      duorex rotate upright|clockwise|upside-down|counterclockwise
      duorex press power|volume-up|volume-down|camera
      duorex sweep [--out sheet.png]                         six postures in one picture
      duorex open                                            only open the pane

    pictures:
      duorex record [--out movie.mp4] [--size 1920x1080]
      duorex strobe [--out poster.png] [--size 2560x1440]
      duorex film [--out film.mp4] [--size 1920x1080]

      duorex update
      duorex version

    """.utf8))
    exit(2)
}
