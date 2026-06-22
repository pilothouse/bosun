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
}
