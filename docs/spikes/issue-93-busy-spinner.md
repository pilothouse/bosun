# Spike #93 — busy/activity spinner on a console tab

**Status:** investigated + prototyped (behind an opt-in setting). Recommendation below.
**Date:** 2026-06-29

## TL;DR recommendation

Ship a **best-effort, opt-in busy spinner driven by `PROGRESS_REPORT` (OSC 9;4)**, with
`COMMAND_FINISHED` (shell integration) as the stop safety-net — exactly the prototype now in the
tree, gated by a default-off `terminalBusySpinner` setting. Do **not** try to infer "busy" from
generic output: libghostty exposes no such signal, and the explicit signals do not cover the
motivating case (Claude Code writing). Keep it opt-in and honest about coverage rather than
promising a "spinner whenever the tab is working" it can't deliver.

## The investigation: what signals libghostty actually gives us

Scanning the action enum (`Sources/CGhostty/include/ghostty.h`, `ghostty_action_tag_e`, L857–924)
and payload structs (L810–833), the only activity-bearing actions are:

| Action | Source | Payload | Fires when |
|---|---|---|---|
| `GHOSTTY_ACTION_PROGRESS_REPORT` | OSC 9;4 (app-emitted) | `state ∈ {REMOVE, SET, ERROR, INDETERMINATE, PAUSE}`, `progress` (−1 or 0–100) | a program prints the OSC 9;4 progress escape |
| `GHOSTTY_ACTION_COMMAND_FINISHED` | OSC 133 *D* (shell integration) | `exit_code` (−1 or 0–255), `duration` (ns) | a shell-tracked command ends |
| `GHOSTTY_ACTION_RING_BELL` | BEL / OSC 9 | — | already used by the bell indicator (#74) |

Two facts decide the design:

1. **There is no `GHOSTTY_ACTION_COMMAND_STARTED`** and **no generic "had output / is active"
   callback.** Shell integration tells us a command *finished* (with duration/exit code) but never
   that one *started*. So shell integration alone cannot *raise* a spinner — only lower it.
2. **A long-lived TUI is a single shell command.** `claude`, `vim`, `less` are one command from the
   shell's view; their per-turn "writing" never surfaces as start/finish events. Shell integration
   sees in-app activity as one command spanning the whole session.

### Coverage of the motivating cases

| "Busy" case from the issue | Reliable signal? | Why |
|---|---|---|
| Claude Code writing | ❌ | Claude Code emits no OSC 9;4; it's one long shell command, so no per-turn command-finished either |
| A process running at the shell prompt | ⚠️ partial | We learn it *finished* (`COMMAND_FINISHED`), never that it *started* — can't drive a spinner from that alone |
| A tool that emits OSC 9;4 progress (some build/download tools) | ✅ | Drives `PROGRESS_REPORT` directly; this is the case the prototype actually serves |
| Logs streaming | ❌ | Plain output; no signal at all |

So the only case we can drive honestly is **a tool that opts into OSC 9;4**. That is real but
narrow on macOS/Unix, and notably excludes Claude Code today.

## Chosen lifecycle

A pure Domain rule, `TerminalBusyPolicy.isBusy(_ signal:)` (`Sources/Domain/TerminalBusyPolicy.swift`),
reduces a signal to busy/idle. Unit-tested in `Tests/DomainTests/TerminalBusyPolicyTests.swift`.

- **Start (busy = true):** `PROGRESS_REPORT` `INDETERMINATE`, or `SET(<100)`.
- **Stop (busy = false):** `PROGRESS_REPORT` `SET(100)` / `REMOVE` / `ERROR` / `PAUSE`, **or**
  `COMMAND_FINISHED` (safety-net so a tool that emits progress and exits without `REMOVE` doesn't
  leave the spinner stuck).

The setting (`terminalBusySpinner`) only gates *rendering*, applied at draw time in `tabView()`;
the session's raw `isBusy` always tracks the signal, so toggling the setting reflects current state
without replaying signals.

## The prototype (what was built)

Mirrors the bell indicator (#74). All wiring is small and isolated:

- **Domain:** `TerminalBusyPolicy` + `ProgressState`/`TerminalBusySignal` enums; opt-in
  `Preferences.terminalBusySpinner` (default **false**).
- **App:** two new cases in the `GhosttyApp` action switch → `GhosttySurfaceView.progressReport(_:)`
  / `commandFinished()` map the C types to a Domain `TerminalBusySignal` and call
  `onActivity`; `TerminalContainerView.activityChanged(id:signal:)` runs the policy, flips an
  ephemeral `TerminalSession.isBusy`, and repaints just the strip; `tabView()` swaps the `Dot` for
  `makeSpinner()` when `store.terminalBusySpinner && session.isBusy`.
- **Settings:** a "Show a spinner on busy console tabs" checkbox in the General pane.

### Verification (run on 2026-06-29)

- **Unit:** `TerminalBusyPolicyTests` (7) + `PreferencesTests` busy cases pass; full suite 474/474.
- **Live, real signal:** enabled the setting, opened a local tab, ran
  `printf '\033]9;4;3\033\\'; sleep 90` (OSC 9;4 indeterminate). The active tab's status dot was
  replaced by an animated spinner; a second, idle tab kept its normal dot. `Ctrl-C` ended the
  command → `COMMAND_FINISHED` → the spinner reverted to a dot. Both the start (`PROGRESS_REPORT`)
  and stop (`COMMAND_FINISHED`) paths exercised the real libghostty → Domain → view chain.
  (Evidence screenshots captured during the spike: busy-spinner and stop-dot states.)

## Known limitations (carry into the follow-up)

- **No coverage for the headline case (Claude Code).** Opt-in + a clear setting label manage the
  expectation; we are not claiming a universal activity indicator.
- **Indeterminate spinner only.** `SET(0–100)` carries a real percentage we currently ignore; a
  determinate bar/ring would use it.
- **Possible stuck spinner** if a tool emits `INDETERMINATE` and neither `REMOVE` nor a tracked
  command-finish ever arrives. `COMMAND_FINISHED` covers the common case; a focus-clear or timeout
  backstop would harden it.
- **Spinner sizing in the tiny dot slot.** `makeSpinner(size: z(14))` is centered on the dot's
  slot; fine, but worth a design pass against the `z(7)` dot footprint.

## Recommendation: ship it (opt-in), with the follow-up below

The prototype is low-risk, isolated, and genuinely useful for OSC-9;4-emitting tools, so it's worth
keeping behind the opt-in setting rather than deferring. The follow-up issue tracks turning the
prototype into a finished feature (determinate progress, stuck-spinner backstop, sizing/design, and
empirical coverage notes).

## Productionization update (#94)

The follow-up (#94) closed the gaps above, so the coverage table earlier in this doc is **no longer
the final word**:

- **Plain foreground commands now covered.** `BusyShellIntegration` injects a zsh `ZDOTDIR` shim that
  emits OSC 9;4 INDETERMINATE from `preexec` and REMOVE from `precmd` (delegating to ghostty's own
  integration first), so a plain `sleep`/build drives the spinner — not just OSC-9;4-native tools.
  Scope is zsh local login shells (a folder/local tab); `ssh` and bash/fish are out (the latter a
  follow-up). The headline case — a long-lived TUI like Claude Code, which is one shell command and
  emits no per-turn signal — is still **not** covered; that's a libghostty limitation, not a gap to
  fix here. The setting's help text states this expectation.
- **Determinate progress.** `SET(0–100)` now renders a determinate ring (`makeProgressRing`) via the
  new pure `TerminalBusyPolicy.state(_:)` (`idle`/`indeterminate`/`determinate(percent)`); `isBusy`
  stays as a thin wrapper.
- **Stuck-spinner backstop.** A per-session timeout (`TerminalContainerView.busyBackstop`, ~10 min),
  re-armed on every signal, force-clears a tab that latches busy then goes silent (chiefly an `ssh`
  tab, where the shell hook isn't installed). A focus-clear was rejected: busy is a live *level*, so
  clearing it on focus would kill a legitimately-busy tab's spinner.
- **Setting moved + relabelled.** The toggle now lives in the **Terminal** settings pane (with the
  other ghostty-style options), labelled "Show busy/progress on console tabs", still opt-in (off).
