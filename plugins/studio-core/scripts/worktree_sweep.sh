#!/usr/bin/env bash
# The worktree sweep: removes a linked git worktree once its work is finished
# and on main, so review worktrees (hundreds of MB each with their modules)
# stop filling the disk. Run it from a scheduled job, and by hand.
#
#   worktree_sweep.sh            dry run: says what it would do
#   worktree_sweep.sh --remove   removes the worktrees that pass
#
# Only worktrees under the worktree root are swept: core.worktree_root from
# .claude/studio.json (relative to the repo root when not absolute), or
# ../<repo-name>-review beside the main worktree when that is empty. A
# worktree elsewhere was made by hand for something else and is kept.
#
# A worktree is removed only when every rule holds, checked in this order:
#   0. it is under the worktree root;
#   1. it is not the main worktree and it is not locked (`git worktree lock`:
#      a run that leaves a worktree idle longer than rule 4 allows locks it,
#      skill self-review; review runs do not
#      lock the worktree they are working in, so rules 4 and 5 guard those);
#   2. its HEAD is an ancestor of origin/main: every commit is on main;
#   3. `git status --porcelain` is empty: nothing uncommitted or untracked;
#   4. nothing in it changed for SWEEP_IDLE_MINUTES (default 360), neither its
#      files (modules left out) nor its git admin files, so a run that has just
#      made the worktree and not yet changed anything keeps it;
#   5. no process has its working directory or an open file in it, or names it
#      on its command line (one snapshot, taken at the start);
#   6. every ignored file it holds is either known to be rebuilt (modules,
#      build output, test reports, caches, logs, generated files) or byte for
#      byte the same as the main worktree's file at the same path. Anything else
#      may be meant for reuse: the worktree is kept and each such path printed,
#      for the next run to give it a home.
#
# Output, one line per worktree, then a summary:
#   keep <path> <reason>               reason: outside-root, locked,
#                                      not-on-main, dirty, recent, in-use,
#                                      artifacts
#   artifact <path> <relative path>    one per path that held it (rule 6)
#   would-remove <path> <MB>MB         dry run
#   removed <path> <MB>MB [branch <b> deleted]
#   failed <path> <git's message>
#   swept removed=<n> kept=<n> held-for-artifacts=<n> freed=<MB>MB
# Removal deletes node_modules links first (they may point into the main
# worktree, whose files must survive), then
# `git worktree remove` without --force (git refuses a tree that turned
# dirty), then the local branch when its tip is on
# main. Remote branches are left alone. `git worktree prune` runs first.
# Exit codes: 0 done, 2 not a git repository, usage, or an unreadable config.
# Env (tests): SWEEP_REPO the repository (default: the git top level of the
# current directory), SWEEP_MAIN_REF (default <core.remote>/<core.main_branch>),
# SWEEP_NO_FETCH=1 skips the fetch, SWEEP_IDLE_MINUTES.
set -u
# No git call here may refresh a worktree's index: that write would make the
# worktree look recently used to rule 4 on the next run.
export GIT_OPTIONAL_LOCKS=0

REMOVE=0
case "${1:-}" in
  --remove) REMOVE=1 ;;
  "") ;;
  *) echo "usage: $0 [--remove]" >&2; exit 2 ;;
