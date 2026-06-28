# What is Bosun, and why?

> The [README](README.md) covers what Bosun does and how to build it; the
> [CLAUDE.md](CLAUDE.md) covers the architecture rules. This document covers the *why* —
> the problem Bosun is trying to solve and the reasoning behind how it's built.

## What Bosun is

Bosun is a native macOS console for working with GitHub and coding agents. It puts a real
terminal, your GitHub issues and pull requests, and the machinery for dispatching coding-agent
runs into a single window: a collapsible connection rail down the left, a tree of organizations
and repositories, a detail pane that renders an issue or PR, and a terminal — powered by real
[libghostty](https://github.com/ghostty-org/ghostty) and drawn with Metal — that stays open
underneath it all.

It is one window where you can see what you're connected to, see what needs work, read the
issue or PR, and run the commands — without leaving for a separate terminal app or a browser tab.

## The problem it solves

A normal day of development is spread across at least three apps. You keep a terminal open for
local shells and SSH into remote machines. You keep the GitHub web UI open to triage issues,
review pull requests, and read CI checks. You keep an editor open for the code. Now there's a
fourth surface: coding agents that you point at a repo, kick off, and then have to babysit —
which run is queued, which is running, which one failed and why.

Each of those is its own window, its own context, its own set of tabs. The cost isn't any single
switch; it's that the switches never stop, and the state you care about is scattered across them.

Bosun collapses the loop — *connect → see what needs work → read the issue or PR → run the
commands → watch the agent* — into one place you can take in at a glance. The terminal doesn't
go away when you look at a pull request; the pull request doesn't go away when you type a command.

## Who it's for

Developers who live in a terminal and on GitHub. People who routinely juggle local shells and
SSH remotes, who manage real work across organizations and repositories, and who are
increasingly driving coding agents against those repos rather than typing every change by hand.
It assumes you want an authentic terminal — colors, escape sequences, signals, real performance —
not a cut-down web emulation.

## What it does today

**Terminal.** A built-in terminal backed by real libghostty and rendered with Metal. It's
resizable, supports tabs whose state persists across launches
(`Sources/Domain/TerminalTabs.swift`, `TerminalTabState.swift`), and can be split alongside the
detail pane on either axis — terminal top/bottom or left/right
(`SplitAxis.swift`, `SplitLayout.swift`).

**Connections.** SSH remotes and local folders are first-class
(`Sources/Domain/Connection.swift`). You can organize them into one level of user-defined folders
(`Folder.swift`), mark favorites, reorder them by drag, and — opt-in — sync them across your Macs
via iCloud (`ConnectionSync.swift`, with the merge implemented as a pure domain rule). SSH
connections can carry a custom post-connect command (`SSHCommand.swift`).

**GitHub.** A live tree of organizations and repositories with their issues and pull requests.
The detail pane shows an issue or PR with its checks, comments, and file changes, and renders
Markdown bodies via [swift-markdown](https://github.com/apple/swift-markdown). You can filter by
state, sort and group items (`ItemSorting.swift`, `ConnectionGrouping.swift`), order repos by name
or by how busy they are (`RepoOrdering.swift`), follow specific orgs (`OrgFollowing.swift`), and
hide repos with nothing open.

**The interface itself.** Four built-in themes (Operator, Carbon, Nord, Daylight), contextual
zoom from 50–200% (`UIZoom.swift`), and a layout that remembers its state — split axis, terminal
position, collapsed rails, window geometry — between launches (`Preferences.swift`).

## The coding-agent model

The "and coding agents" half of the tagline is a real model in the domain, not a label. A unit of
work is an `AgentRun` — a prompt aimed at a repository, moving through a small state machine of
`queued → running → succeeded → failed(reason:)` (`Sources/Domain/AgentRun.swift`). Repositories
are addressed through a forge-agnostic `RepoRef`, and the `Forge` type already distinguishes
GitHub, Gitea, and Forgejo at the type level — even though the live forge integration today is
GitHub.

Dispatch is governed by one rule. `DispatchPolicy.canDispatch`
(`Sources/Domain/DispatchPolicy.swift`) says a run may start only if it's still queued, its repo
isn't paused, and its organization is under its concurrency budget. `DispatchAgentUseCase`
(`Sources/Application/DispatchAgentUseCase.swift`) is the use case that consults that policy,
starts the run through a `runner` port, persists it, and emits an event — orchestrating exactly
three collaborators, no more. The point of pulling the budget-and-pause decision into a pure
function is that every caller — a menu-bar action, a scheduled sweep, a test — asks the *same*
question and gets the *same* answer.

## Why it's built this way

Bosun's architecture is Clean Architecture, but the boundaries aren't a convention you're trusted
to respect — they're enforced by the build. Dependencies point strictly inward:

```
Bosun → Infrastructure → Application → Domain
```

`Domain` (entities and pure rules) declares `dependencies: []` in `Package.swift`, so it
*physically cannot* import another layer — `import Application` inside Domain doesn't compile, no
linter required. A SwiftLint plugin runs on the inner layers to catch the thing the compiler
can't see: always-importable system frameworks like AppKit, Metal, or Network leaking into Domain
or Application. The app layer (`Sources/Bosun`) is the one unconstrained place that's allowed to
import everything and is the only target that links libghostty.

The reason this is worth the friction is a real failure. As recorded in `CLAUDE.md`: an agent once
put the "can this run dispatch?" check inside the menu-bar action handler. When a scheduled sweep
later needed the same check, the rule was copied — and within a week the two copies had drifted.
The fix was to make the rule a pure function in Domain (`DispatchPolicy.canDispatch`) that both
callers share. The principle that fell out of it: **if a rule has an `if`, it belongs in Domain.**

The same seam pays off in testing. Because use cases reach the outside world only through *ports*
(protocols defined in `Application` and implemented by adapters in `Infrastructure`), a use case
can run against a fake store or a stubbed SSH runner in a unit test instead of a live connection.

None of this is dogma. There's an explicit *light path*: a change that carries no business rule —
a new settings field threaded through to storage — goes where it lands, no port, no three-layer
ceremony. The full layering is reserved for code that has rules and will be changed for months.

## Why these technologies

- **Real libghostty + Metal** — an authentic terminal, GPU-drawn, rather than a web-terminal
  emulation. The whole product premise is that the terminal is a first-class citizen, not a
  widget.
- **Native AppKit** (not Catalyst) — a real Mac app that behaves like one.
- **SwiftPM as the architecture** — the package's target graph *is* the boundary enforcement.
  The build system and the architecture diagram are the same artifact, so they can't fall out
  of sync.
- **swift-markdown** — GitHub-flavored Markdown rendering for issue, PR, and comment bodies, so
  the detail pane reads the way the web UI does.

## Performance & memory

RAM is the scarce resource of the AI era. A developer's machine now runs local models, agent
toolchains, language servers, and containers at the same time — each measured in gigabytes. A tool
that sits in the corner all day has no business taking a slice of that. So this isn't a vibe claim;
it's measured.

**How it was measured.** `scripts/perf-sim.sh` loads a *release* build with heavy synthetic data
across the three dimensions that actually cost memory — open consoles, saved connections/folders,
and cached GitHub orgs/repos/issues/PRs — and reads the real `Physical footprint (peak)` from
`vmmap`. The numbers below are from that script on **macOS 26.5 (Apple Silicon, arm64)**, stable to
~2% across runs. Avatars are disabled in the simulation, so these figures exclude the bounded,
≤200-image avatar cache (`AvatarLoader`) — they're the data-and-surface floor. Reproduce any row:

```sh
swift build -c release --disable-sandbox
bash scripts/perf-sim.sh baseline t1 t2 t3        # tiers
bash scripts/perf-sim.sh connections-only github-only consoles-only   # isolation runs
```

**What it costs.** `footprint` is Bosun's own process (Activity Monitor's "Memory"); each console
also forks a `login`+`zsh` shell, which are separate PIDs, reported separately.

| Scenario | consoles | connections | GitHub (orgs×repos / cached items) | Bosun footprint (peak) | console shells |
|---|---:|---:|---|---:|---:|
| **Baseline** | 1 | 0 | — | **148 MB** (150) | 1 → 15 MB |
| **Realistic** | 6 | 150 / 15 folders | 15×25 / ~5k | **333 MB** (339) | 6 → 90 MB |
| **Heavy** | 12 | 400 / 30 folders | 30×40 / ~18k | **538 MB** (580) | 12 → 181 MB |
| **Extreme** | 24 | 1000 / 50 folders | 50×40 / ~45k | **933 MB** (1.1 GB) | 24 → 363 MB |

Isolating one dimension at a time (Δ vs. the 148 MB baseline) shows where the memory goes:

- **Each open console ≈ 28 MB** of Bosun's own memory (24 consoles, no data → ~780 MB), plus a
  ~15 MB `login`+`zsh` process. That's the honest price of a *real* GPU-drawn terminal with its own
  scrollback — and it's linear, predictable, and freed on close (`ghostty_surface_free`). Inactive
  tabs stay live, so this is a true peak, not a lazy undercount.
- **1000 connections in 50 folders ≈ +110 MB** — but the connection *data* is well under a
  megabyte (value-type rows); the cost is AppKit rendering a thousand rail rows. A thousand saved
  connections is far past any real use.
- **An extreme GitHub cache ≈ +122 MB** — a 2000-repo tree plus a 45,000-item cache mirror held
  fully resident. Normal use caches items only for the repos you actually open, so this is an upper
  bound, not a typical load.

**The takeaway.** Realistic use — a few real terminals and ordinary amounts of data — lives in the
low-to-mid hundreds of megabytes. The dominant cost is *open consoles*, because they're genuine
GPU terminals rather than web views; everything else is secondary, and the curve is linear and
freed on demand. Even pushed to a deliberately absurd configuration (24 terminals, a thousand
connections, forty-five thousand cached items) it tops out near a gigabyte.

For comparison — these are well-known industry ballparks, *not* benchmarks run here — Electron-based
developer tools commonly idle in the 300 MB–1 GB range, and a single web-terminal tab is often
100 MB+ on its own. A native AppKit app whose marginal cost is ~28 MB for a *real* terminal is lean
by that standard. The reasons are structural, not luck: native AppKit instead of a bundled browser
engine, value-type models (`Connection`, `GitHubItem`, `Preferences` are all `struct`s — no
per-object class overhead, copied not retained), one shared `GhosttyApp` across every surface, and
caches with hard ceilings (`AvatarLoader` evicts past 200 images; the GitHub cache mirrors only
what you've browsed). Lean by construction leaves the gigabytes for the AI workloads that now share
your machine.

## In one line

One window — a real terminal, your GitHub work, and the coding agents you point at it — built so
that the rules can't drift, because the build won't let them.
