#!/usr/bin/env bash
# Tests for studio-unattended's wake_lock.sh: add appends and prints the
# file, two writers keep both lines, remove takes only its own id, an emptied
# file is deleted, --stale drops lines over four hours old, check's output
# and exit codes with and without --holder-class, and the config lookup.
#   bash kit/tests/wake_lock_test.sh
# WAKE_LOCK_FILE points at a throwaway directory, so no project's lock file
# is touched. One line per case; exit 1 if any fails.
set -euo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export WAKE_LOCK_FILE="$TMP/.wake-lock"
export WAKE_LOCK_STALE_HOURS=4
WL="$KIT/plugins/studio-unattended/scripts/wake_lock.sh"
FAILS=0
check() { # name, command...
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; FAILS=1; fi
}
iso_ago() { # minutes ago -> ISO timestamp (macOS, then GNU date)
  local e=$(( $(date +%s) - $1 * 60 ))
  date -r "$e" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || date -d "@$e" +%Y-%m-%dT%H:%M:%S%z
}
wl() { bash "$WL" "$@"; }
code_of() { local c=0; wl "$@" > "$TMP/out" 2>&1 || c=$?; echo "$c"; }
lines() { if [ -f "$WAKE_LOCK_FILE" ]; then grep -c . "$WAKE_LOCK_FILE" || true; else echo 0; fi; }

# add: appends one line and prints the file
rm -f "$WAKE_LOCK_FILE"
wl add wake-up > "$TMP/out"
check "add writes one line" test "$(lines)" -eq 1
check "add line is '<ISO> wake-up'" grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{4} wake-up$' "$WAKE_LOCK_FILE"
check "add prints the file" cmp -s "$TMP/out" "$WAKE_LOCK_FILE"

# two writers: both lines kept, neither overwritten
wl add steer > /dev/null &
wl add steer-twin > /dev/null &
wait
check "two writers keep three lines" test "$(lines)" -eq 3
check "steer line present" grep -q ' steer$' "$WAKE_LOCK_FILE"
check "second writer's line present" grep -q ' steer-twin$' "$WAKE_LOCK_FILE"

# remove own only
wl remove steer-twin
check "remove takes only its own line" test "$(lines)" -eq 2
check "other lines stay" grep -q ' wake-up$' "$WAKE_LOCK_FILE"
check "steer line stays" grep -q ' steer$' "$WAKE_LOCK_FILE"

# check: fresh steer plus fresh wake-up -> exit 4
check "check exit 4 with a fresh wake-up line" test "$(code_of check --holder-class steer)" -eq 4
check "check prints age, state, kind, line" grep -Eq '^[0-9]+min fresh run .* wake-up$' "$TMP/out"
check "check names the holder-class line" grep -Eq '^[0-9]+min fresh steer .* steer$' "$TMP/out"

# only the holder class fresh -> exit 3; without the flag every line blocks
wl remove wake-up
check "check exit 3 with only holder-class lines" test "$(code_of check --holder-class steer)" -eq 3
check "without --holder-class any fresh line blocks (exit 4)" test "$(code_of check)" -eq 4
check "without --holder-class the kind is 'run'" grep -Eq '^[0-9]+min fresh run .* steer$' "$TMP/out"
check "a class that matches no line blocks (exit 4)" test "$(code_of check --holder-class other)" -eq 4
check "--holder-class run does not make every line non-blocking" test "$(code_of check --holder-class run)" -eq 4
check "--holder-class without a name is a usage error" test "$(code_of check --holder-class)" -eq 2
check "check with a stray argument is a usage error" test "$(code_of check steer)" -eq 2

# empty -> file deleted
wl remove steer
check "emptied file is deleted" test ! -e "$WAKE_LOCK_FILE"
check "check exit 0 with no file" test "$(code_of check)" -eq 0
check "remove with no file exits 0" test "$(code_of remove steer)" -eq 0

# stale removal: a 300-minute-old wake-up line goes, a fresh steer line stays
printf '%s wake-up\n' "$(iso_ago 300)" > "$WAKE_LOCK_FILE"
printf '%s steer\n' "$(iso_ago 10)" >> "$WAKE_LOCK_FILE"
code_of check --holder-class steer > "$TMP/code"
check "check marks the old line stale" grep -Eq '^3[0-9]{2}min stale run ' "$TMP/out"
check "a stale wake-up line does not count (exit 3)" test "$(cat "$TMP/code")" -eq 3
wl remove --stale
check "remove --stale drops the old line" test "$(lines)" -eq 1
check "remove --stale keeps the fresh line" grep -q ' steer$' "$WAKE_LOCK_FILE"