esac

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${SWEEP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
IDLE="${SWEEP_IDLE_MINUTES:-360}"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repository: $REPO" >&2; exit 2; }
MAIN_WT="$(git -C "$REPO" worktree list --porcelain | awk '/^worktree /{sub(/^worktree /,""); print; exit}')"

conf() { # dotted key: one config value, read at the main worktree
  python3 "$DIR/studio_config.py" get "$1" --root "$MAIN_WT" --format lines
}
REMOTE="$(conf core.remote)" || { echo "could not read core.remote from the config" >&2; exit 2; }
if [ -n "${SWEEP_MAIN_REF:-}" ]; then MAIN_REF="$SWEEP_MAIN_REF"
else
  MAIN_BRANCH="$(conf core.main_branch)" || { echo "could not read core.main_branch from the config" >&2; exit 2; }
  MAIN_REF="$REMOTE/$MAIN_BRANCH"
fi
ROOT_CONF="$(conf core.worktree_root)" || { echo "could not read core.worktree_root from the config" >&2; exit 2; }
case "$ROOT_CONF" in
  "") WT_ROOT="$(dirname "$MAIN_WT")/$(basename "$MAIN_WT")-review" ;;
  /*) WT_ROOT="$ROOT_CONF" ;;
  *)  WT_ROOT="$MAIN_WT/$ROOT_CONF" ;;
esac
# Compare real paths, so a symlinked temp dir or a "../" in the config match.
if [ -d "$WT_ROOT" ]; then WT_ROOT="$(cd "$WT_ROOT" && pwd -P)"; fi
WT_ROOT="${WT_ROOT%/}"

if [ "${SWEEP_NO_FETCH:-0}" != 1 ]; then
  git -C "$REPO" fetch -q "$REMOTE" 2>/dev/null || echo "note fetch failed; using the local $MAIN_REF"
fi
[ "$REMOVE" = 1 ] && git -C "$REPO" worktree prune

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Snapshots of every process, taken before this script touches any worktree
# (git -C runs inside the worktree, and the grep below would match itself).
lsof -n -w -Fn 2>/dev/null | sed -n 's/^n//p' > "$TMP/open" || true
ps -axww -o command= > "$TMP/ps" 2>/dev/null || true
# lsof always lists at least its own working directory: an empty list means it
# failed, and rule 5 cannot be checked, so nothing is removed this run.
if [ ! -s "$TMP/open" ] || [ ! -s "$TMP/ps" ]; then
  echo "note process list unreadable; dry run only"; REMOVE=0
fi

# Ignored paths that are always rebuilt, matched on the path's last part.
disposable() { # relative path (a directory ends in /)
  local p="${1%/}" b
  b="${p##*/}"
  case "$b" in
    node_modules|.react-router|build|dist|playwright-report|test-results|blob-report) return 0 ;;
    __pycache__|*.pyc|.venv|.DS_Store|*.log|.cache|.turbo|coverage|.vite) return 0 ;;
    .build|DerivedData|*.xcresult|xcuserdata) return 0 ;;
  esac
  return 1
}

same_as_shared() { # relative path: the main worktree holds the same bytes
  local p="${1%/}"
  [ -e "$MAIN_WT/$p" ] || return 1
  if [ -d "$W/$p" ]; then diff -rq "$W/$p" "$MAIN_WT/$p" >/dev/null 2>&1
  else cmp -s "$W/$p" "$MAIN_WT/$p"; fi
}

in_use() { # real path; prints the first match
  local hit
  hit="$(awk -v a="$1" -v b="$2" 'index($0, a "/") == 1 || $0 == a || index($0, b "/") == 1 || $0 == b {print; exit}' "$TMP/open")"
  [ -n "$hit" ] && { echo "open-file:$hit"; return 0; }
  # Every occurrence counts unless a name character follows (t279 is not t279-roles).
  hit="$(awk -v a="$1" -v b="$2" 'function has(x,  r,i,c){r=$0; while((i=index(r,x))>0){c=substr(r,i+length(x),1); if(c !~ /[A-Za-z0-9._-]/)return 1; r=substr(r,i+1)} return 0} has(a)||has(b){print; exit}' "$TMP/ps")"
  [ -n "$hit" ] && { echo "process:${hit:0:80}"; return 0; }
  return 1
}

size_mb() { du -sk "$1" 2>/dev/null | awk '{printf "%d", $1/1024}'; }

REMOVED=0; KEPT=0; HELD=0; FREED=0
git -C "$REPO" worktree list --porcelain > "$TMP/list"
# Blocks separated by blank lines: worktree, HEAD, branch|detached, locked, prunable.
awk 'BEGIN{RS=""; FS="\n"} {w=""; br=""; lk=0; for(i=1;i<=NF;i++){ if($i ~ /^worktree /){w=substr($i,10)} else if($i ~ /^branch /){br=substr($i,8)} else if($i ~ /^locked/){lk=1} } print lk "|" br "|" w}' "$TMP/list" > "$TMP/rows"

