#!/usr/bin/env bash
#
# perf-sim.sh — Bosun memory simulation harness.
#
# Loads a RELEASE build of Bosun with heavy synthetic data and samples its real peak memory
# footprint, so the "Performance & memory" section of ABOUT.md is backed by measurement rather
# than guesswork. It exercises the three dimensions that actually consume RAM at runtime:
#
#   • open consoles   — N real libghostty/Metal surfaces (inactive tabs stay allocated, so N tabs
#                        == N live surfaces == the true peak). Each forks a login shell, counted
#                        and reported SEPARATELY (those are distinct PIDs, not Bosun's memory).
#   • connections     — N saved connections spread across M folders, loaded into the rail.
#   • GitHub data     — an orgs/repos tree plus a cache mirror holding issues/PRs. Held resident
#                        via the off-by-default BOSUN_PERF_SEED flag (AppDelegate +
#                        GitHubDataController.loadFromCacheForPerf), which hydrates from the seeded
#                        github-cache.json with NO live fetch. The flag now resolves to
#                        AppMode.perfSeed in CompositionRoot — the same mode selector as the
#                        offline BOSUN_UI_TEST mode, which is Keychain-safe too.
#
# It seeds three stores the app reads on launch — `connections.json`, `github-cache.json`, and the
# `bosun.preferences` UserDefaults blob (openTabs) — runs the app under `caffeinate` (Metal needs
# an awake display), reads `Physical footprint (peak)` from `vmmap --summary`, then tears down.
#
# SAFETY: your real connections.json / github-cache.json / Bosun defaults are backed up before the
# first tier and restored on exit (including Ctrl-C / error). The run leaves your data untouched.
#
# Usage:
#   bash scripts/build-libghostty.sh            # once, if Vendor/libghostty.a isn't staged
#   swift build -c release --disable-sandbox    # the binary this measures
#   bash scripts/perf-sim.sh baseline t1 t2 t3  # run one or more tiers in sequence
#   bash scripts/perf-sim.sh consoles-only connections-only github-only   # isolation runs
#
# Tunables: SETTLE=<seconds> (default 8) — time to let surfaces + cache hydration settle.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO/.build/release/Bosun"
SUPPORT="$HOME/Library/Application Support/bosun"
CACHE="$SUPPORT/github-cache.json"
CONNS="$SUPPORT/connections.json"
PREFS_DOMAIN="Bosun"
PREFS_KEY="bosun.preferences"
SETTLE="${SETTLE:-8}"

# tier preset -> "consoles connections folders orgs reposPerOrg cachedRepos itemsPerRepo".
# A console count of 1 means "don't seed openTabs" — the app opens its single default shell (the
# unavoidable floor). Isolation tiers hold every other dimension at that floor so a delta against
# `baseline` attributes one dimension's cost.
preset() {
  case "$1" in
    baseline)         echo "1 0 0 0 0 0 0" ;;
    t1)               echo "6 150 15 15 25 40 120" ;;
    t2)               echo "12 400 30 30 40 120 150" ;;
    t3)               echo "24 1000 50 50 40 300 150" ;;
    consoles-only)    echo "24 0 0 0 0 0 0" ;;
    connections-only) echo "1 1000 50 0 0 0 0" ;;
    github-only)      echo "1 0 0 50 40 300 150" ;;
    *) echo "unknown tier: $1 (try: baseline t1 t2 t3 consoles-only connections-only github-only)" >&2; return 1 ;;
  esac
}

[ -x "$BIN" ] || { echo "missing $BIN — run: swift build -c release --disable-sandbox" >&2; exit 1; }
[ "$#" -ge 1 ] || { echo "usage: bash scripts/perf-sim.sh <tier> [tier ...]" >&2; exit 1; }

# ── back up the user's real stores once; restore on any exit ────────────────────────────────────
BK="$(mktemp -d "${TMPDIR:-/tmp}/bosun-perf.XXXXXX")"
GEN="$BK/gen.py"
HAD_CACHE=0; HAD_CONNS=0
[ -f "$CACHE" ] && { cp "$CACHE" "$BK/github-cache.json"; HAD_CACHE=1; }
[ -f "$CONNS" ] && { cp "$CONNS" "$BK/connections.json"; HAD_CONNS=1; }
defaults export "$PREFS_DOMAIN" "$BK/Bosun.plist" 2>/dev/null || true

