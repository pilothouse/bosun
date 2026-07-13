import Foundation
import os

/// Opt-in shell hook that makes a console tab's busy spinner cover *plain* foreground commands
/// (e.g. `sleep`), not just tools that emit OSC 9;4 themselves (#93 covered the latter; #94 this).
///
/// libghostty surfaces `COMMAND_FINISHED` but no command-*started* signal, so the shell has to tell
/// us when a command begins. We do that by emitting an OSC 9;4 progress escape from a zsh
/// `preexec`/`precmd` hook — which the existing `progressReport` → `TerminalBusyPolicy` → spinner
/// path already understands. The hook is delivered by pointing the shell's `ZDOTDIR` at a tiny
/// Bosun-owned shim whose `.zshenv` *delegates to ghostty's own integration* (it restores the user's
/// `ZDOTDIR`, loads their config, and installs ghostty's OSC 133 hooks) before appending ours, so
/// nothing of ghostty's behavior is reimplemented or lost.
///
/// Why `ZDOTDIR` and why this shape: a surface's env vars are applied as ghostty's `env_override`
/// *after* its `shell_integration.setup`, so our `ZDOTDIR` lands on top of ghostty's — but `setup`
/// has already exported `GHOSTTY_RESOURCES_DIR` and the user's original `GHOSTTY_ZSH_ZDOTDIR`, which
/// the shim uses to hand back to ghostty. Scope is zsh (the macOS default); bash/fish are follow-ups.
enum BusyShellIntegration {
    /// The shim `.zshenv`. A raw string so the zsh `$'\e…'` escapes stay literal in the file.
    static let zshenv = #"""
    # Bosun busy-spinner shim (#94). We were injected as ZDOTDIR; hand back to ghostty's own zsh
    # integration first (it restores the user's ZDOTDIR, loads their config, installs OSC 133 hooks)...
    if [[ -n "$GHOSTTY_RESOURCES_DIR" && -r "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/.zshenv" ]]; then
      builtin source "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/.zshenv"
    elif [[ -n "${GHOSTTY_ZSH_ZDOTDIR+X}" ]]; then   # fallback: ghostty integration unavailable
      builtin export ZDOTDIR="$GHOSTTY_ZSH_ZDOTDIR"; builtin unset GHOSTTY_ZSH_ZDOTDIR
    else
      builtin unset ZDOTDIR
    fi
    # ...then add OSC 9;4: busy on command start, idle at the next prompt. Append to the same hook
    # arrays ghostty uses so both coexist; guard on `interactive` so scripts don't register it.
    if [[ -o interactive ]]; then
      # Inside tmux, a raw OSC is swallowed by tmux and never reaches ghostty (#96). Enable tmux's
      # passthrough and wrap the OSC in tmux's DCS envelope (double ESCs, bracket with
      # \ePtmux;...\e\\) so tmux forwards it. Mirrors Domain.TmuxPassthrough.wrap — keep in lockstep.
      [[ -n "$TMUX" ]] && builtin command tmux set -g allow-passthrough on 2>/dev/null
      _bosun_busy_emit() {   # $1 = OSC 9;4 state digit (3 = busy, 0 = idle)
        if [[ -n "$TMUX" ]]; then   # DCS passthrough: ESCs doubled, wrapped \ePtmux;…\e\\
          builtin print -rn -- $'\ePtmux;\e\e]9;4;'"$1"$'\e\e\\\e\\'
        else
          builtin print -rn -- $'\e]9;4;'"$1"$'\e\\'
        fi
      }
      _bosun_busy_preexec() { _bosun_busy_emit 3 }   # indeterminate -> busy
      _bosun_busy_precmd()  { _bosun_busy_emit 0 }   # remove        -> idle
      builtin typeset -ag preexec_functions precmd_functions
      preexec_functions+=(_bosun_busy_preexec)
      precmd_functions+=(_bosun_busy_precmd)
    fi
    """#

    /// Lazily written shim directory path (the file is `<dir>/.zshenv`). Written once per launch.
    private static var cachedDir: String?

    /// Ensure the shim directory exists with our `.zshenv`, returning its path (the value to use as
    /// `ZDOTDIR`), or `nil` if it couldn't be written.
    static func ensureZdotdir() -> String? {
        if let cachedDir { return cachedDir }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bosun-busy-zsh", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try zshenv.write(to: dir.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        } catch {
            Log.shell.error("failed to write zsh shim: \(String(describing: error), privacy: .public)")
            return nil
        }
        cachedDir = dir.path
        return dir.path
    }

    /// The env vars to set on a surface so its shell emits the busy signal — `[ZDOTDIR=<shim>]` when
    /// the feature is on, this is a local login shell, and that shell is zsh; otherwise empty (a
    /// non-zsh shell ignores `ZDOTDIR`, but we skip it anyway to keep the env clean).
    static func envVars(enabled: Bool, isLocalShell: Bool) -> [(String, String)] {
        guard enabled, isLocalShell, isZshLoginShell, let dir = ensureZdotdir() else { return [] }
        return [("ZDOTDIR", dir)]
    }

    private static var isZshLoginShell: Bool {
        (ProcessInfo.processInfo.environment["SHELL"] ?? "").hasSuffix("zsh")
    }

    /// The shim body to carry into a remote (SSH) tmux session, or nil when the feature is off.
    /// Unlike the local path this writes nothing to disk — `SSHCommand` base64-ships this string into
    /// the remote command, which installs it as a throwaway remote `ZDOTDIR` (#96). The remote shell
    /// is assumed to be zsh (the shim's hooks are zsh; a non-zsh remote simply ignores the file).
    static func remoteShim(enabled: Bool) -> String? {
        enabled ? zshenv : nil
    }
}
