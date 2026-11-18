/// Reads what follows `duorex` on the command line: the subcommand, plain words such as the
/// two numbers of `tap 0.5 0.4`, `--name value` pairs, and flags.
nonisolated struct Arguments {
    /// The flags that take no value. A word after one of them is a plain word.
    private static let flags: Set<String> = ["pattern", "stage", "grid", "full", "no-pane"]

    let command: String
    /// The plain words after the subcommand, in order.
    private(set) var words: [String] = []
    private var values: [String: String] = [:]

    init(_ raw: [String]) {
        var rest = Array(raw.dropFirst())
        command = rest.first.map { $0.hasPrefix("-") ? "view" : $0 } ?? "view"
        if rest.first == command { rest.removeFirst() }
        var index = 0
        while index < rest.count {
            let word = rest[index]
            index += 1
            guard word.hasPrefix("--") else {
                words.append(word)
                continue
            }
            let name = String(word.dropFirst(2))
            if !Self.flags.contains(name), index < rest.count, !rest[index].hasPrefix("--") {
                values[name] = rest[index]
                index += 1
            } else {
                values[name] = ""
            }
        }
    }

    func string(_ name: String) -> String? { values[name].flatMap { $0.isEmpty ? nil : $0 } }
    func double(_ name: String, default fallback: Double) -> Double { values[name].flatMap(Double.init) ?? fallback }
    func flag(_ name: String) -> Bool { values[name] != nil }

    /// The plain words as numbers, or nil when there are not `count` of them or one is not a number.
    func numbers(_ count: Int) -> [Double]? {
        let numbers = words.compactMap(Double.init)
        return words.count == count && numbers.count == count ? numbers : nil
    }
}