BOSUN_PID=""; CAF=""
# Echo every descendant pid of $1 (the per-tab `/usr/bin/login` shells and their `zsh` children).
descendants() {
  local k
  for k in $(pgrep -P "$1" 2>/dev/null); do echo "$k"; descendants "$k"; done
}
kill_app() {
  [ -n "$BOSUN_PID" ] || return 0
  # shellcheck disable=SC2046
  kill $(descendants "$BOSUN_PID") "$BOSUN_PID" 2>/dev/null || true
  BOSUN_PID=""
}
cleanup() {
  kill_app
  [ -n "$CAF" ] && kill "$CAF" 2>/dev/null || true
  pkill -x Bosun 2>/dev/null || true   # backstop: sweep any stray instance from this run
  mkdir -p "$SUPPORT"
  if [ "$HAD_CACHE" = 1 ]; then cp "$BK/github-cache.json" "$CACHE"; else rm -f "$CACHE"; fi
  if [ "$HAD_CONNS" = 1 ]; then cp "$BK/connections.json" "$CONNS"; else rm -f "$CONNS"; fi
  defaults import "$PREFS_DOMAIN" "$BK/Bosun.plist" 2>/dev/null || true
  rm -rf "$BK"
  echo "↩︎  restored your real connections / cache / preferences"
}
trap cleanup EXIT INT TERM

# ── the data generator (written to a file so the heredoc is NOT inside $(), which macOS bash 3.2
#    mishandles). Writes connections.json + github-cache.json to disk and prints the prefs blob as
#    hex on stdout for `defaults … -data`. ───────────────────────────────────────────────────────
cat > "$GEN" <<'PY'
import json, os, sys, uuid

consoles, connections, folders, orgs, repos_per_org, cached_repos, items_per_repo = map(int, sys.argv[1:8])
support = sys.argv[8]
os.makedirs(support, exist_ok=True)

# connections.json — { connections:[...], folders:[...] } envelope (see JSONFileConnectionStore).
folder_ids = [str(uuid.uuid4()) for _ in range(folders)]
conns = [{
    "id": str(uuid.uuid4()),
    "name": "workspace-%04d" % i,
    "kind": {"localFolder": {"path": "/tmp/bosun-perf/%04d" % i}},
    "isFavorite": (i % 25 == 0),
    "folderId": (folder_ids[i % folders] if folders else None),
    "updatedAt": None,
} for i in range(connections)]
folder_list = [{"id": folder_ids[k], "name": "Folder %02d" % k, "updatedAt": None} for k in range(folders)]
with open(os.path.join(support, "connections.json"), "w") as f:
    json.dump({"connections": conns, "folders": folder_list}, f)

# github-cache.json — the Snapshot shape (see JSONFileGitHubCacheStore). Dates are deferredToDate
# (plain JSONEncoder): a Double of seconds since 2001-01-01, NOT ISO8601. Optional GitHubItem
# fields (files/assignees/...) are omitted; synthesized Codable decodes a missing key as nil.
BASE_TS = 770000000.0  # ~2025
def item(owner, repo, kind, n):
    return {
        "id": "%s/%s#%s#%d" % (owner, repo, kind, n),
        "number": n,
        "kind": kind,
        "title": "%s %d in %s: synthetic work item for the perf simulation" % (kind, n, repo),
        "state": "open",
        "author": {"login": "user%d" % (n % 50), "avatarURL": None},
        "createdAt": BASE_TS - n * 3600.0,
        "body": "Synthetic body for the Bosun memory simulation. " * 6,
        "repositoryNameWithOwner": "%s/%s" % (owner, repo),
        "labels": ["perf", "synthetic"] if n % 3 == 0 else [],
        "isDraft": False,
        "comments": [],
        "checks": [],
        "tasks": [],
    }

org_list = []
for o in range(orgs):
    login = "org%02d" % o
    repolist = [{
        "id": "%s/repo%02d" % (login, r),
        "name": "repo%02d" % r,
        "owner": login,
        "openIssues": (r * 3 + o) % 40,
        "openPullRequests": (r * 2 + o) % 20,
    } for r in range(repos_per_org)]
    org_list.append({"id": "org-%s" % login, "login": login, "name": "Organization %02d" % o,
                     "avatarURL": None, "repositories": repolist})

flat = [(o["login"], r["name"]) for o in org_list for r in o["repositories"]]
n_issues = items_per_repo // 2
n_prs = items_per_repo - n_issues
items = {}
for (owner, repo) in flat[:cached_repos]:
    if n_issues:
        items["%s/%s#issue" % (owner, repo)] = [item(owner, repo, "issue", n) for n in range(1, n_issues + 1)]
    if n_prs:
        items["%s/%s#pullRequest" % (owner, repo)] = [item(owner, repo, "pullRequest", n) for n in range(1, n_prs + 1)]