# only stale lines -> exit 0, and --stale then deletes the file
printf '%s steer\n' "$(iso_ago 250)" > "$WAKE_LOCK_FILE"
check "check exit 0 with only stale lines" test "$(code_of check)" -eq 0
wl remove --stale
check "remove --stale of the last line deletes the file" test ! -e "$WAKE_LOCK_FILE"

# a line with any other id (a task id) blocks
printf '%s T-12\n' "$(iso_ago 5)" > "$WAKE_LOCK_FILE"
check "a task-id line blocks (exit 4)" test "$(code_of check --holder-class steer)" -eq 4

# timestamp forms: Z and +HH:MM are read; anything else is unreadable, stale
iso_colon() { local t; t="$(iso_ago "$1")"; echo "${t%??}:${t#"${t%??}"}"; }
utc_z() { local e=$(( $(date +%s) - $1 * 60 )); date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ; }
printf '%s steer\n' "$(utc_z 5)" > "$WAKE_LOCK_FILE"
check "a 'Z' stamp is read (fresh steer, exit 3)" test "$(code_of check --holder-class steer)" -eq 3
check "a 'Z' stamp shows its age" grep -Eq '^[4-6]min fresh steer ' "$TMP/out"
printf '%s wake-up\n' "$(iso_colon 5)" > "$WAKE_LOCK_FILE"
check "a '+HH:MM' stamp is read (fresh wake-up, exit 4)" test "$(code_of check)" -eq 4
printf '%s wake-up\n' "$(iso_colon 300)" > "$WAKE_LOCK_FILE"
check "an old '+HH:MM' stamp is stale (exit 0)" test "$(code_of check)" -eq 0
printf '2026-10-02 09:02:41 PDT wake-up\n' > "$WAKE_LOCK_FILE"
touch "$WAKE_LOCK_FILE"
check "a legacy 'YYYY-MM-DD HH:MM:SS PDT' line is stale despite a fresh mtime (exit 0)" test "$(code_of check)" -eq 0
check "check prints it as 'unreadable, stale'" grep -q '^unreadable, stale run 2026-10-02 09:02:41 PDT wake-up$' "$TMP/out"
printf 'garbage steer\n' > "$WAKE_LOCK_FILE"
check "an unreadable line is stale (exit 0)" test "$(code_of check)" -eq 0
printf '2026-10-02T09:02:41 steer\n' >> "$WAKE_LOCK_FILE"
check "a stamp with no zone is unreadable (exit 0)" test "$(code_of check)" -eq 0
printf '%s steer\n' "$(iso_ago 5)" >> "$WAKE_LOCK_FILE"
wl remove --stale
check "remove --stale drops unreadable lines, keeps the fresh one" test "$(lines)" -eq 1
check "the kept line is the fresh steer" grep -Eq '^[0-9]{4}-.*T.* steer$' "$WAKE_LOCK_FILE"
rm -f "$WAKE_LOCK_FILE"

# mutex: a live writer's mutex (young) makes add fail and is left in place;
# a stale one (over 30 s) is taken over; ours is removed after the write
export WAKE_LOCK_MUTEX_WAIT=3
mkdir "$WAKE_LOCK_FILE.mutex"
check "add beside a live writer's mutex exits 1" test "$(code_of add wake-up)" -eq 1
check "it says the mutex is held" grep -q 'held by another writer' "$TMP/out"
check "it writes no line" test ! -e "$WAKE_LOCK_FILE"
check "it leaves the other writer's mutex" test -d "$WAKE_LOCK_FILE.mutex"
printf '%s steer\n' "$(iso_ago 5)" > "$WAKE_LOCK_FILE"
check "remove beside a live writer's mutex exits 1" test "$(code_of remove steer)" -eq 1
check "and removes nothing" test "$(lines)" -eq 1
check "and leaves the mutex" test -d "$WAKE_LOCK_FILE.mutex"
old="$(date -r $(( $(date +%s) - 120 )) +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$(( $(date +%s) - 120 ))" +%Y%m%d%H%M.%S)"
touch -t "$old" "$WAKE_LOCK_FILE.mutex"
check "add takes over a stale mutex (exit 0)" test "$(code_of add wake-up)" -eq 0
check "its line is written" test "$(lines)" -eq 2
check "and the mutex is released" test ! -e "$WAKE_LOCK_FILE.mutex"
unset WAKE_LOCK_MUTEX_WAIT
rm -f "$WAKE_LOCK_FILE"

