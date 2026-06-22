import Foundation

/// Pure rule for GitHub's REST pagination, which advertises the next page in the `Link`
/// response header (RFC 8288). No network — the adapter fetches a page, hands the header here,
/// and follows whatever URL comes back until there isn't one. Scanning `<url>; rel="..."`
/// pairs (rather than splitting on commas) keeps URLs that themselves contain commas intact.
public enum GitHubPagination {
    /// The `rel="next"` URL, or nil when the header is absent, has no next link, or is malformed.
    public static func nextPageURL(fromLinkHeader header: String?) -> URL? {
        guard let header, !header.isEmpty else { return nil }
        let pattern = #"<([^>]+)>\s*;\s*rel="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let whole = NSRange(header.startIndex..., in: header)
        for match in regex.matches(in: header, range: whole) {
            guard let relRange = Range(match.range(at: 2), in: header),
                  header[relRange] == "next",
                  let urlRange = Range(match.range(at: 1), in: header) else { continue }
            return URL(string: String(header[urlRange]))
        }
        return nil
    }
}
