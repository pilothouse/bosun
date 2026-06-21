# bosun — architecture rules for agents

You're in a Swift + AppKit app with Clean Architecture enforced by the compiler
(SPM targets) and SwiftLint. The build fails if you cross a boundary, so read the
map before adding code.

## The map: where code goes
- `Sources/Domain` — entities and pure rules. No AppKit, no I/O, no other layer.
  Functions here run from the menu bar, a CLI sweep, or a test with zero setup.
  Has `dependencies: []` in `Package.swift` — it literally cannot import another layer.
- `Sources/Application` — use cases. They orchestrate Domain and reach the outside
  world only through *ports* (protocols) defined here. Max 3 collaborators per use case.
- `Sources/Infrastructure` — adapters. SSH, SQLite, Git-forge clients, libghostty
  bridges. Implements the ports from Application.
- `Sources/Workbench` — the App layer: composition root + AppKit/Metal/libghostty views.
  The only place allowed to import every layer (and the only place that links libghostty).
  Views stay thin: read input, call a use case, render.

## How the boundaries are enforced
- **Direction is the compiler's job.** A target only sees the modules in its
  `dependencies:`. `Domain` depends on nothing, so `import Application` in Domain doesn't
  compile — no linter needed.
- **Purity is SwiftLint's job.** System frameworks (`AppKit`, `Metal`, `Network`, `SQLite`,
  …) are always importable, so the compiler can't stop them. The SwiftLint plugin runs on
  Domain/Application at build time and fails the build if one leaks in (`.swiftlint.yml`).
- The plugin is intentionally *not* attached to `Sources/Workbench` — it's the unconstrained
  composition layer, and linting the dense AppKit views would only police style. Run
  `swiftlint` (CLI) over the whole tree if you want the `no_io_in_views` rule checked there too.

## Where logic lives
Business rules live in `Domain` as plain functions with no dependencies.
Why: an agent once put the "can this run dispatch?" check inside the menu-bar action
handler. When the scheduled sweep later needed the same check, the rule got copied,
and the two copies drifted within a week. Now `DispatchPolicy.canDispatch` lives in
Domain and both callers share it. If a rule has an `if`, it belongs in Domain.

## Reaching the outside world
Need SSH, a database, or a forge API? Define a protocol (a port) in `Application`,
implement it in `Infrastructure`, and wire the concrete type in
`Sources/Workbench/CompositionRoot.swift`.
Why: that seam is what lets a use case run against a fake in a unit test instead of a
live SSH connection (see `Tests/ApplicationTests`). An `import Network` in Application or
Domain fails the build on purpose.

## The light path (skip the ceremony)
If a change carries no business rule — a new field in a settings pane threaded through
to storage — you do NOT need three layers and a port. Put it where it lands and move on.
Three files for one field is ceremony, not architecture. The full layering is for code
that has rules and will be changed for months.

## Public surface
A module's `public` symbols are its contract. Keep that surface small; default to
`internal`. Needing a new `public` function is a deliberate contract change — make it
visible in review, don't widen the surface to dodge a boundary.

## Tests
Contract tests cover each module's public API: what it promises outward, not how it
works inside. A human writes/reviews these. Don't edit a contract test to make your
implementation pass, if the contract is wrong then flag it.

## Scaling note
Layer-first (above) is right for now. Once you pass ~5 features, graduate to
feature-first: a `FeatureDispatch` package whose target exposes a small `public` surface
and hides `Domain/Application/Infrastructure` as internal folders, with cross-feature
access only through that public API.