# stale hours from the env override: a 90-minute-old line is stale at 1 hour
printf '%s wake-up\n' "$(iso_ago 90)" > "$WAKE_LOCK_FILE"
check "a 90-minute line is fresh at 4 hours (exit 4)" test "$(code_of check)" -eq 4
check "and stale at WAKE_LOCK_STALE_HOURS=1 (exit 0)" test "$(WAKE_LOCK_STALE_HOURS=1 bash "$WL" check >/dev/null 2>&1; echo $?)" -eq 0
rm -f "$WAKE_LOCK_FILE"

# config: with no env overrides the file and stale hours come from
# .claude/studio.json under CLAUDE_PROJECT_DIR
PROJ="$TMP/proj"; mkdir -p "$PROJ/.claude"
printf '{"unattended": {"lock_file": "run/.lock", "stale_hours": 1}}\n' > "$PROJ/.claude/studio.json"
cfg_wl() { env -u WAKE_LOCK_FILE -u WAKE_LOCK_STALE_HOURS CLAUDE_PROJECT_DIR="$PROJ" bash "$WL" "$@"; }
cfg_wl add wake-up > /dev/null
check "config lock_file is used, relative to the project" test -f "$PROJ/run/.lock"
printf '%s wake-up\n' "$(iso_ago 90)" > "$PROJ/run/.lock"
check "config stale_hours is used (90 min stale at 1 h, exit 0)" test "$(cfg_wl check >/dev/null 2>&1; echo $?)" -eq 0
rm -f "$PROJ/.claude/studio.json"
cfg_wl add wake-up > /dev/null
check "with no config the default .wake-lock is used" test -f "$PROJ/.wake-lock"

# worktrees: with no env overrides the lock lives in the main worktree, so a
# remove run from a linked (review) worktree takes the real line
REPO="$TMP/repo"; LINKED="$TMP/repo-review/t1"
git init -q "$REPO"
git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
git -C "$REPO" worktree add -q -b review/t1 "$LINKED"
mkdir -p "$REPO/sub"
git_wl() { (cd "$1" && shift && env -u WAKE_LOCK_FILE -u WAKE_LOCK_STALE_HOURS -u CLAUDE_PROJECT_DIR bash "$WL" "$@"); }
git_wl "$REPO" add wake-up > /dev/null
check "add from main writes the main worktree's lock" test -f "$REPO/.wake-lock"
check "check from a linked worktree sees it (exit 4)" test "$(git_wl "$LINKED" check >/dev/null 2>&1; echo $?)" -eq 4
git_wl "$LINKED" remove wake-up
check "remove from a linked worktree leaves no lock there" test ! -e "$LINKED/.wake-lock"
check "remove from a linked worktree clears main's line" test ! -e "$REPO/.wake-lock"
check "check from main then exits 0" test "$(git_wl "$REPO" check >/dev/null 2>&1; echo $?)" -eq 0
git_wl "$REPO/sub" add wake-up > /dev/null
check "add from a subfolder uses the main worktree's lock" test -f "$REPO/.wake-lock"
rm -f "$REPO/.wake-lock"
# an older git without --path-format takes the fallback
mkdir -p "$TMP/oldgit"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = --path-format=absolute ] && exit 129; done\nexec "%s" "$@"\n' "$(command -v git)" > "$TMP/oldgit/git"
chmod +x "$TMP/oldgit/git"
PATH="$TMP/oldgit:$PATH" git_wl "$LINKED" add wake-up > /dev/null
check "older git: add from a linked worktree uses main's lock" test -f "$REPO/.wake-lock"
PATH="$TMP/oldgit:$PATH" git_wl "$REPO/sub" remove wake-up
check "older git: remove from a subfolder clears it" test ! -e "$REPO/.wake-lock"
(cd "$LINKED" && env -u WAKE_LOCK_FILE -u WAKE_LOCK_STALE_HOURS CLAUDE_PROJECT_DIR="$PROJ" bash "$WL" add steer > /dev/null)
check "CLAUDE_PROJECT_DIR still wins in a linked worktree" grep -q ' steer$' "$PROJ/.wake-lock"
(cd "$LINKED" && env -u CLAUDE_PROJECT_DIR WAKE_LOCK_FILE="$TMP/explicit.lock" bash "$WL" add steer > /dev/null)
check "WAKE_LOCK_FILE still wins in a linked worktree" test -f "$TMP/explicit.lock"

# usage
check "no command is a usage error" test "$(code_of)" -eq 2
check "add without id is a usage error" test "$(code_of add)" -eq 2
check "add with a flag id is a usage error" test "$(code_of add --stale)" -eq 2

exit "$FAILS"
