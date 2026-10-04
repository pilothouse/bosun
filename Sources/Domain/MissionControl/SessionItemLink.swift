import Foundation

/// An issue/PR a session can link to. `key` is `owner/name#number`; `repo` is `owner/name`.
public struct MissionItemRef: Sendable, Equatable {
    public let repo: String
    public let number: Int

    public init(repo: String, number: Int) {
        self.repo = repo
        self.number = number
    }

    public var key: String { "\(repo)#\(number)" }
}

/// Links a terminal session to the issue/PR it works on. A manual link (the user attached the
/// session) always wins; otherwise the tab title is scanned for `owner/name#123` (exact) or a bare
/// `#123` (only when exactly one known item has that number — ambiguity links nothing).
public enum SessionItemLink {

    public static func resolve(manual: String?, title: String, items: [MissionItemRef]) -> String? {
        if let manual { return manual }
        return autoLink(title: title, items: items)
    }

    /// The `owner/name` part of an item key (`owner/name#123`), or nil when the key has no `#`.
    public static func repo(ofKey key: String) -> String? {
        guard let hash = key.lastIndex(of: "#"), hash > key.startIndex else { return nil }
        return String(key[..<hash])
    }

    public static func autoLink(title: String, items: [MissionItemRef]) -> String? {
        for ref in references(in: title) {
            if let repo = ref.repo {
                if let hit = items.first(where: { $0.repo.caseInsensitiveCompare(repo) == .orderedSame
                                                  && $0.number == ref.number }) {
                    return hit.key
                }
                continue
            }
            let hits = items.filter { $0.number == ref.number }
            if hits.count == 1 { return hits[0].key }
        }
        return nil
    }

    /// Every `#<digits>` in `title`, with the `owner/name` immediately before it when present.
    static func references(in title: String) -> [(repo: String?, number: Int)] {
        let chars = Array(title)
        var found: [(repo: String?, number: Int)] = []
        var index = 0
        while index < chars.count {
            guard chars[index] == "#" else { index += 1; continue }
            var end = index + 1
            while end < chars.count, chars[end].isASCII, chars[end].isNumber { end += 1 }
            guard end > index + 1, let number = Int(String(chars[(index + 1)..<end])) else {
                index += 1
                continue
            }
            found.append((repoPrefix(chars, before: index), number))
            index = end
        }
        return found
    }

    /// The `owner/name` token ending right before `hashIndex`, or nil when there isn't one.
    private static func repoPrefix(_ chars: [Character], before hashIndex: Int) -> String? {
        var start = hashIndex
        while start > 0, isRepoChar(chars[start - 1]) { start -= 1 }
        let token = String(chars[start..<hashIndex])
        let parts = token.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return token
    }

    private static func isRepoChar(_ char: Character) -> Bool {
        char.isASCII && (char.isLetter || char.isNumber || char == "-" || char == "_" || char == "." || char == "/")
    }
}
