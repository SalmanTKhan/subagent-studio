#!/usr/bin/env bash
# Tests for studio-core's worktree_sweep.sh: each keep rule (outside the
# worktree root, locked, a
# commit not on main, a modified file, an untracked file, a recent change in
# the files or only in the git admin files, a process whose working directory,
# open file or command line is in it, an unknown ignored file), what may go
# (rebuilt output, a file or link the same as the shared tree's), the sweep
# never refreshing an index itself, the dry run removing nothing, and --remove
# taking the worktree and its merged branch while the shared tree's files
# behind a link survive.
#   bash tests/worktree_sweep_test.sh
# Works in a throwaway repository; the real one is never touched. "Idle" is
# made by backdating every file of a worktree and its admin folder. One line
# per case; exit 1 if any fails.
set -uo pipefail
SW="$(cd "$(dirname "$0")/../plugins/studio-core/scripts" && pwd)/worktree_sweep.sh"
unset CLAUDE_PROJECT_DIR
TMP="$(cd "$(mktemp -d)" && pwd -P)"
PIDS=""
trap 'for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"' EXIT
FAILS=0
check() { # name, command...
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; FAILS=1; fi
}
has() { grep -qF -- "$1" "$TMP/out"; }
admin() { git -C "$TMP/$1" rev-parse --absolute-git-dir; }
backdate() { # worktree names: every file and folder 12 hours old or more
  local w
  for w in "$@"; do
    find "$TMP/$w" "$(admin "$w")" -exec touch -h -t 202601010000 {} + 2>/dev/null
  done
}

M="$TMP/main"
git init -q -b main "$M"
git -C "$M" config user.email t@t; git -C "$M" config user.name t
printf 'node_modules\n.env\n*.log\nbuild/\nkeepme/\n.auth\n.build/\n' > "$M/.gitignore"
echo a > "$M/a.txt"
git -C "$M" add -A && git -C "$M" commit -qm init
mkdir -p "$M/node_modules/pkg" "$M/.authreal"
echo dep > "$M/node_modules/pkg/index.js"
echo token > "$M/.authreal/t"
ln -s "$M/.authreal" "$M/.auth"
echo SECRET=1 > "$M/.env"
# The worktrees below sit beside the repo, in $TMP: make that the root.
mkdir -p "$M/.claude"
printf '{"core": {"worktree_root": ".."}}\n' > "$M/.claude/studio.json"

wt() { git -C "$M" worktree add -q "$@"; }
wt -b merged "$TMP/merged" main
wt --detach "$TMP/detached" main
wt -b locked "$TMP/locked" main && git -C "$M" worktree lock "$TMP/locked"
wt -b ahead "$TMP/ahead" main
echo b > "$TMP/ahead/b.txt"; git -C "$TMP/ahead" add b.txt; git -C "$TMP/ahead" commit -qm ahead
wt -b modified "$TMP/modified" main && echo changed > "$TMP/modified/a.txt"
wt -b untracked "$TMP/untracked" main && echo new > "$TMP/untracked/new.txt"
wt -b cwd "$TMP/cwd" main
wt -b openf "$TMP/openf" main
wt -b cmdline "$TMP/cmdline" main
wt -b held "$TMP/held" main && mkdir "$TMP/held/keepme" && echo proof > "$TMP/held/keepme/video.txt"
wt -b envdiff "$TMP/envdiff" main && echo SECRET=2 > "$TMP/envdiff/.env"
wt -b fresh "$TMP/fresh" main
wt -b adminonly "$TMP/adminonly" main
wt -b fileonly "$TMP/fileonly" main
# Rebuilt output, a copy of the shared .env and links into the shared tree may go.
ln -s "$M/node_modules" "$TMP/merged/node_modules"
ln -s "$M/.authreal" "$TMP/merged/.auth"
mkdir "$TMP/merged/build" "$TMP/merged/.build" && echo out > "$TMP/merged/build/x.js"
echo obj > "$TMP/merged/.build/y.o"
echo log > "$TMP/merged/run.log"
cp "$M/.env" "$TMP/merged/.env"

mkdir "$TMP/fileonly/build"
backdate merged detached locked ahead modified untracked cwd openf cmdline held envdiff adminonly fileonly
touch "$(admin adminonly)/HEAD"   # only the admin folder changed lately
echo new > "$TMP/fileonly/build/x.js"   # only an ignored file changed lately

# Each sleeper is the process its pid names (exec) and holds no pipe, so the
# trap's kill ends it and `test | grep` never waits on it.
(cd "$TMP/cwd" && exec sleep 300) </dev/null >/dev/null 2>&1 & PIDS="$PIDS $!"
(exec 3<"$TMP/openf/a.txt"; exec sleep 300) </dev/null >/dev/null 2>&1 & PIDS="$PIDS $!"
# A longer name sharing the prefix comes first and must not hide the real one.
perl -e 'sleep 300' "$TMP/cmdline-other" "$TMP/cmdline;npm" </dev/null >/dev/null 2>&1 & PIDS="$PIDS $!"
sleep 1

