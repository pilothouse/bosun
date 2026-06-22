import Foundation

/// A single GitHub-flavored markdown checkbox lifted out of an issue/PR body, plus the pure
/// rule that finds them. The presentation layer renders these as the task list; the rule lives
/// here because "is this line a task, and is it done?" is exactly the kind of `if` Domain owns.
public struct GitHubTask: Sendable, Equatable {
    public let title: String
    public let isDone: Bool

    public init(title: String, isDone: Bool) {
        self.title = title
        self.isDone = isDone
    }

    /// Extract `- [ ]` / `- [x]` (or `*` bulleted) checkbox lines from a markdown body, in
    /// document order. Indentation is tolerated; non-checkbox lines are skipped.
    public static func parse(markdownBody body: String) -> [GitHubTask] {
        body.components(separatedBy: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let bullet = line.first, bullet == "-" || bullet == "*" else { return nil }

            let afterBullet = line.dropFirst().trimmingCharacters(in: .whitespaces)
            let marker = Array(afterBullet.prefix(3))
            guard marker.count == 3, marker[0] == "[", marker[2] == "]" else { return nil }

            let isDone: Bool
            switch marker[1] {
            case " ": isDone = false
            case "x", "X": isDone = true
            default: return nil   // `[*]`, `[-]`, … aren't checkboxes
            }
            let title = afterBullet.dropFirst(3).trimmingCharacters(in: .whitespaces)
            return GitHubTask(title: String(title), isDone: isDone)
        }
    }
}
