import Foundation

/// Pure rule for naming a duplicated connection (#101): `"<name> (copy)"`, numbered when that name
/// is already taken. Lives in Domain because it has `if`s — the rail's Duplicate action, a future
/// importer, and a migration would all otherwise grow their own copy of it, the way the folder
/// dedup loop in the App layer already did.
///
/// Names are *not* unique in Bosun (`ConnectionPolicy` only requires non-blank), so this is a
/// courtesy rather than a constraint: it keeps a rail full of copies readable.
public enum ConnectionNaming {
    /// The name for a copy of `name` that no entry in `existing` already uses. Pass every current
    /// connection name — including `name` itself; it is expected to be in there.
    public static func copyName(of name: String, existing: [String]) -> String {
        let base = baseName(of: name)
        let taken = Set(existing)
        var candidate = "\(base) (copy)"
        var attempt = 2
        while taken.contains(candidate) {
            candidate = "\(base) (copy \(attempt))"
            attempt += 1
        }
        return candidate
    }

    /// `name` with a trailing `" (copy)"` / `" (copy N)"` removed, so duplicating a copy numbers from
    /// the original (`x (copy)` → `x (copy 2)`) instead of stacking suffixes (`x (copy) (copy)`).
    ///
    /// Only a *trailing* marker counts — `"a (copy) b"` is a name the user chose, not a copy — and a
    /// name that would strip to nothing (`" (copy)"`) is left intact, since a connection needs a name.
    private static func baseName(of name: String) -> String {
        guard name.hasSuffix(")"),
              let marker = name.range(of: " (copy", options: .backwards) else { return name }

        let close = name.index(before: name.endIndex)
        guard marker.upperBound <= close else { return name }

        // "" for "(copy)", " 2" for "(copy 2)". Anything else ("(copy v2)") isn't ours to strip.
        let inner = name[marker.upperBound..<close]
        let isMarker = inner.isEmpty
            || (inner.first == " " && inner.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
                && inner.count > 1)
        guard isMarker else { return name }

        let base = String(name[name.startIndex..<marker.lowerBound])
        return base.trimmingCharacters(in: .whitespaces).isEmpty ? name : base
    }
}
