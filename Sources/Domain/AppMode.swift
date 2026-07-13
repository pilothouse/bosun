import Foundation

/// The one mutually-exclusive launch mode the app runs in, decided once from the process
/// environment. Splitting this out of the composition root is deliberate: "which `BOSUN_*` flag
/// wins" is a rule with an `if`, and the codebase keeps rules in Domain so the menu bar, a test,
/// and the perf script all read the same answer instead of each re-parsing the environment.
///
/// - `normal`   — the shipping path: Keychain token, live GitHub client, on-disk cache.
/// - `uiTest`   — offline UI verification: an in-memory token (so the Keychain ACL dialog never
///                fires), a seeded fake GitHub client, and seeded connections. The canonical
///                replacement for the old per-feature `BOSUN_UI_DEMO`/`BOSUN_*` seams.
/// - `perfSeed` — memory profiling (`scripts/perf-sim.sh`): skip the live fetch and hold a heavy
///                on-disk cache resident. Also Keychain-safe, via the same in-memory token.
public enum AppMode: Sendable, Equatable {
    case normal
    case uiTest
    case perfSeed

    /// Resolve the mode from an environment dictionary. Precedence is `uiTest` > `perfSeed` >
    /// `normal`, and only the exact string `"1"` enables a mode — a present-but-empty or otherwise
    /// non-`"1"` value is treated as absent so a stray export can't silently fake the app's data.
    /// `BOSUN_API_SMOKE` (a live-probe boolean) is intentionally not a mode here — it runs alongside
    /// the normal signed-in path and is handled separately.
    public static func resolve(environment: [String: String]) -> AppMode {
        if environment["BOSUN_UI_TEST"] == "1" { return .uiTest }
        if environment["BOSUN_PERF_SEED"] == "1" { return .perfSeed }
        return .normal
    }
}