run() { SWEEP_REPO="$M" SWEEP_MAIN_REF=main SWEEP_NO_FETCH=1 SWEEP_IDLE_MINUTES=360 bash "$SW" ${1:-} > "$TMP/out" 2>&1; }

run
check "locked is kept" has "keep $TMP/locked locked"
check "a commit not on main is kept" has "keep $TMP/ahead not-on-main (1 commits)"
check "a modified file is kept" has "keep $TMP/modified dirty"
check "an untracked file is kept" has "keep $TMP/untracked dirty"
check "a fresh worktree is kept as recent" has "keep $TMP/fresh recent"
check "a change only in the admin folder is kept as recent" has "keep $TMP/adminonly recent"
check "a change only in an ignored file is kept as recent" has "keep $TMP/fileonly recent (changed within 360 min: build"
check "a process working inside is kept" has "keep $TMP/cwd in-use (open-file:"
check "a process with a file open inside is kept" has "keep $TMP/openf in-use (open-file:"
check "a process naming it on its command line is kept" has "keep $TMP/cmdline in-use (process:"
check "an unknown ignored file is kept" has "keep $TMP/held artifacts (1 paths)"
check "and its path is printed" has "artifact $TMP/held keepme/"
check "a .env unlike the shared tree's is kept" has "artifact $TMP/envdiff .env"
check "merged would go" has "would-remove $TMP/merged"
check "detached on main would go" has "would-remove $TMP/detached"
check "the main worktree is never listed" bash -c "! grep -q ' $M ' '$TMP/out'"
check "dry run removes nothing" test -d "$TMP/merged"

# The sweep itself must not make a worktree look used: a second dry run
# still finds merged idle.
run
check "a second dry run still finds merged idle" has "would-remove $TMP/merged"

# lsof failing (an empty list) must not switch rule 5 off: no removal.
mkdir "$TMP/bin" && printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/lsof" && chmod +x "$TMP/bin/lsof"
PATH="$TMP/bin:$PATH" run --remove
check "an unreadable process list means dry run only" has "note process list unreadable; dry run only"
check "and nothing is removed" test -d "$TMP/merged"

run --remove
check "merged is removed" has "removed $TMP/merged"
check "its branch is deleted" has "branch merged deleted"
check "merged dir is gone" test ! -e "$TMP/merged"
check "merged branch is gone" bash -c "! git -C '$M' rev-parse -q --verify refs/heads/merged >/dev/null"
check "detached is removed" test ! -e "$TMP/detached"
check "the shared tree's modules survive" test -f "$M/node_modules/pkg/index.js"
check "the shared tree's linked folder survives" test -f "$M/.authreal/t"
check "the shared tree's .env survives" test -f "$M/.env"
for w in locked ahead modified untracked cwd openf cmdline held envdiff fresh adminonly fileonly; do
  check "$w is still there" test -d "$TMP/$w"
done
check "unmerged branch kept" bash -c "git -C '$M' rev-parse -q --verify refs/heads/ahead >/dev/null"
check "summary counts" has "swept removed=2 kept=12 held-for-artifacts=2"

# The worktree root. With no core.worktree_root it is ../main-review: a
# worktree there may go, one beside it in $TMP is kept as outside-root.
rm "$M/.claude/studio.json"
mkdir -p "$TMP/main-review"
wt -b inroot "$TMP/main-review/inroot" main
backdate main-review/inroot
run
check "default root: a worktree under ../<repo>-review would go" has "would-remove $TMP/main-review/inroot"
check "default root: a worktree elsewhere is kept as outside-root" has "keep $TMP/locked outside-root ($TMP/main-review)"
check "default root: an idle worktree elsewhere is kept too" has "keep $TMP/fresh outside-root"
# An absolute root from the config.
printf '{"core": {"worktree_root": "%s"}}\n' "$TMP/elsewhere" > "$M/.claude/studio.json"
mkdir -p "$TMP/elsewhere"
run
check "absolute root: a worktree outside it is kept" has "keep $TMP/main-review/inroot outside-root ($TMP/elsewhere)"
# A config that cannot be read stops the sweep before it touches anything.
printf '{not json\n' > "$M/.claude/studio.json"
SWEEP_REPO="$M" SWEEP_NO_FETCH=1 bash "$SW" --remove > "$TMP/out" 2>&1; rc=$?
check "broken config: exit 2" test "$rc" = 2
check "broken config: nothing removed" test -d "$TMP/main-review/inroot"

exit "$FAILS"