with open(os.path.join(support, "github-cache.json"), "w") as f:
    json.dump({"login": ("perf-user" if orgs else None), "orgs": org_list,
               "viewerRepos": [], "items": items}, f)

# prefs blob: seed openTabs only when forcing more than the default single shell. A .local tab
# encodes as {"local": {}} (Swift's synthesized enum form). Printed as hex for `defaults ... -data`.
prefs = {}
if consoles > 1:
    tabs = [{"id": str(uuid.uuid4()), "kind": {"local": {}}, "title": "perf-%02d" % (i + 1), "locked": False}
            for i in range(consoles)]
    prefs["openTabs"] = tabs
    prefs["activeTabId"] = tabs[0]["id"]
sys.stdout.write(json.dumps(prefs).encode("utf-8").hex())
PY

# ── per-tier run ────────────────────────────────────────────────────────────────────────────────
run_tier() {
  local tier="$1"
  local consoles connections folders orgs reposPerOrg cachedRepos itemsPerRepo
  read -r consoles connections folders orgs reposPerOrg cachedRepos itemsPerRepo <<<"$(preset "$tier")"

  local prefs_hex
  prefs_hex="$(python3 "$GEN" "$consoles" "$connections" "$folders" "$orgs" "$reposPerOrg" "$cachedRepos" "$itemsPerRepo" "$SUPPORT")"
  defaults write "$PREFS_DOMAIN" "$PREFS_KEY" -data "$prefs_hex"

  # Launch the release binary DIRECTLY (so $! is Bosun's pid, not caffeinate's — whose argv would
  # otherwise contain the binary path and confuse pgrep) with the measurement hook on.
  BOSUN_PERF_SEED=1 "$BIN" >/dev/null 2>&1 &
  BOSUN_PID=$!
  sleep "$SETTLE"
  ps -p "$BOSUN_PID" >/dev/null 2>&1 || { echo "$tier: app exited early (no Metal display?)" >&2; BOSUN_PID=""; return 0; }

  # Sample. `Physical footprint (peak)` is the high-water mark — robust to sample timing.
  local summary peak foot rss shells shell_kb r c cm
  summary="$(vmmap --summary "$BOSUN_PID" 2>/dev/null || true)"
  foot="$(printf '%s\n' "$summary" | awk -F: '/Physical footprint:/        {gsub(/ /,"",$2); print $2; exit}')"
  peak="$(printf '%s\n' "$summary" | awk -F: '/Physical footprint \(peak\)/ {gsub(/ /,"",$2); print $2; exit}')"
  rss="$(ps -o rss= -p "$BOSUN_PID" 2>/dev/null | tr -d ' ')"

  # Console shells: each tab is a `/usr/bin/login` child running a `zsh`. Count the logins (==
  # consoles) and sum the whole shell subtree's RSS — reported separately, as those are distinct
  # PIDs, not Bosun's own memory.
  shells=0; shell_kb=0
  for c in $(descendants "$BOSUN_PID"); do
    cm="$(ps -o comm= -p "$c" 2>/dev/null)"
    r="$(ps -o rss= -p "$c" 2>/dev/null | tr -d ' ')"
    [ -n "$r" ] && shell_kb=$((shell_kb + r))
    case "$cm" in *login) shells=$((shells + 1));; esac
  done

  printf '%-16s consoles=%-2s conns=%-4s/%-2sf  orgs=%-2sx%-2s  cachedItems~%-6s | footprint=%s peak=%s rss=%sM | shells=%s totaling %sM\n' \
    "$tier" "$consoles" "$connections" "$folders" "$orgs" "$reposPerOrg" \
    "$(( cachedRepos * itemsPerRepo ))" \
    "${foot:-?}" "${peak:-?}" "$(( ${rss:-0} / 1024 ))" "$shells" "$(( shell_kb / 1024 ))"

  kill_app
  sleep 1
}

caffeinate -dis & CAF=$!   # keep the display + system awake so Metal surfaces can be created

echo "Bosun perf-sim — release binary, $(sw_vers -productName) $(sw_vers -productVersion) ($(uname -m)), SETTLE=${SETTLE}s"
echo "─────────────────────────────────────────────────────────────────────────────────────────────"
for tier in "$@"; do run_tier "$tier"; done
