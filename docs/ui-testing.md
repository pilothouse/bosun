# UI-test mode (`BOSUN_UI_TEST`)

Bosun reads its GitHub OAuth token from the macOS Keychain at launch
(`AppDelegate.restoreState` → `auth.restore()` → `KeychainTokenStore.load()`). After a rebuild the
binary's Keychain ACL is invalidated, so macOS pops a **blocking "allow access" password dialog**
that steals focus and freezes any scripted click or keystroke until a human dismisses it. That OAuth
token is the *only* blocking secret — SSH auth is delegated to `ssh-agent`, so there is nothing else
to mock.

`BOSUN_UI_TEST=1` is the one, documented way past this. It is the canonical replacement for the
scattered, per-feature seams that used to be reinvented for each verification (`BOSUN_UI_DEMO` and
friends). Set it and the app launches **fully offline**: signed-in, populated, and interactive, with
the Keychain never touched.

```sh
swift build --disable-sandbox
BOSUN_UI_TEST=1 swift run Bosun          # or: BOSUN_UI_TEST=1 .build/debug/Bosun
```

## What the flag does

The mode is resolved once from the environment by the pure `Domain/AppMode.swift` rule and consumed
only in the composition root (`Sources/Bosun/CompositionRoot.swift`) — no view or use-case code
changes. In `.uiTest` mode `CompositionRoot` swaps three adapters:

| Port | Normal adapter | `.uiTest` adapter |
| --- | --- | --- |
| `GitHubTokenStore` | `KeychainTokenStore` | `StaticTokenStore` (fixed non-empty token → `auth.restore()` reports signed-in; the Keychain is **never read**) |
| `GitHubAPI` | `GitHubAPIClient` (live) | `FakeGitHubAPI` — stateful, in-memory, seeded from fixtures |
| `GitHubCacheStore` | `JSONFileGitHubCacheStore` | `InMemoryGitHubCacheStore` — pre-seeded from the same fixtures |
| `ConnectionStore` | `JSONFileConnectionStore` (+ iCloud) | `InMemoryConnectionStore` — sample rows, never touches your real `connections.json` |

Because the token store returns a token, the normal launch path (`auth.restore()` →
`onSignedIn` → `GitHubDataController.load()`) runs unchanged against the fake API and seeded cache —
so the orgs/repos tree, the issue/PR list, and the detail pane all render from fixtures with no
network and no dialog.

The fake is **stateful**, so real write actions work offline and the panel updates as it would
against github.com: posting a comment, merging/closing a PR, closing an issue, editing
title/body/labels/assignees, and requesting/removing reviewers all mutate the in-memory item and
return the updated value.

## The seed data

Defined once in `Sources/Bosun/UITestSupport.swift` (`UITestFixtures`), deterministic and
clock-free (avatar URLs are nil, so chips render from initials with no remote fetch):

- **Viewer:** `maya` (Maya Ono).
- **Orgs / repos:** `acme` (`acme/web`, `acme/api`), `octo-labs` (`octo-labs/infra`), plus the
  personal repo `maya/dotfiles`.
- **Items:** a handful of open/closed issues and PRs across those repos, exercising labels with
  colors, assignees, a draft PR, CI checks, a PR comment, a blocked-by pair (`acme/web#103` blocked
  by `#101`), and a merged/closed history item.
- **Connections:** three sample connections (two SSH, one local folder) grouped under a "Work"
  folder.

## Relationship to the other `BOSUN_*` flags

| Flag | Mode | Purpose |
| --- | --- | --- |
| `BOSUN_UI_TEST=1` | `AppMode.uiTest` | Offline UI verification. Keychain-safe. **Use this for UI/UX testing.** |
| `BOSUN_PERF_SEED=1` | `AppMode.perfSeed` | Memory profiling (`scripts/perf-sim.sh`): hold a heavy on-disk cache resident with no live fetch. Now Keychain-safe via the same in-memory token. |
| `BOSUN_API_SMOKE=1` (+ `BOSUN_GITHUB_TOKEN`) | *not a mode* | Dev-only **live** probe of the real GitHub API (the opposite of offline). Runs alongside the normal signed-in path. |

`BOSUN_UI_TEST` and `BOSUN_PERF_SEED` are the two mutually-exclusive offline modes resolved by
`AppMode.resolve` (UI-test wins if both are set). `BOSUN_API_SMOKE` is orthogonal — it hits the
network and does not change the resolved mode.

Before inventing a new `BOSUN_*` hook for a verification, extend the `UITestFixtures` seed or the
`FakeGitHubAPI` instead — that keeps every verification on the one documented mode.

## Driving real UI actions

See [`Tests/UITests/README.md`](../Tests/UITests/README.md) for the XCUITest harness that launches
the packaged app with this flag and drives real actions, plus the scripted-AX fallback used in
CI/headless contexts.
