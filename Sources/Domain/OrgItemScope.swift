/// Pure rule for the aggregate org view: given a repo's open-work count and whether the active
/// status filter is open-only, decide whether the repo is worth fetching. With the default
/// open-only filter, a repo with `open == 0` contributes nothing, so it's skipped; once the filter
/// widens to closed/merged the open count says nothing about history and every repo is fetched.
/// Lives here — not in the data controller — so the fetch scope is one shared, testable definition.
public enum OrgItemScope {
    public static func includesRepo(open: Int, openOnly: Bool) -> Bool {
        openOnly ? open > 0 : true
    }
}
