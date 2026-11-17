import Testing
@testable import duorex

@Test func `a tool's output comes back without its trailing newline`() async throws {
    #expect(try await Shell.run("/bin/echo", ["hello"]) == "hello")
}

@Test(.timeLimit(.minutes(1)))
func `output larger than a pipe holds comes back whole`() async throws {
    // `simctl list --json` prints more than the 64 KB a pipe holds on a Mac with many simulators.
    let text = try await Shell.run("/bin/sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' a"])
    #expect(text.count == 300_000)
}

@Test func `standard error stays out of the output`() async throws {
    #expect(try await Shell.run("/bin/sh", ["-c", "echo warning >&2; echo result"]) == "result")
}

@Test func `a failing tool throws what it wrote to standard error`() async {
    await #expect(throws: Shell.Failure.self) {
        try await Shell.run("/bin/sh", ["-c", "echo no such device >&2; exit 3"])
    }
    do {
        _ = try await Shell.run("/bin/sh", ["-c", "echo no such device >&2; exit 3"])
    } catch {
        #expect("\(error)" == "sh failed: no such device")
    }
}

@Test func `a tool that does not exist throws`() async {
    await #expect(throws: Shell.Failure.self) {
        try await Shell.run("/nonexistent/tool", [])
    }
}
