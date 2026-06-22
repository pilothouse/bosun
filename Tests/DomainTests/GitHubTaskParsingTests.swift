import XCTest
@testable import Domain

/// Contract tests for the pure task-list rule: extract GitHub-flavored markdown checkboxes
/// (`- [ ]` / `- [x]`) from an issue or PR body. Prose, headings, and plain bullets are not
/// tasks and must be ignored, preserving document order for the ones that are.
final class GitHubTaskParsingTests: XCTestCase {
    func testParsesUncheckedAndCheckedInOrder() {
        let body = """
        - [ ] write the port
        - [x] write the adapter
        - [X] capital X also counts
        """
        XCTAssertEqual(GitHubTask.parse(markdownBody: body), [
            GitHubTask(title: "write the port", isDone: false),
            GitHubTask(title: "write the adapter", isDone: true),
            GitHubTask(title: "capital X also counts", isDone: true),
        ])
    }

    func testIgnoresProseHeadingsAndPlainBullets() {
        let body = """
        ## Plan
        Some intro text.
        - a plain bullet, not a task
        - [ ] the only real task
        more prose
        """
        XCTAssertEqual(GitHubTask.parse(markdownBody: body),
                       [GitHubTask(title: "the only real task", isDone: false)])
    }

    func testAcceptsAsteriskBulletsAndLeadingIndentation() {
        let body = "  * [x] indented asterisk task"
        XCTAssertEqual(GitHubTask.parse(markdownBody: body),
                       [GitHubTask(title: "indented asterisk task", isDone: true)])
    }

    func testReturnsEmptyWhenNoTasks() {
        XCTAssertEqual(GitHubTask.parse(markdownBody: "just a description, no checkboxes"), [])
        XCTAssertEqual(GitHubTask.parse(markdownBody: ""), [])
    }
}
