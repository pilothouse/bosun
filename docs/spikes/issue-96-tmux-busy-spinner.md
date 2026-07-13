# Spike #96 — busy/progress spinner on a tmux connection tab

**Status:** investigated + implemented (behind the existing opt-in setting). Recommendation below.
**Date:** 2026-07-13

## TL;DR recommendation

Ship the tmux passthrough path — it's built and verified. The busy spinner (#93/#94) was dark on a
tmux tab for two independent reasons; both are now fixed for the case Bosun actually creates, an
**SSH connection whose `customCommand` runs tmux**:

1. **tmux swallows the signal.** By default tmux consumes an inner OSC 9;4 and never forwards it to
   ghostty. Fix: enable tmux's `allow-passthrough` and wrap the OSC in tmux's DCS envelope
   (`\ePtmux;…\e\\`, ESCs doubled) — a pure rule, `Domain/TmuxPassthrough.wrap`.
2. **No emitter on an SSH tab.** The busy shim was injected only for local shells; `env` can't cross
   SSH. Fix: `SSHCommand.command` now ships the shim into the remote session as a throwaway
   `ZDOTDIR`, so the remote shell emits the (wrapped) OSC 9;4 that tmux forwards.

Kept opt-in (the existing `terminalBusySpinner`) and honest about coverage: **local, manually-typed
`tmux`** and **`tmux attach` to a pre-existing server** stay uncovered (reasons below), and a
long-lived TUI like Claude Code is still invisible — a libghostty limitation carried over from #93.

## The investigation: confirm the failure precisely

The #93 doc already flagged SSH and long-lived TUIs as uncovered; tmux is a sharper case because even
a program that *does* emit OSC 9;4 goes dark inside tmux. Two facts, both verified here.

**1. Default tmux swallows OSC 9;4; passthrough forwards it.** Captured what tmux writes to its host
pty while a pane emits the DCS-wrapped busy sequence (`scripts`/PTY harness, tmux 3.7b):

| tmux config | pane emits | host (ghostty side) receives | result |
|---|---|---|---|
| default (`allow-passthrough off`) | `\ePtmux;\e\e]9;4;3\e\e\\\e\\` | *nothing* — envelope + payload consumed | spinner stays dark (**the #96 bug**) |
| `set -g allow-passthrough on` | same | exactly `\e]9;4;3\e\\` (envelope stripped, ESCs un-doubled) | ghostty fires `PROGRESS_REPORT` → spinner |

So the fix is entirely on the *emitter* side: turn passthrough on and wrap the sequence. ghostty
needs no change — it just receives an ordinary OSC 9;4, the path #93 already wired.

**2. The shim never reaches an SSH tab.** `makeConnectionSession` set the shim `env` only in the
`.localFolder` branch; the `.ssh` branch passed `env = []`, and libghostty `env_vars` apply to the
local `ssh` client, not the remote shell. So an SSH+tmux tab had no OSC 9;4 source at all.

### A subtlety that decides the scope

The #94 shim hands `ZDOTDIR` back to the user's before the shell finishes starting (so their config
loads). That means a **manually-typed local `tmux`** spawns panes that no longer re-source our shim —
they get no hook. The shim only reaches an in-tmux shell when *we* launch tmux with `ZDOTDIR` still
pointing at the shim. That is exactly the SSH case (`ssh … -t 'tmux …'` is launched by Bosun), and it
is the only tmux shape Bosun creates (`Connection.customCommand` is SSH-only). Local hand-run tmux is
therefore out of scope by construction, not by choice.

## Coverage

| tmux case | Covered? | Why |
|---|---|---|
| SSH connection, `customCommand` = `tmux new …` | ✅ | `SSHCommand` ships the shim as remote `ZDOTDIR` + enables passthrough; shim wraps OSC 9;4 inside tmux |
| A remote tool that emits OSC 9;4 itself (build/download) | ✅ | passthrough is on for the session, so its progress now reaches ghostty |
| `customCommand` = `tmux attach` to a **pre-existing** server | ⚠️ partial | passthrough gets set on that server, but panes it already spawned lack the hook; new panes/`tmux new` are fine |
| Local, manually-typed `tmux` in a folder/local tab | ❌ | `ZDOTDIR` already handed back before the manual launch (see above) |
| Long-lived TUI (Claude Code, vim) inside tmux | ❌ | one shell command, emits no per-turn signal — a libghostty limit, unchanged from #93 |

## Chosen approach (cheapest-first, all opt-in)

Reuse the #93/#94 pipeline unchanged; add only the emitter + passthrough.

- **`Domain/TmuxPassthrough.wrap(_:)`** — the single source of truth for the DCS wrapping (double
  ESCs, bracket with `\ePtmux;…\e\\`) plus `allowPassthroughCommand`. Pure, contract-tested.
