import XCTest
@testable import Domain

/// Behavior tests for the zsh busy shim (#94, #96, #103). They run the generated script in a real
/// `/bin/zsh` and check the bytes its hooks print, so the zsh quoting itself is under test (a wrong
/// `$'…'` expansion once shipped literal text instead of an escape, #96).
final class BusyShellShimTests: XCTestCase {

    private let busy = "\u{1b}]9;4;3\u{1b}\\"
    private let idle = "\u{1b}]9;4;0\u{1b}\\"

    /// Run `call` after loading the shim in an interactive zsh without user rc files. `command` is
    /// passed through the environment so no quoting is needed.
    private func output(of call: String, command: String = "", environment: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-i", "-c", BusyShellShim.zshenv + "\n" + call]
        process.environment = ["PATH": "/usr/bin:/bin", "BOSUN_TEST_COMMAND": command]
            .merging(environment) { _, new in new }
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func preexec(_ command: String, termProgram: String = "ghostty", tmux: Bool = false) throws -> String {
        var environment = ["TERM_PROGRAM": termProgram]
        if tmux { environment["TMUX"] = "/tmp/bosun-test-tmux,1,0" }
        return try output(of: #"_bosun_busy_preexec "" "$BOSUN_TEST_COMMAND" """#, command: command,
                          environment: environment)
    }

    func testCommandStartRaisesBusy() throws {
        XCTAssertEqual(try preexec("make -j4"), busy)
    }

    func testPromptReturnsToIdle() throws {
        XCTAssertEqual(try output(of: "_bosun_busy_precmd", environment: ["TERM_PROGRAM": "ghostty"]), idle)
    }

    func testClaudeReportsItsOwnProgressUnderGhostty() throws {
        // #103 spike: Claude Code emits OSC 9;4 per turn when it sees ghostty. The shim must stay out of
        // the way, or the tab reads busy for Claude's whole lifetime.
        for command in ["claude", "claude --resume", "/opt/homebrew/bin/claude -p hi", "'claude' --model haiku"] {
            XCTAssertEqual(try preexec(command), "", command)
        }
    }

    func testClaudeOutsideGhosttyStillRaisesBusy() throws {
        // Without TERM_PROGRAM=ghostty Claude Code emits nothing, so the shim's whole-run busy is the
        // only signal left.
        XCTAssertEqual(try preexec("claude", termProgram: ""), busy)
    }

    func testSimilarNamesStillRaiseBusy() throws {
        XCTAssertEqual(try preexec("claudette"), busy)
    }

    func testInsideTmuxTheSignalIsWrappedForPassthrough() throws {
        // tmux sets its own TERM_PROGRAM, so Claude stays silent there and the shim reports for it.
        XCTAssertEqual(try preexec("claude", termProgram: "tmux", tmux: true), TmuxPassthrough.wrap(busy))
    }
}