# "|", not a tab: read collapses an empty field between two tabs (a detached HEAD).
while IFS="|" read -r LOCKED BRANCH W; do
  [ -n "$W" ] || continue
  if [ "$W" = "$MAIN_WT" ]; then continue; fi
  [ -d "$W" ] || continue   # gone from disk: prune handles it
  keep() { echo "keep $W $1"; KEPT=$((KEPT + 1)); }
  case "$(cd "$W" && pwd -P)/" in
    "$WT_ROOT"/*) ;;
    *) keep "outside-root ($WT_ROOT)"; continue ;;
  esac
  if [ "$LOCKED" = 1 ]; then keep locked; continue; fi
  HEAD="$(git -C "$W" rev-parse HEAD 2>/dev/null)" || { keep "not-on-main (no HEAD)"; continue; }
  if ! git -C "$REPO" merge-base --is-ancestor "$HEAD" "$MAIN_REF" 2>/dev/null; then
    n="$(git -C "$REPO" rev-list --count "$MAIN_REF..$HEAD" 2>/dev/null || echo '?')"
    keep "not-on-main ($n commits)"; continue
  fi
  st="$(git -C "$W" status --porcelain 2>/dev/null)" || { keep "dirty (status failed)"; continue; }
  if [ -n "$st" ]; then keep "dirty ($(printf '%s\n' "$st" | wc -l | tr -d ' ') paths)"; continue; fi
  GITDIR="$(git -C "$W" rev-parse --absolute-git-dir 2>/dev/null)"
  recent="$(find "$W" \( -name node_modules -o -name .git \) -prune -o -mmin "-$IDLE" -print 2>/dev/null | head -1)"
  [ -z "$recent" ] && [ -n "$GITDIR" ] && recent="$(find "$GITDIR" -type f -mmin "-$IDLE" -print 2>/dev/null | head -1)"
  if [ -n "$recent" ]; then keep "recent (changed within $IDLE min: ${recent#$W/})"; continue; fi
  REAL="$(cd "$W" && pwd -P)"
  if why="$(in_use "$W" "$REAL")"; then keep "in-use ($why)"; continue; fi
  git -C "$W" ls-files --others --ignored --exclude-standard --directory 2>/dev/null > "$TMP/ignored"
  : > "$TMP/held"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    disposable "$p" && continue
    same_as_shared "$p" && continue
    echo "$p" >> "$TMP/held"
  done < "$TMP/ignored"
  if [ -s "$TMP/held" ]; then
    keep "artifacts ($(grep -c . "$TMP/held") paths)"; HELD=$((HELD + 1))
    while IFS= read -r p; do echo "artifact $W $p"; done < "$TMP/held"
    continue
  fi
  MB="$(size_mb "$W")"
  if [ "$REMOVE" != 1 ]; then echo "would-remove $W ${MB}MB"; continue; fi
  # Check the commit rule again just before removing. No --force: git itself
  # refuses a worktree that turned dirty after the checks above.
  if ! git -C "$REPO" merge-base --is-ancestor "$(git -C "$W" rev-parse HEAD)" "$MAIN_REF"; then
    keep "not-on-main (changed during the sweep)"; continue
  fi
  find "$W" \( -name .git -o -name node_modules -type d \) -prune -o -name node_modules -type l -print 2>/dev/null |
    while IFS= read -r l; do rm -f "$l"; done
  if out="$(git -C "$REPO" worktree remove "$W" 2>&1)"; then
    note=""
    if [ -n "$BRANCH" ]; then
      b="${BRANCH#refs/heads/}"
      if git -C "$REPO" merge-base --is-ancestor "$BRANCH" "$MAIN_REF" 2>/dev/null &&
         git -C "$REPO" branch -D "$b" >/dev/null 2>&1; then note=" branch $b deleted"; fi
    fi
    echo "removed $W ${MB}MB$note"; REMOVED=$((REMOVED + 1)); FREED=$((FREED + MB))
  else
    echo "failed $W $(printf '%s' "$out" | tr '\n' ' ')"; KEPT=$((KEPT + 1))
  fi
done < "$TMP/rows"

echo "swept removed=$REMOVED kept=$KEPT held-for-artifacts=$HELD freed=${FREED}MB"
exit 0
