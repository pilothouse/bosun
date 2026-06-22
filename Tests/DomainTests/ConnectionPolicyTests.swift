import XCTest
@testable import Domain

/// Contract tests for the pure connection-validation rule. They describe what
/// `ConnectionPolicy` promises outward, not how it works inside. Don't edit a contract test
/// to make an implementation pass — if the contract is wrong, flag it.
final class ConnectionPolicyTests: XCTestCase {
    private func sshDraft(name: String = "prod", host: String = "10.0.2.11",
                          port: Int = 22, user: String? = nil) -> ConnectionDraft {
        ConnectionDraft(id: nil, name: name, kind: .ssh(host: host, port: port, user: user))
    }
    private func folderDraft(name: String = "api", path: String = "~/dev/api") -> ConnectionDraft {
        ConnectionDraft(id: nil, name: name, kind: .localFolder(path: path))
    }

    func testValidSSHHasNoErrors() {
        XCTAssertTrue(ConnectionPolicy.validate(sshDraft()).isEmpty)
    }

    func testValidFolderHasNoErrors() {
        XCTAssertTrue(ConnectionPolicy.validate(folderDraft()).isEmpty)
    }

    func testEmptyNameIsRejected() {
        XCTAssertEqual(ConnectionPolicy.validate(sshDraft(name: "   ")), [.emptyName])
    }

    func testEmptyHostIsRejected() {
        XCTAssertEqual(ConnectionPolicy.validate(sshDraft(host: "  ")), [.emptyHost])
    }

    func testPortBelowRangeIsRejected() {
        XCTAssertEqual(ConnectionPolicy.validate(sshDraft(port: 0)), [.invalidPort])
    }

    func testPortAboveRangeIsRejected() {
        XCTAssertEqual(ConnectionPolicy.validate(sshDraft(port: 70_000)), [.invalidPort])
    }

    func testEmptyPathIsRejected() {
        XCTAssertEqual(ConnectionPolicy.validate(folderDraft(path: "")), [.emptyPath])
    }

    func testMultipleErrorsAreReported() {
        let errors = ConnectionPolicy.validate(sshDraft(name: "", host: "", port: 0))
        XCTAssertEqual(Set(errors), [.emptyName, .emptyHost, .invalidPort])
    }
}
