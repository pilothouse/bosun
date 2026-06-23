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
}
