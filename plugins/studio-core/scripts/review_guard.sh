#!/usr/bin/env bash
# The review guard: nothing that touches a reviewed path reaches the main
# branch without its two review passes, the author's and a fresh reviewer
# agent's (skill self-review). Run it from the repo it checks.
#
#   review_guard.sh push [--source REV]
#                                 before any push to main, and before a
#                                 production deploy: walks the first-parent
#                                 commits the remote's main lacks
#                                 (origin/main..main, or origin/main..REV
#                                 with --source: what a push of REV to main
#                                 would bring) and fails on each that touches
#                                 a reviewed path, unless it is a landing
#                                 merge that passes the audit's checks below.
#                                 Without --source it checks the main ref,
#                                 not HEAD, so it gives the same answer from
#                                 any worktree; REV resolves where it runs.
#   review_guard.sh audit FROM    the periodic bypass check: every commit on
#                                 main's first-parent line after FROM
#                                 (FROM..origin/main) that touches a reviewed
#                                 path must be a landing merge whose
#                                 Reviewed-by range, and its
#                                 Fixed-after-review range when it has one,
#                                 covers what it brought in in the reviewed
#                                 paths (a brought-in non-merge commit
#                                 touching only unreviewed paths is not a
#                                 gap; a brought-in merge always is).
#                                 FROM is the origin/main SHA the last audit
#                                 ended at; the first audit starts at the
#                                 first parent of the landing merge that
#                                 introduced this guard.
#   review_guard.sh move BRANCH   run in the main checkout on main after
#                                 `push` exited 1: puts every local commit
#                                 (origin/main..main) on BRANCH
#                                 (review/<date>-<task>), resets main to
#                                 origin/main with --keep (it refuses while
#                                 the index holds a staged change), brings
#                                 each docs-only commit back with a
#                                 cherry-pick (one that conflicts is skipped
#                                 and arrives with the landing), and pushes
#                                 BRANCH. Safe to run again after a refusal:
#                                 it always starts from main's current tip.
#
# Configuration (.claude/studio.json, read with studio_config.py beside this
# script): core.review.reviewed_paths, core.main_branch, core.remote and
# core.review.branch_prefix. "origin", "main" and "review/" above stand for
# those. Every mode reads them from the remote main's committed copy
# (git show origin/main:.claude/studio.json), never from the working tree,
# so an unreviewed local commit that narrows the reviewed paths cannot
# switch the guard off. When the remote main has no copy yet, the reviewed
# paths are the defaults, and the working tree's main branch, remote and
# branch prefix locate things, so the push that lands the first config on a
# repo whose main branch is not "main" is not blocked. The audit uses the
# same copy, at origin/main's tip, for every landing it reads. That is sound
# because .claude/studio.json is always a reviewed path, whatever the config
# says: every change to it on main is a reviewed landing or a gap in this
# same audit. Otherwise the working tree's copy only names the remote and
# the main branch to fetch; when the remote main's copy names others, exit 2.
# Environment overrides, for tests: STUDIO_REVIEWED_PATHS
# (space-separated), STUDIO_MAIN_BRANCH, STUDIO_REMOTE. A config that cannot
# be read, or an empty reviewed path list, is exit 2: the guard fails closed.
#
# A landing merge (skill self-review, the landing step) is a --no-ff merge of
# the review branch onto origin/main whose message has the line
#   Reviewed-by: fresh reviewer agent, <BASE>..<HEAD>, ...
# and, when the author fixed findings after that review (the fresh review is
# the last review; its fixes get no second reviewer), the line
#   Fixed-after-review: author, <HEAD>..<FIX>, ...
# whose range starts at the reviewed <HEAD> and ends at the landed tip, so the
# unreviewed fix commits are named on main. Without that line the landed tip
# is <HEAD>. Only that documented shape is read; a line
# "Fixed-after-review: none" counts as absent, and any other one is a gap.
# It passes the audit when its second parent is the landed tip, every commit
# it brings in outside the reviewed range (on <BASE>'s side, not yet on main:
# <P1>..<BASE>) is a non-merge commit touching only unreviewed paths (plans,
# a journal and the rest, which land straight on main by design; a merge there
# is a gap to audit by hand, since a first-parent diff hides one that drops
# main's side; one git cannot list is a gap),
# and in the reviewed paths it is exactly the merge its two parents make on
# their own (git merge-tree): no conflict there, and no hand in the result.
# A conflict in a reviewed path is a gap however it was resolved (by hand,
# -X ours or theirs, checkout --ours or --theirs), because a reviewer read
# neither the resolution nor what a taken side threw away; a git show --cc
# prints nothing for a file taken whole from one side. Such a conflict is
# resolved on the branch instead (skill self-review), and the landing then
# merges clean. A resolution in a docs file such as a task list is not a gap.
#
# Exit 0 clean, 1 findings (one line each on stdout), 2 usage or git error.
# A git failure never passes a commit. In push it is exit 2. In the audit,
# git failing on one commit (listing its paths, merge-tree, the diff after it)
# is a finding for that commit, "audit it by hand", and the audit goes on. In
# move, git failing to list the local commits before the reset is exit 2 with
# nothing changed. After the reset nothing stops the move silently: a failure
# to list the commits is a REWRITE ON MAIN line, a failure to find BASE prints
# BASE=unknown, a commit whose paths git cannot list stays on the branch, a
# code commit whose docs git cannot list is named mixed, a cherry-pick whose
# state git cannot read is a conflict, and a failed check for unmerged files
# after the loop is exit 1 once the branch is pushed.
# Plain bash 3.2: macOS still ships it as /bin/bash.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEWED_PATHS=()
MAIN=""
REMOTE=""
PREFIX=""
RM=""   # the remote's main, e.g. origin/main
TMPD=""

