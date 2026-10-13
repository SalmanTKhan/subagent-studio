#!/usr/bin/env bash
# The wake lock: stops scheduled runs from overlapping.
# The lock file holds one line per run at work: "<ISO timestamp> <id>". Each
# run appends its own line and removes only its own; nothing overwrites the
# file. The state lives in the file, never in a shell variable, because every
# Bash call is a new shell.
#
# The id is the run's own fixed token, e.g. `wake-up` for a wake-up (never a
# task id, which changes during a run). A line older than
# unattended.stale_hours (default 4) is stale.
#
#   wake_lock.sh add <id>        append "<now> <id>", then print the file
#   wake_lock.sh remove <id>     remove every line ending in " <id>";
#                                the file is deleted when left empty
#   wake_lock.sh remove --stale  remove every stale line
#   wake_lock.sh check [--holder-class PREFIX]
#                                one line per lock line:
#                                "<age>min <fresh|stale> <kind> <line>"
#                                ("unreadable, stale ..." for a bad stamp);
#                                kind is PREFIX for a line whose id starts
#                                with PREFIX, otherwise `run`
#
# --holder-class names a class of runs that never blocks the caller, for
# example a steering run that only edits the queue at its end: a wake-up
# beside a fresh line of that class still works and holds back only the
# edits that class owns.
#
# Exit codes. add, remove: 0 done, 1 another writer holds the mutex (it is
# younger than 30 s after a 5 s wait), 2 usage. check: 0 no fresh line (no
# file, or only stale lines), 3 fresh lines and every one is of the holder
# class, 4 a fresh line of any other run, 2 usage.
# Timestamps: "YYYY-MM-DDTHH:MM:SS" then "+HHMM", "+HH:MM" or "Z". Any other
# form (a hand-written "2026-10-02 09:02:41Z <id>" line, a space for the T)
# is unreadable and counts as stale; check prints it as "unreadable, stale".
#
# Config: unattended.lock_file (relative to the project root: $CLAUDE_PROJECT_DIR,
# else the main worktree, also when run from a linked worktree) and
# unattended.stale_hours, read through studio_config.py beside this script.
# Env overrides (tests): WAKE_LOCK_FILE the file, WAKE_LOCK_STALE_HOURS the
# stale age, WAKE_LOCK_NOW the clock (epoch), WAKE_LOCK_MUTEX_WAIT the mutex
# wait in tenths of a second.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

