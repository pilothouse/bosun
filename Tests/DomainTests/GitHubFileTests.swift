import XCTest
@testable import Domain

/// Contract tests for the changed-file value type and its effect on `GitHubItem` decoding. The
/// raw values are the on-disk/cache form, so they must stay stable; and an item written before the
/// `files` key existed must still decode (the cache decodes its whole snapshot in one pass, so a
/// single `keyNotFound` would wipe every cached row).
final class GitHubFileTests: XCTestCase {
    func testFileChangeRawValuesRoundTrip() {
        for change in [GitHubFileChange.added, .modified, .removed, .renamed, .copied, .changed] {
            XCTAssertEqual(GitHubFileChange(rawValue: change.rawValue), change)
        }
        // The on-disk vocabulary mirrors REST `status` — deletion is `removed`, not `deleted`.
        XCTAssertEqual(GitHubFileChange.removed.rawValue, "removed")
        XCTAssertNil(GitHubFileChange(rawValue: "deleted"))
    }

    func testItemRoundTripsFiles() throws {
        let item = Self.makeItem(files: [
            GitHubFile(path: "Sources/A.swift", additions: 10, deletions: 2, change: .modified),
            GitHubFile(path: "Sources/B.swift", additions: 0, deletions: 40, change: .removed),
        ])
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(GitHubItem.self, from: data)
        XCTAssertEqual(decoded, item)
        XCTAssertEqual(decoded.files?.map(\.path), ["Sources/A.swift", "Sources/B.swift"])
        XCTAssertEqual(decoded.files?.last?.change, .removed)
    }

    /// An old cache predates the `files` key. Simulate by encoding an item, stripping the key, and
    /// asserting it still decodes — with `files == nil` rather than throwing.
    func testItemDecodesWhenFilesKeyMissing() throws {
        let data = try JSONEncoder().encode(Self.makeItem(files: [
            GitHubFile(path: "x", additions: 1, deletions: 1, change: .added),
        ]))
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "files")
        let stripped = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(GitHubItem.self, from: stripped)
        XCTAssertNil(decoded.files)
    }

    private static func makeItem(files: [GitHubFile]?) -> GitHubItem {
        GitHubItem(id: "1", number: 1, kind: .pullRequest, title: "t", state: .open,
                   author: GitHubActor(login: "octocat"), createdAt: Date(timeIntervalSince1970: 0),
                   body: "", repositoryNameWithOwner: "o/r", files: files)
    }
}