die() { echo "review_guard: $*" >&2; exit 2; }

CONFIG_PATH=".claude/studio.json"   # always reviewed, whatever it says
REMOTE_CFG=""   # a file holding the remote main's copy; empty for the defaults

# One config value as lines: $1 the dotted key, $2 "remote" to read the
# remote main's copy (load_config fetches it first) instead of the working
# tree's. Any failure is exit 2.
config_get() {
  local root
  if [[ "${2:-}" == remote ]]; then
    if [[ -n "$REMOTE_CFG" ]]; then
      python3 "$DIR/studio_config.py" get "$1" --file "$REMOTE_CFG" --format lines \
        || die "could not read $1 from $RM:$CONFIG_PATH; fix the config"
    else
      # No copy on the remote main: the defaults. An empty directory holds no
      # config, so the loader returns them.
      python3 "$DIR/studio_config.py" get "$1" --root "$TMPD" --format lines \
        || die "could not read the default $1"
    fi
    return
  fi
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  python3 "$DIR/studio_config.py" get "$1" --root "$root" --format lines \
    || die "could not read $1 from the config ($CONFIG_PATH); fix the config"
}

# Fetches the remote main and fills REVIEWED_PATHS, MAIN, REMOTE, PREFIX and
# RM: the environment first, the rest from the remote main's copy.
load_config() {
  local raw line want sha top
  # Pathspecs are relative to the current directory: run from the top, so a
  # run from a subdirectory sees every reviewed path.
  top="$(git rev-parse --show-toplevel 2>/dev/null)" && cd "$top"
  TMPD="$(mktemp -d)" || die "could not make a temporary directory"
  trap 'rm -rf "$TMPD"' EXIT
  # Which remote and branch to fetch: the environment, else the working tree.
  if [[ -n "${STUDIO_MAIN_BRANCH:-}" ]]; then MAIN="$STUDIO_MAIN_BRANCH"; else MAIN="$(config_get core.main_branch)" || exit 2; fi
  if [[ -n "${STUDIO_REMOTE:-}" ]]; then REMOTE="$STUDIO_REMOTE"; else REMOTE="$(config_get core.remote)" || exit 2; fi
  [[ -n "$MAIN" && -n "$REMOTE" ]] || die "core.main_branch and core.remote must not be empty"
  RM="$REMOTE/$MAIN"
  fetch_main
  # ls-tree prints nothing with exit 0 when the file is absent, so a git
  # failure is never read as "no config, use the defaults".
  raw="$(git ls-tree --full-tree "$RM" -- "$CONFIG_PATH")" || die "could not look for $CONFIG_PATH on $RM"
  if [[ -n "$raw" ]]; then
    sha="$(printf '%s\n' "$raw" | awk '{print $3}')"
    REMOTE_CFG="$TMPD/studio.json"
    git cat-file blob "$sha" > "$REMOTE_CFG" || die "could not read $CONFIG_PATH from $RM"
  fi
  # The names are compared only against a committed copy. With none on the
  # remote main yet, the working tree's names locate things (the defaults
  # would name a main branch the repo may not have, and block the very push
  # that lands the config); the reviewed paths are still the defaults.
  if [[ -n "$REMOTE_CFG" && -z "${STUDIO_MAIN_BRANCH:-}" ]]; then
    want="$(config_get core.main_branch remote)" || exit 2
    [[ "$want" == "$MAIN" ]] || die "the working tree's config names main branch '$MAIN' but $RM's copy names '$want'; land the config change through review"
  fi
  if [[ -n "$REMOTE_CFG" && -z "${STUDIO_REMOTE:-}" ]]; then
    want="$(config_get core.remote remote)" || exit 2
    [[ "$want" == "$REMOTE" ]] || die "the working tree's config names remote '$REMOTE' but $RM's copy names '$want'; land the config change through review"
  fi
  if [[ -n "${STUDIO_REVIEWED_PATHS:-}" ]]; then
    # Split on spaces with globbing off, so a "*" stays a word.
    set -f
    # shellcheck disable=SC2086
    raw="$(printf '%s\n' $STUDIO_REVIEWED_PATHS)"
    set +f
  else
    raw="$(config_get core.review.reviewed_paths remote)" || exit 2
  fi
  REVIEWED_PATHS=()
  while IFS= read -r line; do
    line="${line%/}"
    if [[ -n "$line" ]]; then REVIEWED_PATHS+=("$line"); fi
  done <<EOF
$raw
EOF
  (( ${#REVIEWED_PATHS[@]} > 0 )) || die "no reviewed paths configured (core.review.reviewed_paths is empty)"
  # Appended last: the tests' git shims match the first pathspec.
  REVIEWED_PATHS+=("$CONFIG_PATH")
  if [[ -n "$REMOTE_CFG" ]]; then
    PREFIX="$(config_get core.review.branch_prefix remote)" || exit 2
  else
    PREFIX="$(config_get core.review.branch_prefix)" || exit 2
  fi
  [[ -n "$PREFIX" ]] || die "core.review.branch_prefix must not be empty"
}

subject() { git log -1 --format='%h %s' "$1"; }

# True when path $1 is, or is under, one of REVIEWED_PATHS.
in_reviewed() {
  local p
  for p in "${REVIEWED_PATHS[@]}"; do
    [[ "$1" == "$p" || "$1" == "$p"/* ]] && return 0
  done
  return 1
}

fetch_main() {
  git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
  git fetch -q "$REMOTE" "$MAIN" || die "git fetch $REMOTE $MAIN failed"
  git rev-parse -q --verify "$RM" >/dev/null || die "no $RM"
}

# Paths under REVIEWED_PATHS that commit $1 changes against its first parent
# (against the empty tree for a root commit). One git call, so no failure can
# be read as "this is a root commit": --root covers a root, and
# --diff-merges=first-parent gives a merge its first-parent paths (a plain
# diff-tree on a merge prints nothing with exit 0). Its status is git's: call
# it as `paths="$(changed_paths "$c")" || ...`, never inside [[ ]], where a
# failure reads as an empty list.
changed_paths() {
  git diff-tree --no-commit-id --name-only -r --root --diff-merges=first-parent "$1" -- "${REVIEWED_PATHS[@]}"
}

cmd_push() {
  local src="$1" tip label bad=0 c commits paths
  if [[ -n "$src" ]]; then
    tip="$(git rev-parse -q --verify "$src^{commit}")" || die "push: --source '$src' is not a commit here; push nothing"
    label="pushed to $MAIN"
  else
    git rev-parse -q --verify "refs/heads/$MAIN" >/dev/null || die "no local $MAIN branch"
    tip="$MAIN"; label="on $MAIN"
  fi
  commits="$(git rev-list --first-parent "$RM..$tip")" || die "push: could not list the local commits on $MAIN; push nothing"
  for c in $commits; do
    paths="$(changed_paths "$c")" || die "push: could not list the paths of $(subject "$c"); push nothing"
    [[ -n "$paths" ]] || continue
    # The audit's own check: a plain commit is unreviewed, and a merge passes
    # only as a landing merge whose trailers cover what it brings in.
    check_landing "$c" "unreviewed local commit $label" || bad=1
  done
  return "$bad"
}

# Whether first-parent commit $1, which touches a reviewed path, is a
# reviewed landing merge (the shape described at the top). Prints one line
# and returns 1 when it is not; $2 opens the line for a commit with one
# parent. Shared by push and audit, so both read a landing the same way.
check_landing() {
  local c="$1" direct="$2" parents p1 p2 range base head mt rc auto conflict f
  local fixline fixrange fbase fhead landed merges_in uncovered stray u upaths none_re
  # shellcheck disable=SC2207
  parents=($(git rev-list --parents -n 1 "$c"))
  if (( ${#parents[@]} < 3 )); then
    echo "$direct: $(subject "$c")"
    return 1
  fi
  if (( ${#parents[@]} > 3 )); then
    echo "gap: merge with more than two parents: $(subject "$c")"
    return 1
  fi
  p1="${parents[1]}"; p2="${parents[2]}"
  range="$(git log -1 --format=%B "$c" | grep -E '^Reviewed-by:' | grep -oE '[0-9a-f]{7,40}\.\.[0-9a-f]{7,40}' | tail -n 1 || true)"
  if [[ -z "$range" ]]; then
    echo "gap: merge touching reviewed paths with no Reviewed-by range: $(subject "$c")"
    return 1
  fi
  if ! base="$(git rev-parse -q --verify "${range%%..*}^{commit}")" \
     || ! head="$(git rev-parse -q --verify "${range##*..}^{commit}")"; then
    echo "gap: Reviewed-by range $range does not resolve to two commits: $(subject "$c")"
    return 1
  fi
  # Only the documented shape is read: "author, <HEAD>..<FIX>" at the
  # start, so a range in the findings text after it is never taken. A line
  # "none", alone or followed only by a note in parentheses, counts as
  # absent; any other line ("none, author ..." included) is a gap.
  fixline="$(git log -1 --format=%B "$c" | grep -E '^Fixed-after-review:' | head -n 1 | tr -d '\r' || true)"
  fixrange=""
  none_re='^Fixed-after-review:[[:space:]]*none([[:space:]]*\(.*\))?[[:space:]]*$'
  if [[ -n "$fixline" ]] && ! [[ "$fixline" =~ $none_re ]]; then
    fixrange="$(printf '%s\n' "$fixline" | sed -nE 's/^Fixed-after-review: author, ([0-9a-f]{7,40}\.\.[0-9a-f]{7,40})([,[:space:]].*)?$/\1/p')"
    if [[ -z "$fixrange" ]]; then
      echo "gap: Fixed-after-review line is not the documented shape ($fixline): $(subject "$c")"
      return 1
    fi
  fi
  landed="$head"
  if [[ -n "$fixrange" ]]; then
    if ! fbase="$(git rev-parse -q --verify "${fixrange%%..*}^{commit}")" \
       || ! fhead="$(git rev-parse -q --verify "${fixrange##*..}^{commit}")"; then
      echo "gap: Fixed-after-review range $fixrange does not resolve to two commits: $(subject "$c")"
      return 1
    fi
    # A git failure in the ancestor check is a gap, never a pass.
    if [[ "$fbase" != "$head" ]] || ! git merge-base --is-ancestor "$head" "$fhead"; then
      echo "gap: the author's fixes $fixrange do not start where the review ended ($(git rev-parse --short "$head")): $(subject "$c")"
      return 1
    fi
    # A reviewed head already on main means the review read nothing this
    # landing brings, so everything would arrive as "fixes". A git failure
    # here (exit 128) also counts as already on main: a gap, never a pass.
    rc=0; git merge-base --is-ancestor "$head" "$p1" || rc=$?
    if (( rc != 1 )); then
      echo "gap: the review range ends at $(git rev-parse --short "$head"), already on main, so the author's fixes $fixrange carry unreviewed work: $(subject "$c")"
      return 1
    fi
    landed="$fhead"
  fi
  if [[ "$landed" != "$p2" ]]; then
    if [[ -n "$fixrange" ]]; then
      echo "gap: merge lands $(git rev-parse --short "$p2") but the review and the author's fixes end at $(git rev-parse --short "$landed"): $(subject "$c")"
    else
      echo "gap: merge lands $(git rev-parse --short "$p2") but the review read up to $(git rev-parse --short "$head"): $(subject "$c")"
    fi
    return 1
  fi
  # What the merge brings in outside the ranges: the commits on the review
  # base's side that main lacked before the merge (P1..BASE). A merge among
  # them is always a gap: one that keeps its own tree and drops main's side
  # (merge -s ours, a hand-edited result) shows no reviewed path under a
  # first-parent diff, yet the landing then reverts reviewed code on main.
  # A non-merge one touching a reviewed path is a gap; one touching only
  # unreviewed paths (a plan, a journal line) could have landed straight on
  # main, so it is not.
  if ! merges_in="$(git rev-list --merges "$p1..$base")"; then
    echo "gap: could not list the merges the merge brings in outside the review, audit it by hand: $(subject "$c")"
    return 1
  fi
  if [[ -n "$merges_in" ]]; then
    echo "gap: review base $(git rev-parse --short "$base") is not on main before the merge, and the merge brings in a merge (${merges_in:0:7}) no reviewer read, audit it by hand: $(subject "$c")"
    return 1
  fi
  if ! uncovered="$(git rev-list "$p1..$base")"; then
    echo "gap: could not list what the merge brings in outside the review, audit it by hand: $(subject "$c")"
    return 1
  fi
  stray=""
  for u in $uncovered; do
    if ! upaths="$(changed_paths "$u")"; then
      stray="could not list the paths of ${u:0:7}, audit it by hand"; break
    fi
    if [[ -n "$upaths" ]]; then
      stray="the merge brings in ${u:0:7}, which touches a reviewed path no reviewer read"; break
    fi
  done
  if [[ -n "$stray" ]]; then
    echo "gap: review base $(git rev-parse --short "$base") is not on main before the merge, and $stray: $(subject "$c")"
    return 1
  fi
  # Merge the parents again with no hand in it. merge-tree prints the tree
  # first, then one conflicted path per line, and exits 0 clean, 1 on a
  # conflict; a failure prints no tree. A git failure on one landing is a
  # gap, not exit 2: exit 2 is a skipped audit for whoever runs it, and the same
  # landing would stop every later audit and hide the gaps before it.
  rc=0
  mt="$(git -c core.quotePath=false merge-tree --write-tree --name-only --no-messages "$p1" "$p2" 2>/dev/null)" || rc=$?
  auto="${mt%%$'\n'*}"
  if (( rc > 1 )) || [[ ! "$auto" =~ ^[0-9a-f]{40,64}$ ]]; then
    echo "gap: could not re-merge the parents, audit it by hand: $(subject "$c")"
    return 1
  fi
  conflict=""
  if (( rc == 1 )) && [[ "$mt" == *$'\n'* ]]; then
    while IFS= read -r f; do
      # A quoted name cannot be matched safely: count it as reviewed.
      if [[ -n "$f" ]] && { [[ "$f" == \"* ]] || in_reviewed "$f"; }; then conflict="$f"; break; fi
    done <<< "${mt#*$'\n'}"
  fi
  if [[ -n "$conflict" ]]; then
    echo "gap: merge resolved a conflict in a reviewed path ($conflict) that no reviewer read: $(subject "$c")"
    return 1
  fi
  rc=0; git diff --quiet "$auto" "$c" -- "${REVIEWED_PATHS[@]}" || rc=$?
  if (( rc == 1 )); then
    echo "gap: merge differs in a reviewed path from the merge its parents make on their own (a hand edit, or one side taken): $(subject "$c")"
    return 1
  fi
  if (( rc != 0 )); then
    echo "gap: could not compare the merge with its parents' own merge, audit it by hand: $(subject "$c")"
    return 1
  fi
  return 0
}

cmd_audit() {
  local from_arg="$1" from tip
  tip="$(git rev-parse "$RM")"
  from="$(git rev-parse -q --verify "${from_arg}^{commit}")" || die "audit: '$from_arg' is not a commit"
  git merge-base --is-ancestor "$from" "$tip" || die "audit: $from_arg is not on $RM; the history changed, audit by hand"
  local bad=0 c commits paths
  commits="$(git rev-list --first-parent "$from..$tip")" || die "audit: could not list the commits after $from_arg"
  for c in $commits; do
    if ! paths="$(changed_paths "$c")"; then
      echo "gap: could not list the paths, audit it by hand: $(subject "$c")"
      bad=1; continue
    fi
    [[ -n "$paths" ]] || continue
    check_landing "$c" "gap: direct commit to $MAIN touching reviewed paths" || bad=1
  done
  echo "audited through $tip"
  return "$bad"
}

# True only when git itself says a stopped cherry-pick has no unmerged and no
# staged path. A diff that fails is not an empty answer: the pick is then
# treated as a conflict, never skipped as empty.
pick_is_empty() {
  local unmerged staged
  unmerged="$(git diff --name-only --diff-filter=U)" || return 1
  staged="$(git diff --cached --name-only)" || return 1
  [[ -z "$unmerged" && -z "$staged" ]]
}

cmd_move() {
  local t="$1" m c brought="" skipped=""
  [[ "$t" == "$PREFIX"?* ]] || die "move: name the branch ${PREFIX}<date>-<task>"
  [[ "$(git symbolic-ref --short -q HEAD || true)" == "$MAIN" ]] || die "move: run it in the main checkout with $MAIN checked out"
  m="$(git rev-parse "$MAIN")"
  local pending
  pending="$(git rev-list "$RM..$m")" || die "move: could not list the local commits on $MAIN; nothing changed"
  if [[ -z "$pending" ]]; then echo "move: $MAIN has no local commits; nothing to move"; return 0; fi
  if git rev-parse -q --verify "refs/heads/$t" >/dev/null \
     && ! git merge-base --is-ancestor "$t" "$m"; then
    die "move: $t exists and is not part of $MAIN's history (it was rebased or is another change); use a new branch name"
  fi
  git branch -f "$t" "$m" >/dev/null || die "move: could not point $t at $MAIN (is it checked out in a worktree?)"
  [[ "$(git rev-parse "$MAIN")" == "$m" ]] || die "move: $MAIN moved while moving; run move again"
  # reset --keep resets the whole index: another run's staged file would be
  # unstaged, and a staged new file would become untracked.
  if ! git diff --cached --quiet; then
    echo "move: refused, because the index has staged changes (another run is mid-commit) that a reset would unstage."
    echo "move: nothing changed on $MAIN; $t holds the commits locally. Push nothing, journal it, and run the same move again later."
    return 1
  fi
  if ! git reset -q --keep "$RM"; then
    echo "move: reset --keep refused, because another run has an uncommitted edit to a file these commits touch."
    echo "move: nothing changed on $MAIN; $t holds the commits locally. Push nothing, journal it, and run the same move again later."
    return 1
  fi
  # A commit made on main between the check above and the reset is still in
  # the reflog entry the reset wrote: keep it on the branch too.
  local before
  before="$(git rev-parse -q --verify "$MAIN@{1}" || echo "$m")"
  if [[ "$before" != "$m" ]] && git merge-base --is-ancestor "$m" "$before"; then
    m="$before"; git branch -f "$t" "$m" >/dev/null
  fi
  local failed=0 check_failed=0 base mixed="" unlisted="" paths p excludes=() commits listed=1 docs unmerged
  for p in "${REVIEWED_PATHS[@]}"; do excludes+=(":(exclude)$p"); done
  # main is already reset: a git failure from here on cannot undo the move, so
  # none may stop it silently. The commits are safe on the branch; each failure
  # is named on its own line and the branch is still pushed.
  base="$(git merge-base "$RM" "$m")" || base=""
  commits="$(git rev-list --reverse "$RM..$m")" || { commits=""; listed=0; }
  for c in $commits; do
    # A commit whose paths git cannot list may be code: it stays on the branch.
    if ! paths="$(changed_paths "$c")"; then
      unlisted="$unlisted $(git rev-parse --short "$c")"; continue
    fi
    if [[ -n "$paths" ]]; then
      # A mixed commit's docs arrive with the landing; say so. When git cannot
      # tell whether the commit carries docs, count it as mixed.
      if ! docs="$(git diff --name-only "$c^1" "$c" -- . "${excludes[@]}")" || [[ -n "$docs" ]]; then
        mixed="$mixed $(git rev-parse --short "$c")"
      fi
      continue
    fi
    if git cherry-pick "$c" >/dev/null 2>&1; then
      brought="$brought $(git rev-parse --short HEAD)"
    elif git rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null && pick_is_empty; then
      # An empty pick: its change is already on main. Nothing to rewrite.
      git cherry-pick --skip >/dev/null 2>&1 || git cherry-pick --abort >/dev/null 2>&1 || failed=1
    else
      # Abort only a cherry-pick that is in progress. A refusal before it
      # starts (another run's staged edit) leaves nothing to undo, and a
      # reset there would destroy that run's work.
      if git rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null; then
        git cherry-pick --abort >/dev/null 2>&1 || failed=1
      fi
      skipped="$skipped $(git rev-parse --short "$c")"
    fi
  done
  if ! unmerged="$(git diff --name-only --diff-filter=U)"; then
    check_failed=1
  elif git rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null || [[ -n "$unmerged" ]]; then
    failed=1
  fi
  if [[ -n "$base" ]]; then
    echo "move: $t holds $(git rev-list --count "$RM..$m") commit(s) on top of $(git rev-parse --short "$base")"
    echo "move: BASE=$base HEAD=$m"
  else
    echo "move: BASE=unknown HEAD=$m (git merge-base failed; before the review, run: git merge-base $RM $m)"
  fi
  echo "move: docs-only commits brought back to $MAIN (new SHAs):${brought:- none}"
  if (( ! listed )); then echo "move: REWRITE ON MAIN: could not list the commits on $t after main was reset, so no commit was brought back (write the docs of every commit on $t, docs-only and mixed, on main again)"; fi
  if [[ -n "$skipped" ]]; then echo "move: REWRITE ON MAIN: docs-only commits not brought back (a conflict or a refusal; write their facts on main again):$skipped"; fi
  if [[ -n "$mixed" ]]; then echo "move: REWRITE ON MAIN: mixed commits whose docs (journal, task list, state notes) are now missing from $MAIN:$mixed"; fi
  if [[ -n "$unlisted" ]]; then echo "move: REWRITE ON MAIN: commits whose paths git could not list, kept on $t and not brought back (write any docs they carry on main again):$unlisted"; fi
  if (( failed )); then echo "move: a cherry-pick is left unfinished in the main checkout; stop and look before anything else"; return 1; fi
  if git push -q -u "$REMOTE" "$t"; then echo "move: pushed $t"; else echo "move: $MAIN is already reset; push of $t failed, push it by hand (git push -u $REMOTE $t)"; return 1; fi
  if (( check_failed )); then echo "move: git could not check the main checkout for unmerged files; run git status and stop if it shows unmerged paths or a cherry-pick in progress"; return 1; fi
}

case "${1:-}" in
  push)  shift
         if [[ $# -eq 2 && "$1" == --source && -n "$2" ]]; then SRC="$2"
         elif [[ $# -eq 0 ]]; then SRC=""
         else die "push takes no arguments, or --source REV"; fi
         load_config; cmd_push "$SRC" ;;
  audit) shift; [[ $# -eq 1 ]] || die "audit takes one argument: the commit the last audit ended at"; load_config; cmd_audit "$1" ;;
  move)  shift; [[ $# -eq 1 ]] || die "move takes one argument: the review branch name"; load_config; cmd_move "$1" ;;
  *)     die "usage: review_guard.sh push [--source REV] | audit FROM | move BRANCH" ;;
esac