# The project root: $CLAUDE_PROJECT_DIR, else the main worktree of the git
# repo (the parent of the common git dir), so a run in a linked worktree
# (a review worktree, say) uses the same lock file as the main one; else
# the current directory.
project_root() {
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    printf '%s\n' "$CLAUDE_PROJECT_DIR"; return
  fi
  local common
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  case "$common" in
    /*) (cd "$common/.." 2>/dev/null && pwd) && return ;;
  esac
  # older git: no --path-format; the common dir may be relative to here
  common="$(git rev-parse --git-common-dir 2>/dev/null)"
  if [ -n "$common" ] && (cd "$common/.." 2>/dev/null && pwd); then
    return
  fi
  pwd
}
ROOT="$(project_root)"

# Read the lock file and stale hours from the config, unless both are set.
CFG_FILE=""; CFG_STALE=""
if [ -z "${WAKE_LOCK_FILE:-}" ] || [ -z "${WAKE_LOCK_STALE_HOURS:-}" ]; then
  cfg_out="$(python3 - "$HERE" "$ROOT" <<'PY' 2>/dev/null
import os, sys
sys.path.insert(0, sys.argv[1])
import studio_config as sc
root = sc.find_root(sys.argv[2])
try:
    cfg = sc.load(root)
except sc.ConfigError:
    cfg = sc.DEFAULTS
u = cfg.get("unattended", {})
lock = u.get("lock_file", ".wake-lock")
if not os.path.isabs(lock):
    lock = os.path.join(root, lock)
print(lock)
print(int(u.get("stale_hours", 4)))
PY
)" || cfg_out=""
  CFG_FILE="$(printf '%s\n' "$cfg_out" | sed -n 1p)"
  CFG_STALE="$(printf '%s\n' "$cfg_out" | sed -n 2p)"
fi
F="${WAKE_LOCK_FILE:-${CFG_FILE:-$ROOT/.wake-lock}}"
STALE_HOURS="${WAKE_LOCK_STALE_HOURS:-${CFG_STALE:-4}}"
case "$STALE_HOURS" in ''|*[!0-9]*) STALE_HOURS=4 ;; esac
STALE_MIN=$((STALE_HOURS * 60))

now() { echo "${WAKE_LOCK_NOW:-$(date +%s)}"; }

OS="$(uname -s)"

epoch_of() { # ISO timestamp -> epoch, empty when unreadable
  local ts="$1"
  case "$ts" in *Z) ts="${ts%Z}+0000" ;; esac
  if printf '%s' "$ts" | grep -Eq '[+-][0-9]{2}:[0-9]{2}$'; then
    ts="${ts%???}${ts#"${ts%??}"}"
  fi
  printf '%s' "$ts" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4}$' || return 0
  if [ "$OS" = Darwin ]; then
    date -j -f '%Y-%m-%dT%H:%M:%S%z' "$ts" +%s 2>/dev/null || true
  else
    date -d "$ts" +%s 2>/dev/null || true
  fi
}

# Modification time in epoch: BSD stat on macOS, GNU stat elsewhere (GNU's
# `stat -f` means filesystem status, so it is never tried there).
mtime_of() {
  if [ "$OS" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# A short mutex so two writers never interleave a remove's read and mv with
# an append. mkdir is atomic. After about 5 s a mutex older than 30 s is
# stale (its writer died) and is taken over; a younger one is a live writer,
# so we fail rather than write beside it. We remove only a mutex we created.
MUTEX_WAIT="${WAKE_LOCK_MUTEX_WAIT:-50}" # tenths of a second (tests shorten it)
MUTEX_STALE_S=30
HAVE_MUTEX=0
lock_mutex() {
  local i=0 m
  while ! mkdir "$F.mutex" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge "$MUTEX_WAIT" ]; then
      m="$(mtime_of "$F.mutex")"
      if [ -n "$m" ] && [ $(( $(date +%s) - m )) -gt "$MUTEX_STALE_S" ] \
          && rmdir "$F.mutex" 2>/dev/null && mkdir "$F.mutex" 2>/dev/null; then
        break
      fi
      echo "wake_lock.sh: $F.mutex is held by another writer (younger than ${MUTEX_STALE_S}s); try again" >&2
      exit 1
    fi
    sleep 0.1
  done
  HAVE_MUTEX=1
}
unlock_mutex() {
  [ "$HAVE_MUTEX" = 1 ] || return 0
  rmdir "$F.mutex" 2>/dev/null || true; HAVE_MUTEX=0
}

usage() { grep '^#   wake_lock.sh' "$0" >&2; exit 2; }

# Prints "<age|-> <fresh|stale> <kind> <0|1>\t<line>" for each non-empty
# line; "-" is an unreadable timestamp, always stale; the last field is 1 for
# a line of the holder class CLASS.
CLASS=""
classify() {
  [ -f "$F" ] || return 0
  local n line ts id e age state kind
  n="$(now)"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    ts="${line%% *}"; id="${line##* }"
    e="$(epoch_of "$ts")"
    if [ -z "$e" ]; then age=-; state=stale
    else
      age=$(( (n - e) / 60 ))
      if [ "$age" -gt "$STALE_MIN" ]; then state=stale; else state=fresh; fi
    fi
    kind=run; held=0
    if [ -n "$CLASS" ]; then
      case "$id" in "$CLASS"*) kind="$CLASS"; held=1 ;; esac
    fi
    printf '%s %s %s %s\t%s\n' "$age" "$state" "$kind" "$held" "$line"
  done < "$F"
}

cmd="${1:-}"
case "$cmd" in
  add)
    [ $# -eq 2 ] && [ -n "$2" ] && [ "${2#-}" = "$2" ] || usage
    mkdir -p "$(dirname "$F")"
    lock_mutex
    printf '%s %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$2" >> "$F"
    unlock_mutex
    cat "$F" ;;
  remove)
    [ $# -eq 2 ] && [ -n "$2" ] || usage
    [ -f "$F" ] || exit 0
    lock_mutex
    if [ "$2" = --stale ]; then
      classify | awk -F '\t' '$1 !~ / stale / { print $2 }' > "$F.tmp.$$"
    else
      awk -v id="$2" '{ if ($NF != id && NF > 0) print }' "$F" > "$F.tmp.$$"
    fi
    if [ -s "$F.tmp.$$" ]; then mv "$F.tmp.$$" "$F"; else rm -f "$F.tmp.$$" "$F"; fi
    unlock_mutex ;;
  check)
    if [ $# -eq 3 ] && [ "$2" = --holder-class ] && [ -n "$3" ] \
        && printf '%s' "$3" | grep -Eq '^[A-Za-z0-9._-]+$'; then
      CLASS="$3"
    elif [ $# -ne 1 ]; then
      usage
    fi
    out="$(classify)"
    [ -n "$out" ] || exit 0
    printf '%s\n' "$out" | while IFS="$(printf '\t')" read -r meta line; do
      set -- $meta
      if [ "$1" = - ]; then printf 'unreadable, stale %s %s\n' "$3" "$line"
      else printf '%smin %s %s %s\n' "$1" "$2" "$3" "$line"; fi
    done
    fresh="$(printf '%s\n' "$out" | awk -F '\t' '$1 ~ / fresh /')"
    [ -n "$fresh" ] || exit 0
    if printf '%s\n' "$fresh" | awk -F '\t' '$1 !~ / 1$/ { found = 1 } END { exit !found }'; then
      exit 4
    fi
    exit 3 ;;
  *) usage ;;
esac
