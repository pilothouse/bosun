# bosun

**Workbench** is a macOS console for working with GitHub and coding agents. It has a connection
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
`Workbench → Infrastructure → Application → Domain`. See [`CLAUDE.md`](CLAUDE.md) for the rules.

* `Sources/Domain/`: entities and pure rules (e.g. `DispatchPolicy`). Depends on nothing.
* `Sources/Application/`: use cases and the ports (protocols) they talk through.
* `Sources/Infrastructure/`: adapters that implement those ports (SSH, storage, …).
* `Sources/Workbench/`: the App layer — composition root plus the AppKit/Metal/libghostty UI.
  The only layer that links libghostty.
* `Sources/CGhostty/`: a small C layer that exposes the libghostty header to Swift.
* `Sources/Workbench/Ghostty/`: the libghostty bridge (`GhosttyApp`, `GhosttySurfaceView`).
* `Sources/Workbench/Views/`: the AppKit interface (titlebar, rail, detail, repo panel, terminal).
* `Sources/Workbench/{Theme,Model,Store}.swift`: themes, data models, and interface state.

## Build

The app is a SwiftPM package. Build the libghostty archive once, then run it:

```sh
bash scripts/build-libghostty.sh --check   # verify prerequisites only (fast); builds nothing
bash scripts/build-libghostty.sh           # creates Vendor/libghostty.a (several minutes)
swift run Workbench
```

The build needs **full Xcode** plus the **Metal Toolchain**, a component you download once with
`xcodebuild -downloadComponent MetalToolchain` (ghostty compiles its Metal shaders at build time).
Run `--check` first: it confirms the Metal toolchain can actually compile and reports what's
present, exiting non-zero with the exact fix if anything is missing.

Pinned versions: zig 0.15.2, ghostty v1.3.1, macOS 15.5 SDK (the macOS-26/zig workarounds and why
each is pinned are documented at the top of `scripts/build-libghostty.sh`). The script is
idempotent; everything it creates under `Vendor/` is kept out of git.
