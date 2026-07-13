import XCTest
@testable import Domain

/// Contract tests for the pure SSH command builder. They describe what `SSHCommand` promises
/// outward, not how it works inside. Don't edit a contract test to make an implementation pass —
/// if the contract is wrong, flag it.
final class SSHCommandTests: XCTestCase {
    func testUserAndDefaultPort() {
        XCTAssertEqual(SSHCommand.command(host: "100.87.92.76", port: 22, user: "ubuntu"),
                       "ssh ubuntu@100.87.92.76")
    }

    func testNoUserOmitsAtSign() {
        XCTAssertEqual(SSHCommand.command(host: "gpu.ts.net", port: 22, user: nil),
                       "ssh gpu.ts.net")
    }

    func testEmptyUserTreatedAsNoUser() {
        XCTAssertEqual(SSHCommand.command(host: "gpu.ts.net", port: 22, user: "   "),
                       "ssh gpu.ts.net")
    }

    func testNonDefaultPortAddsFlag() {
        XCTAssertEqual(SSHCommand.command(host: "10.0.2.11", port: 2222, user: "root"),
                       "ssh -p 2222 root@10.0.2.11")
    }

    func testCustomCommandIsFoldedInWithPty() {
        XCTAssertEqual(SSHCommand.command(host: "host", port: 22, user: "u", custom: "tmux new -n dev"),
                       "ssh u@host -t 'tmux new -n dev'")
    }

    func testCustomCommandWithNonDefaultPort() {
        XCTAssertEqual(SSHCommand.command(host: "10.0.2.11", port: 2222, user: "root", custom: "tmux a"),
                       "ssh -p 2222 root@10.0.2.11 -t 'tmux a'")
    }

    func testBlankCustomCommandLeavesBaseUnchanged() {
        XCTAssertEqual(SSHCommand.command(host: "gpu.ts.net", port: 22, user: nil, custom: "   "),
                       "ssh gpu.ts.net")
    }

    func testNilCustomCommandLeavesBaseUnchanged() {
        XCTAssertEqual(SSHCommand.command(host: "gpu.ts.net", port: 22, user: nil, custom: nil),
                       "ssh gpu.ts.net")
    }

    func testCustomCommandWithSingleQuoteIsPosixEscaped() {
        XCTAssertEqual(SSHCommand.command(host: "host", port: 22, user: "u", custom: "echo it's"),
                       "ssh u@host -t 'echo it'\\''s'")
    }

    // MARK: - Busy-spinner integration (#96). `busyShim` defaults to nil, so the cases above are
    // unaffected; these pin the tmux-only rewrite.

    // base64 of "hi" is "aGk=" — a stand-in shim keeps the expected string legible.
    func testBusyShimRewritesTmuxWithPassthroughAndRemoteZdotdir() {
        XCTAssertEqual(
            SSHCommand.command(host: "host", port: 22, user: "u", custom: "tmux new -n dev", busyShim: "hi"),
            "ssh u@host -t 'export ZDOTDIR=\"$(mktemp -d)\"; printf %s aGk= | "
            + "openssl base64 -d -A > \"$ZDOTDIR/.zshenv\"; "
            + "exec tmux set -g allow-passthrough on \\; new -n dev'")
    }

    func testBusyShimBareTmuxBecomesNewSession() {
        XCTAssertEqual(
            SSHCommand.command(host: "host", port: 22, user: "u", custom: "tmux", busyShim: "hi"),
            "ssh u@host -t 'export ZDOTDIR=\"$(mktemp -d)\"; printf %s aGk= | "
            + "openssl base64 -d -A > \"$ZDOTDIR/.zshenv\"; "
            + "exec tmux set -g allow-passthrough on \\; new-session'")
    }

    func testBusyShimLeavesNonTmuxCommandUnchanged() {
        // The rewrite is tmux-specific; a plain remote program is not touched.
        XCTAssertEqual(SSHCommand.command(host: "host", port: 22, user: "u", custom: "htop", busyShim: "hi"),
                       "ssh u@host -t 'htop'")
    }

    func testNilBusyShimLeavesTmuxCommandUnchanged() {
        // Default (no integration) is byte-identical to the plain custom-command contract.
        XCTAssertEqual(SSHCommand.command(host: "host", port: 22, user: "u", custom: "tmux new -n dev"),
                       "ssh u@host -t 'tmux new -n dev'")
        XCTAssertEqual(
            SSHCommand.command(host: "host", port: 22, user: "u", custom: "tmux new -n dev", busyShim: nil),
            "ssh u@host -t 'tmux new -n dev'")
    }

    func testBusyShimWithSingleQuotesDoesNotLeakIntoPayload() {
        // A real shim contains single quotes (zsh `$'\e…'`); base64 must keep them out of the
        // remote payload so the outer single-quote wrapping stays trivial (exactly two quotes).
        let shim = "print -rn -- $'\\e]9;4;3\\e\\\\'"
        let out = SSHCommand.command(host: "h", port: 22, user: "u", custom: "tmux", busyShim: shim)
        XCTAssertEqual(out.filter { $0 == "'" }.count, 2)
    }
}