- **Shim (`BusyShellIntegration`)** — `_bosun_busy_emit` now wraps via `TmuxPassthrough`'s scheme
  when `$TMUX` is set (plain OSC otherwise, so local non-tmux behaviour is byte-identical), and runs
  `tmux set -g allow-passthrough on` once when inside tmux. The zsh mirrors `wrap`; the tests pin the
  exact bytes so the two can't drift.
- **`SSHCommand.command(…, busyShim:)`** — when `busyShim` is set *and* `custom` launches tmux,
  rewrites the remote command to base64-install the shim as a throwaway `ZDOTDIR` and `exec` the
  passthrough-enabled tmux. `busyShim` nil (the default) or a non-tmux `custom` → byte-for-byte
  unchanged (the existing contract tests still pass untouched).
- **`makeConnectionSession`** passes `BusyShellIntegration.remoteShim(enabled: store.terminalBusySpinner)`
  into the `.ssh` branch. No new setting; the existing Terminal-pane toggle gates everything.

## Verification (run 2026-07-13)

- **Unit:** `TmuxPassthroughTests` (8) pin the wrapped bytes for busy/idle/empty/multi-ESC;
  `SSHCommandTests` adds 5 busy cases (tmux rewrite, bare-`tmux`→`new-session`, non-tmux untouched,
  nil-shim identity, and single-quotes-don't-leak). Full suite **562/562** green; the pre-existing
  `SSHCommand` contract tests were not modified.
- **Byte-exact shim:** ran the shim's `_bosun_busy_emit` in zsh; raw = `\e]9;4;3\e\\`, wrapped =
  `\ePtmux;\e\e]9;4;3\e\e\\\e\\` — matches `TmuxPassthrough.wrap` exactly.
- **tmux forwarding (PTY capture):** default tmux dropped the sequence entirely; `allow-passthrough
  on` delivered the exact un-wrapped OSC 9;4 to the host pty (table above).
- **Live GUI (real tmux, real ghostty):** enabled the setting, ran tmux in a Bosun tab. (a) Emitting
  the wrapped OSC 9;4 from inside tmux replaced the tab's dot with an animated spinner; a wrapped
  REMOVE reverted it to the dot. (b) Launching tmux the way `SSHCommand` does — shim as `ZDOTDIR` —
  and running a plain `sleep` **auto-lit** the spinner via the shim's `preexec`, with the shim itself
  having enabled passthrough. That exercises the real shipped path end-to-end.
- **SSH remote path:** unit-tested (the exact rewritten command) + the base64→`openssl base64 -d`
  round-trip verified locally. A live remote run needs an SSH host (Remote Login was off here); the
  in-tmux behaviour it depends on is the same one the live GUI test drove.

## Known limitations

- **Local hand-run tmux** and **`tmux attach` to an existing server** are not covered (see the
  coverage table). A `set-hook`/control-mode (`-CC`) approach could reach them but is out-of-band and
  much heavier — deferred.
- **Remote assumptions:** the SSH path assumes the remote shell is zsh and that `openssl`
  (or base64) and tmux ≥ 3.3 (`allow-passthrough`) exist. A non-zsh remote simply ignores the shim
  file; a remote without `openssl` gets no emitter (passthrough still helps OSC-9;4-native tools).
- **Long-lived TUIs** (Claude Code) remain invisible — one shell command, no per-turn signal.

## Recommendation: ship it (opt-in), with the follow-up below

The change is isolated (one pure Domain rule + a shim tweak + one additive `SSHCommand` param) and
verified end-to-end for the case Bosun creates. Keep it behind `terminalBusySpinner`.

### Follow-up issue (draft — not yet filed)

> **Title:** Extend busy-spinner tmux coverage to local tmux and non-zsh/attach cases
> **Type:** Feature · **Priority:** P2 · Follow-up to #96
>
> #96 lights the spinner for an SSH connection whose `customCommand` runs `tmux new`. Remaining gaps:
> - **Local, manually-typed tmux** — the shim is handed back its `ZDOTDIR` before the manual launch,
>   so panes get no hook. Options: a user-facing "wrap local tmux" launcher, or documenting a manual
>   `~/.tmux.conf` (`allow-passthrough on`) + `~/.zshrc` OSC 9;4 hook opt-in.
> - **`tmux attach`** to a pre-existing server (existing panes lack the hook).
> - **Non-zsh remotes** (bash/fish emitter) and remotes without `openssl`.
> - Consider tmux `set-hook` / control-mode (`-CC`) as an out-of-band alternative that needs no
>   in-pane emitter.
