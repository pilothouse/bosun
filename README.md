# Bosun

**Bosun** is a macOS console for working with GitHub and coding agents. It has a connection
rail you can collapse, a pane that shows issues and pull requests, a tree of organizations and
repositories, themes you can switch between, and a terminal that stays open and can be resized.
The terminal is powered by real [libghostty](https://github.com/ghostty-org/ghostty) and drawn
with Metal.

## Features

* **Connection rail**: SSH remotes and local folders. You can collapse it to save space.
* **Detail pane**: shows an issue or pull request with its checks, tasks, and comments.
* **Repositories**: a tree of organizations and repositories with their pull requests and issues.
* **Themes**: Operator, Carbon, Nord, and Daylight.
* **Terminal**: built in, drawn with Metal, and resizable.

## Layout

The code is layered with Clean Architecture, and the boundaries are enforced by the build
itself — the compiler (SPM target graph) plus SwiftLint. Dependencies point inward:
`Bosun → Infrastructure → Application → Domain`.

* `Sources/Domain/`: entities and pure rules (e.g. `DispatchPolicy`). Depends on nothing.
* `Sources/Application/`: use cases and the ports (protocols) they talk through.
* `Sources/Infrastructure/`: adapters that implement those ports (SSH, storage, …).
* `Sources/Bosun/`: the App layer — composition root plus the AppKit/Metal/libghostty UI.
  The only layer that links libghostty.
* `Sources/CGhostty/`: a small C layer that exposes the libghostty header to Swift.
* `Sources/Bosun/Ghostty/`: the libghostty bridge (`GhosttyApp`, `GhosttySurfaceView`).
* `Sources/Bosun/Views/`: the AppKit interface (titlebar, rail, detail, repo panel, terminal).
* `Sources/Bosun/{Theme,Model,Store}.swift`: themes, data models, and interface state.

## Build

The app is a SwiftPM package. Build the libghostty archive once, then run it:

```sh
bash scripts/build-libghostty.sh --check   # verify prerequisites only (fast); builds nothing
bash scripts/build-libghostty.sh           # creates Vendor/libghostty.a (several minutes)
swift run Bosun
```

The build needs **full Xcode** plus the **Metal Toolchain**, a component you download once with
`xcodebuild -downloadComponent MetalToolchain` (ghostty compiles its Metal shaders at build time).
Run `--check` first: it confirms the Metal toolchain can actually compile and reports what's
present, exiting non-zero with the exact fix if anything is missing.

### Testing the UI offline

`swift test` runs the contract tests (Domain/Application/Infrastructure). To exercise the *running*
app without signing in — and without the Keychain password dialog that a rebuild otherwise triggers —
launch it in UI-test mode, which seeds deterministic GitHub data and connections fully offline:

```sh
BOSUN_UI_TEST=1 swift run Bosun
```

See [`docs/ui-testing.md`](docs/ui-testing.md) for what it seeds and how it relates to the perf and
API-smoke flags.

Pinned versions: zig 0.15.2, ghostty v1.3.1, macOS 15.5 SDK (the macOS-26/zig workarounds and why
each is pinned are documented at the top of `scripts/build-libghostty.sh`). The script is
idempotent; everything it creates under `Vendor/` is kept out of git.

## Run a build without building (pre-v1)

Until v1 there's no release, but every successful CI run on `master` produces a ready-to-run
`Bosun.dmg`. To get it: open the repo's **Actions** tab → the latest **CI** run → the **Bosun-dmg**
artifact (you'll need to be signed in to GitHub). Unzip it, open the `.dmg`, and drag **Bosun** to
Applications.

When **Developer ID signing + notarization secrets** are configured (see
[`docs/signing.md`](docs/signing.md)), the CI build is signed, notarized, and stapled, and opens
with no Gatekeeper workaround. Without those secrets the build is **ad-hoc signed, not notarized**
(still hardened-runtime), so on first launch Gatekeeper says it "cannot be opened". Clear it once —
right-click the app → **Open**, or:

```sh
xattr -dr com.apple.quarantine /Applications/Bosun.app
```

It's a single-architecture build for the CI runner's arch (Apple Silicon / arm64). You can produce
the same bundle locally from a release build with `bash scripts/package-app.sh` (writes
`dist/Bosun.dmg`); set `SIGN_IDENTITY` + notary credentials to get a notarized one — see
[`docs/signing.md`](docs/signing.md).
