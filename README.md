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

* `Sources/CGhostty/`: a small C layer that exposes the libghostty header to Swift.
* `Sources/Workbench/Ghostty/`: the libghostty bridge (`GhosttyApp`, `GhosttySurfaceView`).
* `Sources/Workbench/Views/`: the AppKit interface (titlebar, rail, detail, repo panel, terminal).
* `Sources/Workbench/{Theme,Model,Store}.swift`: themes, data models, and interface state.

## Build

The app is a SwiftPM package. Build the libghostty archive once, then run it:

```sh
bash scripts/build-libghostty.sh   # creates Vendor/libghostty.a (needs full Xcode and the Metal Toolchain)
swift run Workbench
```

The tools you need and the macOS SDK details are written at the top of
`scripts/build-libghostty.sh`. Everything it creates under `Vendor/` is kept out of git.
