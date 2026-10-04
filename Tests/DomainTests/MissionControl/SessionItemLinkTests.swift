import XCTest
@testable import Domain

/// Contract tests for `SessionItemLink`: which issue/PR a terminal session is linked to.
final class SessionItemLinkTests: XCTestCase {

    private let items = [
        MissionItemRef(repo: "acme/api", number: 12),
        MissionItemRef(repo: "acme/web", number: 12),
        MissionItemRef(repo: "acme/web", number: 40),
    ]

    func testKeyJoinsRepoAndNumber() {
        XCTAssertEqual(MissionItemRef(repo: "acme/api", number: 7).key, "acme/api#7")
    }

    func testManualLinkWinsOverTitle() {
        XCTAssertEqual(SessionItemLink.resolve(manual: "acme/api#12", title: "fix #40", items: items), "acme/api#12")
    }

    func testBareNumberLinksWhenUnambiguous() {
        XCTAssertEqual(SessionItemLink.autoLink(title: "claude · fix #40", items: items), "acme/web#40")
    }

    func testBareNumberSharedByTwoReposLinksNothing() {
        XCTAssertNil(SessionItemLink.autoLink(title: "review #12", items: items))
    }

    func testQualifiedReferenceLinksExactRepo() {
        XCTAssertEqual(SessionItemLink.autoLink(title: "gh pr checkout acme/web#12", items: items), "acme/web#12")
    }

    func testQualifiedReferenceMatchesRepoCaseInsensitively() {
        XCTAssertEqual(SessionItemLink.autoLink(title: "Acme/API#12", items: items), "acme/api#12")
    }

    func testUnknownNumberLinksNothing() {
        XCTAssertNil(SessionItemLink.autoLink(title: "#999", items: items))
    }

    func testHashWithoutDigitsIsIgnored() {
        XCTAssertNil(SessionItemLink.autoLink(title: "# zsh", items: items))
    }

    func testFirstResolvableReferenceWins() {
        XCTAssertEqual(SessionItemLink.autoLink(title: "#12 then #40", items: items), "acme/web#40")
    }

    func testRepoOfKeyStripsTheNumber() {
        XCTAssertEqual(SessionItemLink.repo(ofKey: "acme/web#40"), "acme/web")
        XCTAssertNil(SessionItemLink.repo(ofKey: "acme/web"))
    }
}
