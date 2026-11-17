import Foundation

/// Asks Rex where this pane sits in its window, and whether its tab is the one showing.
final class RexHost {
    static let bundleID = "com.superlogical.rex"
    private nonisolated static let layoutEvents = ["session_view_changed", "window_created", "window_closed", "block_created", "block_closed"]

    var onChange: ((Dock.Placement) -> Void)?

    private let rex: URL
    private let session: String
    private let block: String
    private var events: Process?
    private var refreshing = false
    private var stale = false

    /// Nil when duorex is not running inside a Rex pane.
    init?() {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["REX_BIN_DIR"], let session = environment["REX_SESSION"], let block = environment["REX_BLOCK"] else { return nil }
        rex = URL(fileURLWithPath: directory).appendingPathComponent("rex")
        self.session = session
        self.block = block
    }

    func start() {
        refresh()
        // Terminals in the session report titles and status all the time. Only layout events move the pane.
        let events = Process()
        events.executableURL = rex
        events.arguments = ["events", "--session", session, "--json"]
        let pipe = Pipe()
        events.standardOutput = pipe
        events.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard Self.layoutEvents.contains(where: { text.contains("\"type\":\"\($0)\"") }) else { return }
            DispatchQueue.main.async { self?.refresh() }
        }
        do { try events.run() } catch { log.error("rex events: \(error.localizedDescription, privacy: .public)") }
        self.events = events
    }

    func stop() { events?.terminate() }

    /// Reads the layout again. Events that arrive while it runs lead to one more read after it.
    private func refresh() {
        guard !refreshing else {
            stale = true
            return
        }
        refreshing = true
        Task {
            let view = try? await Shell.run(rex.path, ["api", "call", "--session", session, "session.view"])
            refreshing = false
            if let view, let placement = placement(from: Data(view.utf8)) {
                log.info("rex pane \(placement.rect.debugDescription, privacy: .public) shown \(placement.shown)")
                onChange?(placement)
            }
            if stale {
                stale = false
                refresh()
            }
        }
    }

    private func placement(from data: Data) -> Dock.Placement? {
        guard let view = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = view["windows"] as? [[String: Any]] else { return nil }
        var placement = Dock.Placement(shown: false, titleSuffix: view["label"] as? String)
        for window in windows {
            let layers = window["layers"] as? [[String: Any]] ?? []
            // Layers are listed back to front: later ones float above earlier ones.
            guard let index = layers.firstIndex(where: { Self.rect(of: block, in: $0["layout"]) != nil }),
                  let leaf = Self.rect(of: block, in: layers[index]["layout"]) else { continue }
            let bounds = Self.rect(layers[index]["bounds"]) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            var rect = CGRect(x: bounds.minX + leaf.minX * bounds.width, y: bounds.minY + leaf.minY * bounds.height,
                              width: leaf.width * bounds.width, height: leaf.height * bounds.height)
            var shown = window["window_id"] as? String == view["active_window_id"] as? String
            if let zoomed = Self.value(for: "zoomed_block_id", in: window) as? String {
                if zoomed == block { rect = bounds } else { shown = false }
            }
            // A floating layer in front of the pane, such as a popup, hides the device.
            let covered = layers[(index + 1)...].contains { Self.rect($0["bounds"]).map { $0.intersects(rect) } ?? false }
            placement.rect = rect
            placement.shown = shown && !covered
        }
        return placement
    }

    private static func rect(_ value: Any?) -> CGRect? {
        guard let numbers = value as? [Double], numbers.count == 4 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    /// A layout is a pane, or a split with a pane or split on each side.
    private static func rect(of block: String, in layout: Any?) -> CGRect? {
        guard let node = layout as? [String: Any] else { return nil }
        if node["block_id"] as? String == block { return rect(node["rect"]) }
        guard let split = node["split"] as? [String: Any] else { return nil }
        return rect(of: block, in: split["before"]) ?? rect(of: block, in: split["after"])
    }

    private static func value(for key: String, in tree: Any) -> Any? {
        if let dictionary = tree as? [String: Any] {
            if let found = dictionary[key] { return found }
            return dictionary.values.lazy.compactMap { value(for: key, in: $0) }.first
        }
        return (tree as? [Any])?.lazy.compactMap { value(for: key, in: $0) }.first
    }
}
