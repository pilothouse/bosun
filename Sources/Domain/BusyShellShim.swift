import Foundation

/// The zsh shim that makes a console tab report busy/idle through OSC 9;4 (#94): `preexec` emits
/// busy, `precmd` emits idle, wrapped for tmux passthrough inside tmux (#96). Bosun installs it as the
/// shell's `ZDOTDIR` (`BusyShellIntegration` in the app), and `SSHCommand` ships the same text to a
/// remote tmux session. Pure text, so it lives here and `BusyShellShimTests` runs it in a real zsh.
public enum BusyShellShim {
    /// Commands that report their own per-turn progress when they see ghostty (#103 spike: Claude
    /// Code emits OSC 9;4 at startup, turn start and turn end when `TERM_PROGRAM=ghostty`, and nothing
    /// otherwise). The shim skips its own whole-run busy for these. Plain names, no glob characters.
    static let selfReportingCommands = ["claude"]

    /// The shim `.zshenv`. A raw string so the zsh `$'\e…'` escapes stay literal in the file.
    public static let zshenv = #"""
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
      # \ePtmux;...\e\\) so tmux forwards it. Mirrors TmuxPassthrough.wrap (BusyShellShimTests pins it).
      [[ -n "$TMUX" ]] && builtin command tmux set -g allow-passthrough on 2>/dev/null
      _bosun_busy_emit() {   # $1 = OSC 9;4 state digit (3 = busy, 0 = idle)
        if [[ -n "$TMUX" ]]; then   # DCS passthrough: ESCs doubled, wrapped \ePtmux;…\e\\
          builtin print -rn -- $'\ePtmux;\e\e]9;4;'"$1"$'\e\e\\\e\\'
        else
          builtin print -rn -- $'\e]9;4;'"$1"$'\e\\'
        fi
      }
      # Tools that emit their own per-turn OSC 9;4 once they detect ghostty (Claude Code, #103) would
      # otherwise read busy for their whole lifetime: preexec fires once, when they start. Leave those
      # to report themselves. Elsewhere (tmux, no TERM_PROGRAM) they stay silent, so keep our signal.
      _bosun_busy_self_reporting() {   # $1 = the command line about to run
        [[ "$TERM_PROGRAM" == ghostty ]] || return 1
        builtin local -a words   # an array even for one word, so [1] is a word, not a character
        words=(${(z)1})
        builtin local cmd=${(Q)words[1]}
        [[ ${cmd:t} == (\#(selfReportingCommands.joined(separator: "|"))) ]]
      }
      _bosun_busy_preexec() { _bosun_busy_self_reporting "$2" || _bosun_busy_emit 3 }   # indeterminate -> busy
      _bosun_busy_precmd()  { _bosun_busy_emit 0 }   # remove        -> idle
      builtin typeset -ag preexec_functions precmd_functions
      preexec_functions+=(_bosun_busy_preexec)
      precmd_functions+=(_bosun_busy_precmd)
    fi
    """#
}
