#!/usr/bin/env bash
# Tests for studio-core's review_guard.sh on throwaway repositories.
#   bash tests/review_guard_test.sh
# Builds a bare "origin" and a clone in a temp directory, never touches the
# real repository, and prints one line per case. Exit 1 if any case fails.
# The reviewed paths come from STUDIO_REVIEWED_PATHS here; the cases at the
# end read them, and the main branch, from a .claude/studio.json committed on
# the remote's main (the working tree's copy only names what to fetch).
set -euo pipefail
# REVIEW_GUARD_UNDER_TEST runs these cases against another copy of the guard.
GUARD="${REVIEW_GUARD_UNDER_TEST:-$(cd "$(dirname "$0")/../plugins/studio-core/scripts" && pwd)/review_guard.sh}"
unset CLAUDE_PROJECT_DIR STUDIO_MAIN_BRANCH STUDIO_REMOTE
# "apps" first: the LIST_PATHS shim below matches it as the first pathspec.
export STUDIO_REVIEWED_PATHS="apps packages scripts .github .claude runbooks CLAUDE.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

FAILS=0
expect() { # name, wanted exit, command...
  local name="$1" want="$2" got out; shift 2
  set +e; out="$("$@" 2>&1)"; got=$?; set -e
  if [[ "$got" == "$want" ]]; then echo "ok   $name"; else echo "FAIL $name: exit $got, wanted $want"; echo "$out" | sed 's/^/     /'; FAILS=1; fi
}
expect_out() { # name, wanted substring, command...
  local name="$1" want="$2" out; shift 2
  set +e; out="$("$@" 2>&1)"; set -e
  if [[ "$out" == *"$want"* ]]; then echo "ok   $name"; else echo "FAIL $name: output lacks '$want'"; echo "$out" | sed 's/^/     /'; FAILS=1; fi
}
expect_out_both() { # name, first wanted substring, second wanted substring, command...
  # Both must be in the one output: a check on "calls=0" alone also passes when
  # the command died before reaching the thing under test.
  local name="$1" want1="$2" want2="$3" out; shift 3
  set +e; out="$("$@" 2>&1)"; set -e
  if [[ "$out" == *"$want1"* && "$out" == *"$want2"* ]]; then echo "ok   $name"; else echo "FAIL $name: output lacks '$want1' or '$want2'"; echo "$out" | sed 's/^/     /'; FAILS=1; fi
}

new_repo() { # fresh origin + clone at $TMP/<name>, one commit with docs and code
  local d="$TMP/$1"
  git init -q --bare -b main "$d.git"
  git clone -q "$d.git" "$d" 2>/dev/null
  mkdir -p "$d/apps/a" "$d/journal"
  echo one > "$d/journal/day.md"; echo 'x=1' > "$d/apps/a/code.js"
  git -C "$d" add -A && git -C "$d" commit -q -m base && git -C "$d" push -q origin main
  echo "$d"
}
commit() { # repo, path, content, message
  mkdir -p "$(dirname "$1/$2")"; echo "$3" >> "$1/$2"
  git -C "$1" add -- "$2" && git -C "$1" commit -q -m "$4"
}
land() { # repo, branch, trailer-range ("" for none): --no-ff merge onto origin/main and push
  local r="$1" b="$2" range="$3"
  local msg=(-m "merge $b")
  [[ -n "$range" ]] && msg+=(-m "Reviewed-by: fresh reviewer agent, $range, 1 round (0 blocker, 0 major, 0 minor)")
  git -C "$r" fetch -q origin && git -C "$r" checkout -q --detach origin/main
  git -C "$r" merge -q --no-ff "${msg[@]}" "$b" && git -C "$r" push -q origin HEAD:main
  git -C "$r" checkout -q main && git -C "$r" reset -q --hard origin/main
}
run_in() { (cd "$1" && shift && "$@"); }
# A git that fails on purpose: $TMP/shim-<name>/git runs the sh condition (one
# line, which may exit) and then the real git. Put its directory first on PATH.
make_shim() { # name, condition
  mkdir -p "$TMP/shim-$1"
  printf '#!/bin/sh\n%s\nexec "%s" "$@"\n' "$2" "$(command -v git)" > "$TMP/shim-$1/git" && chmod +x "$TMP/shim-$1/git"
}
run_shim() { # shim name, repo, command...: run_in with the shim first on PATH
  local s="$1" d="$2"; shift 2
  (cd "$d" && PATH="$TMP/shim-$s:$PATH" "$@")
}
# The call changed_paths makes:
#   git diff-tree --no-commit-id --name-only -r --root --diff-merges=first-parent <commit> -- apps ...
# so the commit is $7.
LIST_PATHS='[ "$1" = diff-tree ] && [ "$7" != -- ] && [ "$8" = -- ] && [ "$9" = apps ]'


# push mode
R="$(new_repo push)"
expect "push: nothing local passes" 0 run_in "$R" "$GUARD" push
commit "$R" journal/day.md two "docs"
expect "push: a local docs commit passes" 0 run_in "$R" "$GUARD" push
commit "$R" apps/a/code.js 'x=2' "code"
expect "push: a local code commit fails" 1 run_in "$R" "$GUARD" push
expect_out "push: names the commit" "unreviewed local commit on main" run_in "$R" "$GUARD" push
git -C "$R" reset -q --hard origin/main
commit "$R" CLAUDE.md rule "process file"
expect "push: a local CLAUDE.md commit fails" 1 run_in "$R" "$GUARD" push
git -C "$R" reset -q --hard origin/main
commit "$R" .claude/skills/x/SKILL.md s "skill"
expect "push: a local skill commit fails" 1 run_in "$R" "$GUARD" push
git -C "$R" reset -q --hard origin/main
commit "$R" runbooks/rollback.md 'roll back the last release' "runbook"
expect "push: a local runbook commit fails" 1 run_in "$R" "$GUARD" push
expect "push: bad argument is a usage error" 2 run_in "$R" "$GUARD" push extra
git -C "$R" reset -q --hard origin/main
# From a worktree on another branch, the guard still reads the local main ref.
git -C "$R" worktree add -q -b review/wt "$TMP/push-wt" origin/main
commit "$R" apps/a/code.js 'x=main' "code on main while a worktree is elsewhere"
expect "push: a code commit on main is caught from another worktree" 1 run_in "$TMP/push-wt" "$GUARD" push
git -C "$R" reset -q --hard origin/main
commit "$TMP/push-wt" apps/a/code.js 'x=branch' "code on the review branch only"
expect "push: a code commit on a review branch does not block main" 0 run_in "$TMP/push-wt" "$GUARD" push
# Pathspecs are relative to the directory: a run from a subdirectory still
# sees every reviewed path.
commit "$R" apps/a/code.js 'x=sub' "code, checked from a subdirectory"
expect "push: a code commit is caught from a subdirectory" 1 run_in "$R/journal" "$GUARD" push
expect "push: and with --source from a subdirectory" 1 run_in "$R/journal" "$GUARD" push --source main
git -C "$R" reset -q --hard origin/main
# git failing to list what a local commit touches never passes the push: exit 2.
R="$(new_repo push2)"
commit "$R" apps/a/code.js 'x=unlisted' "local code whose paths git cannot list"
make_shim push-paths "$LIST_PATHS"' && { echo "fatal: diff broke" >&2; exit 128; }'
expect "push: a failure to list a local commit's paths refuses with exit 2" 2 run_shim push-paths "$R" "$GUARD" push
expect_out "push: the paths failure says so" "push: could not list the paths of" run_shim push-paths "$R" "$GUARD" push
make_shim push-commits '[ "$1" = rev-list ] && [ "$2" = --first-parent ] && [ "$3" = origin/main..main ] && { echo "fatal: rev-list broke" >&2; exit 128; }'
expect "push: a failure to list the local commits refuses with exit 2" 2 run_shim push-commits "$R" "$GUARD" push
expect_out "push: the commits failure says so" "push: could not list the local commits on main" run_shim push-commits "$R" "$GUARD" push

# push --source REV: what a push of REV to main would bring, not the local
# main. A review branch pushed straight to main is caught even when the local
# main is clean; a proper landing merge pushed from the review worktree passes.
R="$(new_repo src)"
W="$TMP/src-wt"
git -C "$R" worktree add -q -b review/x "$W" origin/main
SB="$(git -C "$W" rev-parse HEAD)"
commit "$W" apps/a/code.js 'x=src' "unreviewed code on review/x"
SH="$(git -C "$W" rev-parse HEAD)"
expect "push --source: the local main is clean, so plain push passes" 0 run_in "$W" "$GUARD" push
expect "push --source: review/x pushed to main is caught" 1 run_in "$R" "$GUARD" push --source review/x
expect_out "push --source: and is named" "unreviewed local commit pushed to main: " run_in "$W" "$GUARD" push --source review/x
expect "push --source: HEAD of the review worktree is caught too" 1 run_in "$W" "$GUARD" push --source HEAD
expect "push --source: a source already on the remote main passes" 0 run_in "$W" "$GUARD" push --source origin/main
git -C "$W" checkout -q --detach origin/main
git -C "$W" merge -q --no-ff -m "merge review/x" -m "Reviewed-by: fresh reviewer agent, ${SB:0:7}..${SH:0:7}, 1 round (0 blocker, 0 major, 0 minor)" review/x
expect "push --source: a reviewed landing merge passes" 0 run_in "$W" "$GUARD" push --source HEAD
git -C "$W" reset -q --hard origin/main
git -C "$W" merge -q --no-ff -m "merge review/x, no trailer" review/x
expect "push --source: a landing merge with no Reviewed-by line is caught" 1 run_in "$W" "$GUARD" push --source HEAD
expect_out "push --source: and says so" "no Reviewed-by range" run_in "$W" "$GUARD" push --source HEAD
git -C "$W" reset -q --hard origin/main
git -C "$W" merge -q --no-ff -m "merge review/x" -m "Reviewed-by: fresh reviewer agent, ${SB:0:7}..${SB:0:7}, 1 round" review/x
expect "push --source: a landing whose range ends before the landed tip is caught" 1 run_in "$W" "$GUARD" push --source HEAD
expect "push --source: a source that is not a commit is exit 2" 2 run_in "$W" "$GUARD" push --source no-such-ref
expect "push --source: with no value is a usage error" 2 run_in "$W" "$GUARD" push --source
git -C "$R" worktree remove --force "$W"

# audit mode
R="$(new_repo audit)"
expect "audit: no FROM is a usage error" 2 run_in "$R" "$GUARD" audit
expect "audit: a FROM that is not a commit is a usage error" 2 run_in "$R" "$GUARD" audit nope
git -C "$R" checkout -q -b stray && commit "$R" journal/day.md s "stray" && git -C "$R" checkout -q main
expect "audit: a FROM that is not on origin/main is a usage error" 2 run_in "$R" "$GUARD" audit stray
R="$(new_repo audit2)"
# Audit only what comes after the base commit.
FROM_HERE() { git -C "$1" rev-parse origin/main; }
S="$(FROM_HERE "$R")"
commit "$R" journal/day.md more "docs on main" && git -C "$R" push -q origin main
expect "audit: a docs commit on main passes" 0 run_in "$R" "$GUARD" audit "$S"
expect_out "audit: prints where it ended" "audited through $(git -C "$R" rev-parse origin/main)" run_in "$R" "$GUARD" audit "$S"

git -C "$R" checkout -q -b review/t1 origin/main
BASE1="$(git -C "$R" rev-parse origin/main)"
commit "$R" apps/a/code.js 'x=3' "t1 change"
HEAD1="$(git -C "$R" rev-parse HEAD)"
git -C "$R" checkout -q main
commit "$R" journal/day.md moved "main moved meanwhile" && git -C "$R" push -q origin main
land "$R" review/t1 "${BASE1:0:7}..${HEAD1:0:7}"
expect "audit: a landing merge with the right range passes" 0 run_in "$R" "$GUARD" audit "$S"

git -C "$R" checkout -q -b review/t2 origin/main
BASE2="$(git -C "$R" rev-parse origin/main)"
commit "$R" apps/a/code.js 'x=4' "t2 reviewed"
HEAD2="$(git -C "$R" rev-parse HEAD)"
commit "$R" apps/a/code.js 'x=5' "t2 added after review"
git -C "$R" checkout -q main
land "$R" review/t2 "${BASE2:0:7}..${HEAD2:0:7}"
expect_out "audit: a commit added after the review is a gap" "but the review read up to" run_in "$R" "$GUARD" audit "$S"

# Fixes the author made after the fresh review, named on a
# Fixed-after-review line whose range starts at the reviewed head.
land_fixed() { # repo, branch, reviewed range, fix range
  local r="$1" b="$2"
  git -C "$r" fetch -q origin && git -C "$r" checkout -q --detach origin/main
  git -C "$r" merge -q --no-ff -m "merge $b" -m "Reviewed-by: fresh reviewer agent, $3, 1 round (0 blocker, 1 major, 0 minor)" -m "Fixed-after-review: author, $4, 1 fix" "$b" && git -C "$r" push -q origin HEAD:main
  git -C "$r" checkout -q main && git -C "$r" reset -q --hard origin/main
}
R="$(new_repo auditfix)"; S="$(FROM_HERE "$R")"
git -C "$R" checkout -q -b review/tf origin/main
BASEF="$(git -C "$R" rev-parse origin/main)"
commit "$R" apps/a/code.js 'x=f1' "tf reviewed"
HEADF="$(git -C "$R" rev-parse HEAD)"
commit "$R" apps/a/code.js 'x=f2' "tf fix after review"
FIXF="$(git -C "$R" rev-parse HEAD)"
git -C "$R" checkout -q main
land_fixed "$R" review/tf "${BASEF:0:7}..${HEADF:0:7}" "${HEADF:0:7}..${FIXF:0:7}"
expect "audit: author fixes named from the reviewed head to the landed tip pass" 0 run_in "$R" "$GUARD" audit "$S"

R="$(new_repo auditfix2)"; S="$(FROM_HERE "$R")"
git -C "$R" checkout -q -b review/tg origin/main
BASEG="$(git -C "$R" rev-parse origin/main)"
commit "$R" apps/a/code.js 'x=g1' "tg first commit"
MIDG="$(git -C "$R" rev-parse HEAD)"
commit "$R" apps/a/code.js 'x=g2' "tg reviewed"
HEADG="$(git -C "$R" rev-parse HEAD)"
commit "$R" apps/a/code.js 'x=g3' "tg fix"
FIXG="$(git -C "$R" rev-parse HEAD)"
git -C "$R" checkout -q main
land_fixed "$R" review/tg "${BASEG:0:7}..${HEADG:0:7}" "${MIDG:0:7}..${FIXG:0:7}"
expect_out "audit: author fixes that do not start at the reviewed head are a gap" "do not start where the review ended" run_in "$R" "$GUARD" audit "$S"

R="$(new_repo auditfix3)"; S="$(FROM_HERE "$R")"
git -C "$R" checkout -q -b review/th origin/main
BASEH="$(git -C "$R" rev-parse origin/main)"
commit "$R" apps/a/code.js 'x=h1' "th reviewed"
HEADH="$(git -C "$R" rev-parse HEAD)"
commit "$R" apps/a/code.js 'x=h2' "th fix"
FIXH="$(git -C "$R" rev-parse HEAD)"
commit "$R" apps/a/code.js 'x=h3' "th unnamed commit after the fixes"
git -C "$R" checkout -q main
land_fixed "$R" review/th "${BASEH:0:7}..${HEADH:0:7}" "${HEADH:0:7}..${FIXH:0:7}"
expect_out "audit: a commit after the named fixes is a gap" "but the review and the author's fixes end at" run_in "$R" "$GUARD" audit "$S"

R="$(new_repo auditfix4)"; S="$(FROM_HERE "$R")"
git -C "$R" checkout -q -b review/ti origin/main
BASEI="$(git -C "$R" rev-parse origin/main)"
commit "$R" apps/a/code.js 'x=i1' "ti reviewed"
HEADI="$(git -C "$R" rev-parse HEAD)"
git -C "$R" checkout -q main
land_fixed "$R" review/ti "${BASEI:0:7}..${HEADI:0:7}" "${HEADI:0:7}..fffffff"
expect_out "audit: a fix range that does not resolve is a gap" "Fixed-after-review range" run_in "$R" "$GUARD" audit "$S"

R="$(new_repo auditfix5)"; S="$(FROM_HERE "$R")"
git -C "$R" checkout -q -b review/tj origin/main
EMPTYJ="$(git -C "$R" rev-parse origin/main)"
commit "$R" apps/a/code.js 'x=j1' "tj whole change landed as a fix"
FIXJ="$(git -C "$R" rev-parse HEAD)"
git -C "$R" checkout -q main
land_fixed "$R" review/tj "${EMPTYJ:0:7}..${EMPTYJ:0:7}" "${EMPTYJ:0:7}..${FIXJ:0:7}"
expect_out "audit: an empty review whose fixes carry the whole change is a gap" "already on main, so the author's fixes" run_in "$R" "$GUARD" audit "$S"

# Only the documented shape "author, <HEAD>..<FIX>, ..." is read; a
# range in the findings text after it is ignored, "none" counts as absent and
# any other Fixed-after-review line is a gap that names the line.
land_fixline() { # repo, branch, reviewed range, whole Fixed-after-review line
  local r="$1" b="$2"
  git -C "$r" fetch -q origin && git -C "$r" checkout -q --detach origin/main
  git -C "$r" merge -q --no-ff -m "merge $b" -m "Reviewed-by: fresh reviewer agent, $3, 1 round (0 blocker, 1 major, 0 minor)" -m "$4" "$b" && git -C "$r" push -q origin HEAD:main
  git -C "$r" checkout -q main && git -C "$r" reset -q --hard origin/main
}
two_pass_branch() { # repo, branch: sets P1S P1E (a pass-one range), HD (reviewed head), FX (fix tip)
  git -C "$1" checkout -q -b "$2" origin/main
  P1S="$(git -C "$1" rev-parse origin/main)"
  commit "$1" apps/a/code.js "x=$2-1" "$2 pass one fixed"
  P1E="$(git -C "$1" rev-parse HEAD)"
  commit "$1" apps/a/code.js "x=$2-2" "$2 reviewed"
  HD="$(git -C "$1" rev-parse HEAD)"
  commit "$1" apps/a/code.js "x=$2-3" "$2 fix after review"
  FX="$(git -C "$1" rev-parse HEAD)"
  git -C "$1" checkout -q main
}
# auditshape1 guards against a regression to reading the last or any range
# on the line (the old parser also passed it); auditshape2 and auditshape3
# are the cases that separate the documented-shape parser from the old one.
R="$(new_repo auditshape1)"; S="$(FROM_HERE "$R")"
two_pass_branch "$R" review/tk
land_fixline "$R" review/tk "${P1S:0:7}..${HD:0:7}" "Fixed-after-review: author, ${HD:0:7}..${FX:0:7}, 1 fixes (pass one ${P1S:0:7}..${P1E:0:7} fixed)"
expect "audit: the documented fix range is read, not a range in the findings text" 0 run_in "$R" "$GUARD" audit "$S"

R="$(new_repo auditshape2)"; S="$(FROM_HERE "$R")"
two_pass_branch "$R" review/tl
land_fixline "$R" review/tl "${P1S:0:7}..${HD:0:7}" "Fixed-after-review: pass one ${P1S:0:7}..${P1E:0:7}, then author ${HD:0:7}..${FX:0:7}"
expect_out "audit: a Fixed-after-review line not in the documented shape is a gap naming it" "Fixed-after-review line is not the documented shape (Fixed-after-review: pass one ${P1S:0:7}" run_in "$R" "$GUARD" audit "$S"

R="$(new_repo auditshape3)"; S="$(FROM_HERE "$R")"
two_pass_branch "$R" review/tm
land_fixline "$R" review/tm "${P1S:0:7}..${HD:0:7}" "Fixed-after-review: ${FX:0:8} (major: a fix named by one commit)"
expect_out "audit: a Fixed-after-review line with no range is a gap, not absent" "not the documented shape" run_in "$R" "$GUARD" audit "$S"

R="$(new_repo auditshape6)"; S="$(FROM_HERE "$R")"
two_pass_branch "$R" review/tq
land_fixline "$R" review/tq "${P1S:0:7}..${HD:0:7}" "Fixed-after-review: none, author ${HD:0:7}..${FX:0:7}"
expect_out "audit: none followed by more than a parenthesis is a gap naming the line, not absent" "not the documented shape (Fixed-after-review: none, author ${HD:0:7}" run_in "$R" "$GUARD" audit "$S"

R="$(new_repo auditshape4)"; S="$(FROM_HERE "$R")"
git -C "$R" checkout -q -b review/tn origin/main
BASEN="$(git -C "$R" rev-parse origin/main)"
commit "$R" apps/a/code.js 'x=n1' "tn reviewed"
HEADN="$(git -C "$R" rev-parse HEAD)"
git -C "$R" checkout -q main
land_fixline "$R" review/tn "${BASEN:0:7}..${HEADN:0:7}" "Fixed-after-review: none (0 blocker, 0 major)"
expect "audit: Fixed-after-review none counts as absent" 0 run_in "$R" "$GUARD" audit "$S"

R="$(new_repo auditshape5)"; S="$(FROM_HERE "$R")"
git -C "$R" checkout -q -b review/to origin/main
BASEO="$(git -C "$R" rev-parse origin/main)"
commit "$R" apps/a/code.js 'x=o1' "to reviewed"
HEADO="$(git -C "$R" rev-parse HEAD)"
commit "$R" apps/a/code.js 'x=o2' "to unnamed commit after the review"
git -C "$R" checkout -q main
land_fixline "$R" review/to "${BASEO:0:7}..${HEADO:0:7}" "Fixed-after-review: none"
expect_out "audit: with none, a commit after the review is still a gap" "but the review read up to" run_in "$R" "$GUARD" audit "$S"

R="$(new_repo auditfix6)"; S="$(FROM_HERE "$R")"
git -C "$R" checkout -q -b review/tk origin/main
BASEK="$(git -C "$R" rev-parse origin/main)"
commit "$R" apps/a/code.js 'x=k1' "tk reviewed"
HEADK="$(git -C "$R" rev-parse HEAD)"
commit "$R" apps/a/code.js 'x=k2' "tk fix"
FIXK="$(git -C "$R" rev-parse HEAD)"
git -C "$R" checkout -q main
land_fixed "$R" review/tk "${BASEK:0:7}..${HEADK:0:7}" "${HEADK:0:7}..${FIXK:0:7} (finding about ${BASEK:0:7}..${HEADK:0:7})"
expect "audit: a range inside the findings text does not replace the fix range" 0 run_in "$R" "$GUARD" audit "$S"

R="$(new_repo audit3)"; S="$(FROM_HERE "$R")"
git -C "$R" checkout -q -b review/t3 origin/main
commit "$R" apps/a/code.js 'x=6' "t3"
git -C "$R" checkout -q main
land "$R" review/t3 ""
expect_out "audit: a merge with no trailer is a gap" "no Reviewed-by range" run_in "$R" "$GUARD" audit "$S"

R="$(new_repo audit4)"; S="$(FROM_HERE "$R")"
mkdir -p "$R/scripts" && echo 'echo hi' > "$R/scripts/deploy.sh" && git -C "$R" add scripts
GIT_COMMITTER_DATE="2020-01-01T00:00:00Z" GIT_AUTHOR_DATE="2020-01-01T00:00:00Z" git -C "$R" commit -q -m "direct script commit dated years ago"
git -C "$R" push -q origin main
expect_out "audit: a direct script commit is a gap, whatever its date" "direct commit to main" run_in "$R" "$GUARD" audit "$S"

R="$(new_repo audit5)"; S="$(FROM_HERE "$R")"
# The branch starts from a commit that never reaches main: its base is not on main.
git -C "$R" checkout -q -b side origin/main
commit "$R" apps/a/code.js 'x=side' "unread side commit"
git -C "$R" checkout -q -b review/t5
BASE5="$(git -C "$R" rev-parse HEAD)"
commit "$R" apps/a/other.js 'y=1' "t5 reviewed"
HEAD5="$(git -C "$R" rev-parse HEAD)"
git -C "$R" checkout -q main
land "$R" review/t5 "${BASE5:0:7}..${HEAD5:0:7}"
expect_out "audit: a base that is not on main is a gap" "is not on main before the merge" run_in "$R" "$GUARD" audit "$S"

# A step branch cut from an older main carries its own copy of the plan
# commit, and the review range starts at that copy. What the merge brings in
# outside the range touches only plans/, which lands on main unreviewed by
# design: not a gap. The same shape with a commit under apps/ is a gap.
brought_in() { # repo name, path the commit outside the range touches
  R="$(new_repo "$1")"; S="$(FROM_HERE "$R")"
  commit "$R" journal/day.md 'main moved' "main moves on" && git -C "$R" push -q origin main
  git -C "$R" checkout -q -b "review/$1" "$S"
  commit "$R" "$2" 'outside the range' "commit outside the review range"
  local b; b="$(git -C "$R" rev-parse HEAD)"
  commit "$R" apps/a/code.js "x=$1" "$1 reviewed"
  git -C "$R" checkout -q main
  land "$R" "review/$1" "${b:0:7}..$(git -C "$R" rev-parse --short=7 "review/$1")"
}
brought_in audit5b plans/step.md
expect "audit: a brought-in commit touching only plans/ is not a gap" 0 run_in "$R" "$GUARD" audit "$S"
brought_in audit5c apps/a/stray.js
expect "audit: a brought-in commit touching apps/ is a gap (exit 1)" 1 run_in "$R" "$GUARD" audit "$S"
expect_out "audit: and it names the commit" "which touches a reviewed path no reviewer read" run_in "$R" "$GUARD" audit "$S"
# git failing to list the brought-in commit's paths is a gap, never a pass.
brought_in audit5d plans/step.md
make_shim audit5d "$LIST_PATHS"' && [ "$(git log -1 --format=%s "$7")" = "commit outside the review range" ] && { echo "fatal: diff broke" >&2; exit 128; }'
expect_out "audit: a brought-in commit whose paths git cannot list is a gap" "could not list the paths of" run_shim audit5d "$R" "$GUARD" audit "$S"
# git failing to list what the merge brings in (rev-list P1..BASE) is a gap too.
brought_in audit5e plans/step.md
make_shim audit5e '[ "$1" = rev-list ] && [ $# = 2 ] && case "$2" in *..*) echo "fatal: rev-list broke" >&2; exit 128;; esac'
expect "audit: a failure to list what a merge brings in exits 1, not 0" 1 run_shim audit5e "$R" "$GUARD" audit "$S"
expect_out "audit: and it says so" "could not list what the merge brings in" run_shim audit5e "$R" "$GUARD" audit "$S"
# A merge brought in (P1..BASE) that keeps its own tree and drops main's side
# (git merge -s ours) shows no reviewed path under a first-parent diff, yet the
# landing then reverts reviewed code on main: always a gap.
R="$(new_repo audit5f)"
OLD5F="$(git -C "$R" rev-parse origin/main)"
commit "$R" apps/a/code.js 'x=reviewed on main' "reviewed change on main" && git -C "$R" push -q origin main
S="$(FROM_HERE "$R")"
git -C "$R" checkout -q -b review/t5f "$OLD5F"
git -C "$R" merge -q -s ours -m "merge main, keep ours" origin/main
BASE5F="$(git -C "$R" rev-parse HEAD)"
commit "$R" apps/a/other.js 'y=5f' "t5f reviewed"
git -C "$R" checkout -q main
land "$R" review/t5f "${BASE5F:0:7}..$(git -C "$R" rev-parse --short=7 review/t5f)"
expect "audit: a brought-in merge that drops main's side is a gap (exit 1)" 1 run_in "$R" "$GUARD" audit "$S"
expect_out "audit: and it names the merge" "brings in a merge" run_in "$R" "$GUARD" audit "$S"
# git failing to list the merges brought in is a gap too.
brought_in audit5g plans/step.md
make_shim audit5g '[ "$1" = rev-list ] && [ "$2" = --merges ] && { echo "fatal: rev-list broke" >&2; exit 128; }'
expect "audit: a failure to list the merges a merge brings in exits 1, not 0" 1 run_shim audit5g "$R" "$GUARD" audit "$S"
expect_out "audit: and it says so" "could not list the merges the merge brings in" run_shim audit5g "$R" "$GUARD" audit "$S"

R="$(new_repo audit6)"; S="$(FROM_HERE "$R")"
git -C "$R" checkout -q -b review/t6 origin/main
BASE6="$(git -C "$R" rev-parse origin/main)"
commit "$R" apps/a/code.js 'branch' "t6"
HEAD6="$(git -C "$R" rev-parse HEAD)"
git -C "$R" checkout -q main
commit "$R" apps/a/code.js 'main' "a conflicting change on main"
git -C "$R" push -q origin main
git -C "$R" fetch -q origin && git -C "$R" checkout -q --detach origin/main
set +e; git -C "$R" merge -q --no-ff -m "merge review/t6" -m "Reviewed-by: fresh reviewer agent, ${BASE6:0:7}..${HEAD6:0:7}, 1 round" review/t6 >/dev/null 2>&1; set -e
printf 'x=resolved\n' > "$R/apps/a/code.js"
git -C "$R" add apps/a/code.js && git -C "$R" commit -q --no-edit && git -C "$R" push -q origin HEAD:main
expect_out "audit: a conflict resolution in the merge is a gap" "resolved a conflict" run_in "$R" "$GUARD" audit "$S"

R="$(new_repo audit7)"; S="$(FROM_HERE "$R")"
git -C "$R" checkout -q -b review/t7 origin/main
BASE7="$(git -C "$R" rev-parse origin/main)"
commit "$R" apps/a/code.js 'x=7' "t7 code"
commit "$R" journal/day.md 'branch docs' "t7 docs"
HEAD7="$(git -C "$R" rev-parse HEAD)"
git -C "$R" checkout -q main
commit "$R" journal/day.md 'main docs' "docs on main that will conflict" && git -C "$R" push -q origin main
git -C "$R" fetch -q origin && git -C "$R" checkout -q --detach origin/main
set +e; git -C "$R" merge -q --no-ff -m "merge review/t7" -m "Reviewed-by: fresh reviewer agent, ${BASE7:0:7}..${HEAD7:0:7}, 1 round" review/t7 >/dev/null 2>&1; set -e
printf 'one\nmain docs\nbranch docs\n' > "$R/journal/day.md"
git -C "$R" add journal/day.md && git -C "$R" commit -q --no-edit && git -C "$R" push -q origin HEAD:main
expect "audit: a docs-only conflict resolution in a landing merge passes" 0 run_in "$R" "$GUARD" audit "$S"

# A reviewed fix lands on main; review/late, cut before it, changes the same
# line. Sets R, S (the FROM), BASEL and HEADL (review/late's reviewed range).
late_branch() { # repo name
  R="$(new_repo "$1")"; S="$(FROM_HERE "$R")"
  git -C "$R" checkout -q -b review/late origin/main
  BASEL="$(git -C "$R" rev-parse origin/main)"
  commit "$R" apps/a/code.js 'x=late' "late reviewed change"
  HEADL="$(git -C "$R" rev-parse HEAD)"
  git -C "$R" checkout -q -b review/fix origin/main
  local bf; bf="$(git -C "$R" rev-parse origin/main)"
  commit "$R" apps/a/code.js 'x=fixed' "a reviewed fix on the same line"
  git -C "$R" checkout -q main
  land "$R" review/fix "${bf:0:7}..$(git -C "$R" rev-parse --short=7 review/fix)"
  git -C "$R" checkout -q --detach origin/main
}
TRAILER_L() { echo "Reviewed-by: fresh reviewer agent, ${BASEL:0:7}..${HEADL:0:7}, 1 round"; }

late_branch audit8
expect "audit: the reviewed fix itself lands clean and passes" 0 run_in "$R" "$GUARD" audit "$S"
git -C "$R" merge -q --no-ff -X theirs -m "merge review/late" -m "$(TRAILER_L)" review/late >/dev/null 2>&1
git -C "$R" push -q origin HEAD:main
grep -q 'x=fixed' "$R/apps/a/code.js" && { echo "FAIL audit: the -X theirs setup did not revert the fix"; FAILS=1; }
expect "audit: a landing merged with -X theirs that reverts a reviewed fix on main fails" 1 run_in "$R" "$GUARD" audit "$S"
expect_out "audit: and names the conflict in the reviewed path" "resolved a conflict in a reviewed path (apps/a/code.js)" run_in "$R" "$GUARD" audit "$S"

late_branch audit9
set +e; git -C "$R" merge -q --no-ff -m "merge review/late" -m "$(TRAILER_L)" review/late >/dev/null 2>&1; set -e
git -C "$R" checkout --theirs -- apps/a/code.js && git -C "$R" add apps/a/code.js && git -C "$R" commit -q --no-edit && git -C "$R" push -q origin HEAD:main
[[ -z "$(git -C "$R" diff-tree --no-commit-id --cc HEAD -- apps)" ]] && echo "ok   audit: git show --cc prints nothing for a file taken whole from one side" || { echo "FAIL audit: --cc showed the taken side"; FAILS=1; }
[[ -n "$(git -C "$R" show --remerge-diff --format= HEAD -- apps)" ]] && echo "ok   audit: git show --remerge-diff shows it" || { echo "FAIL audit: --remerge-diff showed nothing"; FAILS=1; }
expect_out "audit: a conflict resolved with checkout --theirs is a gap" "resolved a conflict in a reviewed path" run_in "$R" "$GUARD" audit "$S"

late_branch audit10
# No conflict: review/late changes another file, and the merge takes its old
# copy of the file the fix changed.
git -C "$R" checkout -q review/late && git -C "$R" reset -q --hard "$BASEL"
commit "$R" apps/b/new.js 'y=1' "late reviewed change elsewhere"
HEADL="$(git -C "$R" rev-parse HEAD)"
git -C "$R" checkout -q --detach origin/main
git -C "$R" merge -q --no-ff --no-commit review/late >/dev/null 2>&1
git -C "$R" checkout review/late -- apps/a/code.js
git -C "$R" commit -q -m "merge review/late" -m "$(TRAILER_L)" && git -C "$R" push -q origin HEAD:main
expect_out "audit: a clean landing that takes one side's copy of a reviewed file is a gap" "differs in a reviewed path from the merge its parents make" run_in "$R" "$GUARD" audit "$S"

R="$(new_repo audit11)"
printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n' > "$R/apps/a/long.js"
git -C "$R" add apps/a/long.js && git -C "$R" commit -q -m "long file" && git -C "$R" push -q origin main
S="$(FROM_HERE "$R")"
git -C "$R" checkout -q -b review/top origin/main
BT="$(git -C "$R" rev-parse origin/main)"
printf 'top\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n' > "$R/apps/a/long.js" && git -C "$R" commit -q -am "top line"
land "$R" review/top "${BT:0:7}..$(git -C "$R" rev-parse --short=7 review/top)"
git -C "$R" checkout -q -b review/bottom "$BT"
printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nbottom\n' > "$R/apps/a/long.js" && git -C "$R" commit -q -am "bottom line"
git -C "$R" checkout -q main
land "$R" review/bottom "${BT:0:7}..$(git -C "$R" rev-parse --short=7 review/bottom)" >/dev/null
expect "audit: a clean landing that merges separate hunks of one reviewed file passes" 0 run_in "$R" "$GUARD" audit "$S"

late_branch audit12
# The skill's way: the conflict is resolved on the branch, a reviewer reads
# that merge, and the landing then merges clean.
git -C "$R" checkout -q review/late
set +e; git -C "$R" merge -q origin/main >/dev/null 2>&1; set -e
printf 'x=1\nx=fixed\nx=late\n' > "$R/apps/a/code.js"
git -C "$R" add apps/a/code.js && git -C "$R" commit -q --no-edit
land "$R" review/late "${BASEL:0:7}..$(git -C "$R" rev-parse --short=7 review/late)"
expect "audit: a reviewed-path conflict resolved on the branch, then a clean landing, passes" 0 run_in "$R" "$GUARD" audit "$S"

# git failing on one landing must not stop the audit: exit 2 is a skipped
# audit, so the same landing would stop every later audit. It is a
# gap for that landing, and the gaps on either side of it are still printed.
# A direct commit, a clean landing, a direct commit; git on PATH is a shim that
# runs the sh condition $2 first. Sets R, TIP, OUT, RC and the three gap lines.
failing_git_audit() { # repo name, shim condition (sh, one line)
  R="$(new_repo "$1")"; S="$(FROM_HERE "$R")"
  local b
  commit "$R" scripts/old.sh 'echo old' "direct commit before the landing" && git -C "$R" push -q origin main
  GAP_BEFORE="gap: direct commit to main touching reviewed paths: $(git -C "$R" log -1 --format='%h %s' HEAD)"
  git -C "$R" checkout -q -b review/shim origin/main
  b="$(git -C "$R" rev-parse origin/main)"
  commit "$R" apps/a/code.js 'x=shim' "shim reviewed change"
  land "$R" review/shim "${b:0:7}..$(git -C "$R" rev-parse --short=7 review/shim)"
  LANDING="$(git -C "$R" log -1 --format='%h %s' origin/main)"
  commit "$R" apps/a/code.js 'x=after' "direct commit after the landing" && git -C "$R" push -q origin main
  GAP_AFTER="gap: direct commit to main touching reviewed paths: $(git -C "$R" log -1 --format='%h %s' HEAD)"
  TIP="$(git -C "$R" rev-parse origin/main)"
  make_shim "$1" "$2"
  set +e; OUT="$(run_shim "$1" "$R" "$GUARD" audit "$S" 2>&1)"; RC=$?; set -e
}
assert_failing_git_audit() { # label, the gap line wanted for the landing
  local nl=$'\n' lines
  lines="$nl${OUT//$nl/$nl$nl}$nl" # every line between its own two newlines
  if [[ "$RC" == 1 ]]; then echo "ok   audit: $1 exits 1, not 2"; else echo "FAIL audit: $1: exit $RC, wanted 1"; printf '%s\n' "$OUT" | sed 's/^/     /'; FAILS=1; fi
  if [[ "$lines" == *"$nl$2$nl"* ]]; then echo "ok   audit: $1 is a gap line for that landing"; else echo "FAIL audit: $1: no line '$2'"; printf '%s\n' "$OUT" | sed 's/^/     /'; FAILS=1; fi
  if [[ "$lines" == *"$nl$GAP_AFTER$nl"*"$nl$2$nl"*"$nl$GAP_BEFORE$nl"* ]]; then echo "ok   audit: $1 keeps the gap printed before it and goes on to the one after"; else echo "FAIL audit: $1: the gaps around the landing are missing or out of order"; printf '%s\n' "$OUT" | sed 's/^/     /'; FAILS=1; fi
  if [[ "$OUT" == *"${nl}audited through $TIP" ]]; then echo "ok   audit: $1 still ends with audited through the tip"; else echo "FAIL audit: $1: no final 'audited through $TIP'"; printf '%s\n' "$OUT" | sed 's/^/     /'; FAILS=1; fi
}
failing_git_audit audit13 'for a in "$@"; do [ "$a" = merge-tree ] && { echo "fatal: merge-tree broke" >&2; exit 128; }; done'
assert_failing_git_audit "a git merge-tree failure on a landing" "gap: could not re-merge the parents, audit it by hand: $LANDING"
failing_git_audit audit14 '[ "$1" = diff ] && [ "$2" = --quiet ] && { echo "fatal: diff broke" >&2; exit 128; }'
assert_failing_git_audit "a git diff failure on a landing" "gap: could not compare the merge with its parents' own merge, audit it by hand: $LANDING"
failing_git_audit audit15 "$LIST_PATHS"' && [ "$(git log -1 --format=%s "$7")" = "merge review/shim" ] && { echo "fatal: diff broke" >&2; exit 128; }'
assert_failing_git_audit "a failure to list a landing's paths" "gap: could not list the paths, audit it by hand: $LANDING"
# The commits after FROM cannot be listed: never "audited through" with nothing read.
R="$(new_repo audit16)"; S="$(FROM_HERE "$R")"
commit "$R" apps/a/code.js 'x=16' "direct code commit" && git -C "$R" push -q origin main
make_shim audit16 '[ "$1" = rev-list ] && [ "$2" = --first-parent ] && { echo "fatal: rev-list broke" >&2; exit 128; }'
expect "audit: a failure to list the commits after FROM is exit 2, not a clean audit" 2 run_shim audit16 "$R" "$GUARD" audit "$S"
expect_out "audit: the commits failure says so" "audit: could not list the commits after" run_shim audit16 "$R" "$GUARD" audit "$S"
# git failing to resolve a merge's first parent must not make the merge look
# like a root commit with no paths: an untrailered merge touching apps is still
# a gap when every `rev-parse -q --verify <commit>^1` fails.
R="$(new_repo audit17)"; S="$(FROM_HERE "$R")"
git -C "$R" checkout -q -b review/t17 origin/main
commit "$R" apps/a/code.js 'x=17' "t17"
git -C "$R" checkout -q main
land "$R" review/t17 ""
make_shim audit17 '[ "$1" = rev-parse ] && [ "$2" = -q ] && [ "$3" = --verify ] && case "$4" in *^1) echo "fatal: rev-parse broke" >&2; exit 128;; esac'
expect "audit: a merge whose first parent git cannot resolve is still audited (exit 1)" 1 run_shim audit17 "$R" "$GUARD" audit "$S"
expect_out "audit: and it is named as a merge with no Reviewed-by range" "no Reviewed-by range" run_shim audit17 "$R" "$GUARD" audit "$S"

# move mode
R="$(new_repo move)"
commit "$R" apps/a/code.js 'x=m1' "code to move"
commit "$R" journal/day.md 'journal line' "close-out journal"
commit "$R" support/tickets.csv 'row1' "hourly row"
expect "move: a name outside review/ is a usage error" 2 run_in "$R" "$GUARD" move feature/x
expect "move: moves and exits 0" 0 run_in "$R" "$GUARD" move review/2026-01-01-t1
expect "move: main now passes the guard" 0 run_in "$R" "$GUARD" push
[[ "$(git -C "$R" log --format=%s origin/main..main | sort | tr '\n' '|')" == "close-out journal|hourly row|" ]] && echo "ok   move: the two docs commits are back on main" || { echo "FAIL move: docs commits on main: $(git -C "$R" log --format=%s origin/main..main | tr '\n' '|')"; FAILS=1; }
[[ "$(git -C "$TMP/move.git" rev-parse review/2026-01-01-t1 2>/dev/null)" == "$(git -C "$R" rev-parse review/2026-01-01-t1)" ]] && echo "ok   move: the branch is pushed with all three commits" || { echo "FAIL move: branch not pushed"; FAILS=1; }
[[ "$(git -C "$R" rev-list --count origin/main..review/2026-01-01-t1)" == 3 ]] || { echo "FAIL move: branch does not hold three commits"; FAILS=1; }

R="$(new_repo move2)"
commit "$R" apps/a/code.js 'x=m2' "code to move"
commit "$R" journal/day.md 'j1' "journal one"
echo "another run's edit" >> "$R/journal/day.md"
expect_out "move: a --keep refusal says so and changes nothing" "reset --keep refused" run_in "$R" "$GUARD" move review/2026-01-01-t2
[[ "$(git -C "$R" rev-list --count origin/main..main)" == 2 ]] && echo "ok   move: main keeps its commits after a refusal" || { echo "FAIL move: main lost commits on refusal"; FAILS=1; }
commit "$R" support/handoff.md 'open line' "hourly hand-off after the refusal"
git -C "$R" checkout -q -- journal/day.md
expect "move: the repeat succeeds" 0 run_in "$R" "$GUARD" move review/2026-01-01-t2
[[ -n "$(git -C "$R" log --format=%s origin/main..main --grep 'hourly hand-off after the refusal')" ]] && echo "ok   move: a commit made after the refusal is back on main" || { echo "FAIL move: the later hourly commit was lost"; FAILS=1; }
[[ -n "$(git -C "$R" log --format=%s origin/main..review/2026-01-01-t2 --grep 'hourly hand-off after the refusal')" ]] && echo "ok   move: and it is on the branch too" || { echo "FAIL move: the later hourly commit is not on the branch"; FAILS=1; }

R="$(new_repo move3)"
mkdir -p "$R/apps/a"; echo 'x=mix' >> "$R/apps/a/code.js"; echo 'mixed journal' >> "$R/journal/day.md"
git -C "$R" add -A && git -C "$R" commit -q -m "mixed code and journal"
MIX3="$(git -C "$R" rev-parse HEAD)"
commit "$R" journal/day.md 'after mixed' "journal on top of the mixed one"
SKIP3="$(git -C "$R" rev-parse HEAD)"
commit "$R" support/tickets.csv 'row' "hourly row after"
set +e; out3="$(cd "$R" && "$GUARD" move review/2026-01-01-t3 2>&1)"; rc3=$?; set -e
[[ "$rc3" == 0 ]] && echo "ok   move: a conflicting cherry-pick does not stop the rest" || { echo "FAIL move: exit $rc3 on a conflicting cherry-pick"; printf '%s\n' "$out3" | sed 's/^/     /'; FAILS=1; }
printf '%s\n' "$out3" | grep '^move: REWRITE ON MAIN: docs-only commits not brought back' | grep -q "${SKIP3:0:7}" && echo "ok   move: REWRITE ON MAIN names the skipped docs commit" || { echo "FAIL move: no REWRITE ON MAIN line for the skipped commit"; printf '%s\n' "$out3" | sed 's/^/     /'; FAILS=1; }
printf '%s\n' "$out3" | grep '^move: REWRITE ON MAIN: mixed commits' | grep -q "${MIX3:0:7}" && echo "ok   move: REWRITE ON MAIN names the mixed commit" || { echo "FAIL move: no REWRITE ON MAIN line for the mixed commit"; printf '%s\n' "$out3" | sed 's/^/     /'; FAILS=1; }
[[ -n "$(git -C "$R" log --format=%s origin/main..main --grep 'hourly row after')" ]] && echo "ok   move: the later support commit is back despite the conflict" || { echo "FAIL move: the support commit after a conflict was not brought back"; FAILS=1; }
[[ -z "$(git -C "$R" status --porcelain)" ]] && echo "ok   move: no cherry-pick left half done" || { echo "FAIL move: tree left dirty: $(git -C "$R" status --porcelain | tr '\n' ' ')"; FAILS=1; }

# BASE must be the merge-base when the shared main is behind origin/main.
R="$(new_repo move6)"
git clone -q "$TMP/move6.git" "$TMP/move6-other" 2>/dev/null
commit "$TMP/move6-other" apps/b/other.js 'landed elsewhere' "another run's landing" && git -C "$TMP/move6-other" push -q origin main
commit "$R" apps/a/code.js 'x=m6' "local code while main is behind"
out6="$(cd "$R" && "$GUARD" move review/2026-01-01-t6 2>&1)"
B6="$(printf '%s\n' "$out6" | sed -n 's/^move: BASE=\([0-9a-f]*\) HEAD=\([0-9a-f]*\)$/\1/p')"
H6="$(printf '%s\n' "$out6" | sed -n 's/^move: BASE=\([0-9a-f]*\) HEAD=\([0-9a-f]*\)$/\2/p')"
if [[ -n "$B6" && -n "$H6" ]] && git -C "$R" merge-base --is-ancestor "$B6" "$H6" && [[ -z "$(git -C "$R" diff --name-only "$B6" "$H6" -- apps/b)" ]]; then echo "ok   move: BASE is an ancestor of HEAD when main was behind"; else echo "FAIL move: BASE $B6 is not the merge-base of HEAD $H6"; printf '%s\n' "$out6" | sed 's/^/     /'; FAILS=1; fi
[[ "$out6" != *"REWRITE ON MAIN"* ]] && echo "ok   move: no rewrite instruction when nothing was skipped" || { echo "FAIL move: a rewrite instruction with nothing skipped"; FAILS=1; }

# An empty pick: another run already pushed the same journal line, so the
# docs commit's change is on origin/main. It is skipped, not reported.
R="$(new_repo move7)"
git clone -q "$TMP/move7.git" "$TMP/move7-other" 2>/dev/null
commit "$TMP/move7-other" journal/day.md 'same line' "the same line, pushed by another run" && git -C "$TMP/move7-other" push -q origin main
commit "$R" journal/day.md 'same line' "the same line, local"
EMPTY7="$(git -C "$R" rev-parse HEAD)"
commit "$R" apps/a/code.js 'x=m7' "code to move"
set +e; out7="$(cd "$R" && "$GUARD" move review/2026-01-01-t7 2>&1)"; rc7=$?; set -e
if [[ "$rc7" == 0 ]] && ! printf '%s\n' "$out7" | grep 'not brought back' | grep -q "${EMPTY7:0:7}" \
   && [[ "$out7" != *"REWRITE ON MAIN"* && "$out7" == *"brought back to main (new SHAs): none"* ]] \
   && [[ -z "$(git -C "$R" status --porcelain)" ]] && ! git -C "$R" rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null; then
  echo "ok   move: an empty pick is skipped with no rewrite instruction"
else echo "FAIL move: the empty pick was reported or left behind (exit $rc7)"; printf '%s\n' "$out7" | sed 's/^/     /'; FAILS=1; fi

# Every reviewed path: a commit touching only that path moves and is not
# named a mixed commit.
RP="$STUDIO_REVIEWED_PATHS"
R="$(new_repo move8)"
for rp in $RP; do
  case "$rp" in *.md) commit "$R" "$rp" "only $rp" "only $rp" ;; *) commit "$R" "$rp/x.txt" "only $rp" "only $rp" ;; esac
done
set +e; out8="$(cd "$R" && "$GUARD" move review/2026-01-01-t8 2>&1)"; rc8=$?; set -e
if [[ -n "$RP" && "$rc8" == 0 && "$out8" != *"mixed commits"* && "$(git -C "$R" rev-list --count origin/main..review/2026-01-01-t8)" == "$(echo $RP | wc -w | tr -d ' ')" ]]; then
  echo "ok   move: a commit in any one reviewed path is not named mixed"
else echo "FAIL move: a single reviewed path named mixed, or not moved (exit $rc8)"; printf '%s\n' "$out8" | sed 's/^/     /'; FAILS=1; fi

# Another run has staged an unrelated change and a new file: move refuses
# before the reset, so nothing is moved and nothing is unstaged.
R="$(new_repo move9)"
commit "$R" README.md 'readme' "readme" && git -C "$R" push -q origin main
commit "$R" apps/a/code.js 'x=m9' "code to move"
commit "$R" journal/day.md 'j9' "journal to bring back"
M9="$(git -C "$R" rev-parse main)"
echo "another run's line" >> "$R/README.md"; echo "another run's new file" > "$R/notes.md"
git -C "$R" add README.md notes.md
set +e; out9="$(cd "$R" && "$GUARD" move review/2026-01-01-t9 2>&1)"; rc9=$?; set -e
if [[ "$rc9" == 1 && "$out9" == *"index has staged changes"* && "$(git -C "$R" rev-parse main)" == "$M9" \
   && "$(git -C "$R" diff --cached --name-only | tr '\n' ' ')" == "README.md notes.md " ]]; then
  echo "ok   move: a staged change elsewhere is refused, nothing moved or unstaged"
else echo "FAIL move: staged changes not refused or lost (exit $rc9, staged: $(git -C "$R" diff --cached --name-only | tr '\n' ' '))"; printf '%s\n' "$out9" | sed 's/^/     /'; FAILS=1; fi

# git cannot list what one local commit touches: move must not take it for
# docs and cherry-pick it back to main. It stays on the branch and is named.
R="$(new_repo move10)"
commit "$R" apps/a/code.js 'x=m10' "code whose paths git cannot list"
CODE10="$(git -C "$R" rev-parse HEAD)"
commit "$R" journal/day.md 'j10' "journal to bring back"
make_shim move10 "$LIST_PATHS"' && [ "$(git log -1 --format=%s "$7")" = "code whose paths git cannot list" ] && { echo "fatal: diff broke" >&2; exit 128; }'
set +e; out10="$(run_shim move10 "$R" "$GUARD" move review/2026-01-01-t10 2>&1)"; rc10=$?; set -e
if [[ "$rc10" == 0 && -z "$(git -C "$R" diff --name-only origin/main main -- apps)" ]]; then echo "ok   move: a commit whose paths git cannot list is not brought back to main"; else echo "FAIL move: an unlisted commit reached main or the move failed (exit $rc10)"; printf '%s\n' "$out10" | sed 's/^/     /'; FAILS=1; fi
if printf '%s\n' "$out10" | grep '^move: REWRITE ON MAIN: commits whose paths git could not list' | grep -q "${CODE10:0:7}" \
   && [[ "$(git -C "$R" log --format=%s origin/main..main)" == "journal to bring back" ]]; then echo "ok   move: it is named on a REWRITE ON MAIN line, and the docs commit still comes back"; else echo "FAIL move: no REWRITE ON MAIN line for the unlisted commit, or the docs commit is missing"; printf '%s\n' "$out10" | sed 's/^/     /'; FAILS=1; fi

# git cannot list the local commits before the move starts: that is exit 2
# with nothing changed, never "nothing to move".
R="$(new_repo move11)"
commit "$R" apps/a/code.js 'x=m11' "code to move"
M11="$(git -C "$R" rev-parse main)"
make_shim move11 '[ "$1" = rev-list ] && case "$2" in origin/main..*) echo "fatal: rev-list broke" >&2; exit 128;; esac'
set +e; out11="$(run_shim move11 "$R" "$GUARD" move review/2026-01-01-t11 2>&1)"; rc11=$?; set -e
if [[ "$rc11" == 2 && "$out11" == *"move: could not list the local commits on main"* && "$out11" != *"nothing to move"* \
   && "$(git -C "$R" rev-parse main)" == "$M11" ]] && ! git -C "$R" rev-parse -q --verify refs/heads/review/2026-01-01-t11 >/dev/null; then
  echo "ok   move: a failure to list the local commits is exit 2 and changes nothing"
else echo "FAIL move: a rev-list failure read as nothing to move, or main changed (exit $rc11)"; printf '%s\n' "$out11" | sed 's/^/     /'; FAILS=1; fi

# git cannot list the commits after main is reset: no docs commit comes back,
# so the move must say REWRITE ON MAIN, and the branch still holds them all.
R="$(new_repo move12)"
commit "$R" apps/a/code.js 'x=m12' "code to move"
commit "$R" journal/day.md 'j12' "journal that cannot come back"
M12="$(git -C "$R" rev-parse main)"
make_shim move12 '[ "$1" = rev-list ] && [ "$2" = --reverse ] && { echo "fatal: rev-list broke" >&2; exit 128; }'
set +e; out12="$(run_shim move12 "$R" "$GUARD" move review/2026-01-01-t12 2>&1)"; rc12=$?; set -e
if printf '%s\n' "$out12" | grep -q '^move: REWRITE ON MAIN: could not list the commits' \
   && [[ "$(git -C "$TMP/move12.git" rev-parse review/2026-01-01-t12 2>/dev/null)" == "$M12" ]]; then
  echo "ok   move: a failure to list the commits after the reset says REWRITE ON MAIN and pushes the branch (exit $rc12)"
else echo "FAIL move: a rev-list failure after the reset printed no REWRITE ON MAIN line, or the branch was not pushed (exit $rc12)"; printf '%s\n' "$out12" | sed 's/^/     /'; FAILS=1; fi

# git cannot tell whether a code commit also carries docs: count it as mixed,
# so its docs are not dropped from main without a word.
R="$(new_repo move13)"
echo 'x=mix13' >> "$R/apps/a/code.js"; echo 'mixed journal 13' >> "$R/journal/day.md"
git -C "$R" add -A && git -C "$R" commit -q -m "mixed code and journal 13"
MIX13="$(git -C "$R" rev-parse HEAD)"
make_shim move13 '[ "$1" = diff ] && [ "$2" = --name-only ] && [ "$5" = -- ] && [ "$6" = . ] && { echo "fatal: diff broke" >&2; exit 128; }'
set +e; out13="$(run_shim move13 "$R" "$GUARD" move review/2026-01-01-t13 2>&1)"; rc13=$?; set -e
if printf '%s\n' "$out13" | grep '^move: REWRITE ON MAIN: mixed commits' | grep -q "${MIX13:0:7}"; then
  echo "ok   move: a failure to list a code commit's docs names it as mixed (exit $rc13)"
else echo "FAIL move: a diff failure dropped a mixed commit's docs silently (exit $rc13)"; printf '%s\n' "$out13" | sed 's/^/     /'; FAILS=1; fi
[[ "$rc12" == 0 ]] && echo "ok   move: a failure to list the commits after the reset still exits 0 once the branch is pushed" || { echo "FAIL move: move12 exit $rc12, wanted 0"; FAILS=1; }

# git merge-base fails after the reset: the move must not stop silently. It
# prints BASE=unknown, still brings the docs back and pushes the branch.
R="$(new_repo move14)"
commit "$R" apps/a/code.js 'x=m14' "code to move"
commit "$R" journal/day.md 'j14' "journal to bring back 14"
M14="$(git -C "$R" rev-parse main)"
make_shim move14 '[ "$1" = merge-base ] && [ "$2" = origin/main ] && { echo "fatal: merge-base broke" >&2; exit 128; }'
set +e; out14="$(run_shim move14 "$R" "$GUARD" move review/2026-01-01-t14 2>&1)"; rc14=$?; set -e
if [[ "$rc14" == 0 && "$out14" == *"move: BASE=unknown HEAD=$M14"* ]] \
   && [[ "$(git -C "$TMP/move14.git" rev-parse review/2026-01-01-t14 2>/dev/null)" == "$M14" ]] \
   && [[ "$(git -C "$R" log --format=%s origin/main..main)" == "journal to bring back 14" ]]; then
  echo "ok   move: a merge-base failure after the reset prints BASE=unknown, brings the docs back and pushes"
else echo "FAIL move: a merge-base failure after the reset stopped the move or lost a line (exit $rc14)"; printf '%s\n' "$out14" | sed 's/^/     /'; FAILS=1; fi

# git cannot read a stopped cherry-pick's state: a conflicting docs pick must
# not be skipped as empty. It is named, the branch is pushed, and the failed
# check for unmerged files is exit 1 with its own line.
R="$(new_repo move15)"
echo 'x=mix15' >> "$R/apps/a/code.js"; echo 'mixed journal 15' >> "$R/journal/day.md"
git -C "$R" add -A && git -C "$R" commit -q -m "mixed code and journal 15"
commit "$R" journal/day.md 'after mixed 15' "journal on top of the mixed one 15"
DOC15="$(git -C "$R" rev-parse HEAD)"
make_shim move15 '[ "$1" = diff ] && { { [ "$2" = --name-only ] && [ "$3" = --diff-filter=U ]; } || { [ "$2" = --cached ] && [ "$3" = --name-only ]; }; } && { echo "fatal: diff broke" >&2; exit 128; }'
set +e; out15="$(run_shim move15 "$R" "$GUARD" move review/2026-01-01-t15 2>&1)"; rc15=$?; set -e
if printf '%s\n' "$out15" | grep '^move: REWRITE ON MAIN: docs-only commits not brought back' | grep -q "${DOC15:0:7}" \
   && [[ "$rc15" == 1 && "$out15" == *"move: git could not check the main checkout for unmerged files"* ]] \
   && [[ -n "$(git -C "$TMP/move15.git" rev-parse -q --verify review/2026-01-01-t15 2>/dev/null)" ]] \
   && ! git -C "$R" rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null; then
  echo "ok   move: a pick whose state git cannot read is named, not skipped as empty, and the failed check is exit 1 after the push"
else echo "FAIL move: a conflicting pick was skipped as empty, or the failed check was not reported (exit $rc15)"; printf '%s\n' "$out15" | sed 's/^/     /'; FAILS=1; fi

R="$(new_repo move4)"
git -C "$R" checkout -q -b review/2026-01-01-t4 origin/main && commit "$R" apps/a/code.js 'fix on the branch' "a review fix commit" && git -C "$R" checkout -q main
commit "$R" apps/a/code.js 'x=m4' "unrelated local code"
B4="$(git -C "$R" rev-parse review/2026-01-01-t4)"
expect "move: an existing branch that is not part of main is refused" 2 run_in "$R" "$GUARD" move review/2026-01-01-t4
[[ "$(git -C "$R" rev-parse review/2026-01-01-t4)" == "$B4" ]] && echo "ok   move: and that branch is left unchanged" || { echo "FAIL move: the existing branch was overwritten"; FAILS=1; }

# Another run stages a file in the middle of the move: the cherry-pick refuses
# before starting, and the staged edit must survive.
R="$(new_repo move5)"
commit "$R" apps/a/code.js 'x=m5' "code to move"
commit "$R" journal/day.md 'j5' "journal to bring back"
REALGIT="$(command -v git)"; mkdir -p "$TMP/shim5"
cat > "$TMP/shim5/git" <<SHIM
#!/bin/sh
if [ "\$1" = cherry-pick ] && [ ! -f "$TMP/shim5.done" ]; then
  touch "$TMP/shim5.done"; echo "staged by another run" >> "$R/journal/day.md"; "$REALGIT" -C "$R" add journal/day.md
fi
exec "$REALGIT" "\$@"
SHIM
chmod +x "$TMP/shim5/git"
set +e; out5="$(cd "$R" && PATH="$TMP/shim5:$PATH" "$GUARD" move review/2026-01-01-t5 2>&1)"; set -e
if grep -q "staged by another run" "$R/journal/day.md" && [[ -n "$(git -C "$R" diff --cached --name-only)" ]]; then echo "ok   move: another run's staged edit survives a refused cherry-pick"; else echo "FAIL move: the staged edit was lost"; echo "$out5" | sed 's/^/     /'; FAILS=1; fi

# The docs-only trailer form, exactly as the self-review skill writes it, is
# read like the full one.
R="$(new_repo docsonly)"
S="$(git -C "$R" rev-parse origin/main)"
git -C "$R" checkout -q -b review/d1 origin/main
commit "$R" .claude/skills/x/SKILL.md 'reworded' "skill wording"
HD="$(git -C "$R" rev-parse HEAD)"
git -C "$R" checkout -q --detach origin/main
git -C "$R" merge -q --no-ff -m "merge review/d1" -m "Reviewed-by: fresh reviewer agent, ${S:0:7}..${HD:0:7}, 1 round, docs-only path (0 blocker, 0 major, 3 minor; 3 fixed)" -m "Fixed-after-review: none" review/d1
git -C "$R" push -q origin HEAD:main && git -C "$R" checkout -q main && git -C "$R" reset -q --hard origin/main
expect "audit: a docs-only Reviewed-by trailer is read and passes" 0 run_in "$R" "$GUARD" audit "$S"

# Configuration: the reviewed paths, the main branch and the branch prefix
# from the remote main's .claude/studio.json when no environment override is
# set. Never from the working tree: a local commit cannot narrow them.
unset STUDIO_REVIEWED_PATHS
cfg() { # repo, json: write the working tree's copy only
  mkdir -p "$1/.claude"; printf '%s\n' "$2" > "$1/.claude/studio.json"
}
cfg_main() { # repo, json, [branch]: commit the config and push it to the remote main
  cfg "$1" "$2"
  git -C "$1" add .claude/studio.json && git -C "$1" commit -q -m config && git -C "$1" push -q origin "${3:-main}"
}
R="$(new_repo cfg1)"
cfg_main "$R" '{"core": {"review": {"reviewed_paths": ["src/"]}}}'
commit "$R" apps/a/code.js 'x=c1' "code outside the configured paths"
expect "config: a path outside core.review.reviewed_paths passes" 0 run_in "$R" "$GUARD" push
commit "$R" src/m.py 'y=1' "code in a configured path"
expect "config: a path in core.review.reviewed_paths fails" 1 run_in "$R" "$GUARD" push
git -C "$R" reset -q --hard origin/main
commit "$R" .claude/studio.json '' "config only"
expect "config: a local commit that only changes studio.json fails" 1 run_in "$R" "$GUARD" push
expect "config: studio.json is reviewed even when the env list omits it" 1 env STUDIO_REVIEWED_PATHS=apps bash -c 'cd "$1" && "$2" push' _ "$R" "$GUARD"
# The bypass: an unreviewed local commit narrows the reviewed paths to a
# path that does not exist, then code lands under a default reviewed path.
R="$(new_repo cfgbypass)"
cfg "$R" '{"core": {"review": {"reviewed_paths": ["nothing"]}}}'
git -C "$R" add .claude/studio.json && git -C "$R" commit -q -m "narrow the reviewed paths"
commit "$R" apps/a/code.js 'x=bypass' "code under apps"
expect "config: a local commit narrowing reviewed_paths does not switch the guard off" 1 run_in "$R" "$GUARD" push
expect_out "config: and the code commit is named" "code under apps" run_in "$R" "$GUARD" push
# The same narrowing left uncommitted in the working tree changes nothing either.
git -C "$R" reset -q --hard origin/main
cfg "$R" '{"core": {"review": {"reviewed_paths": ["nothing"]}}}'
commit "$R" apps/a/code.js 'x=bypass2' "code under apps again"
expect "config: an uncommitted narrowing does not switch the guard off" 1 run_in "$R" "$GUARD" push
# The audit reads the same copy: a direct commit on main changing only the
# config is a gap, whatever the config lists.
R="$(new_repo cfgaudit)"
S="$(git -C "$R" rev-parse origin/main)"
cfg_main "$R" '{"core": {"review": {"reviewed_paths": ["src"]}}}'
expect "audit: a direct commit on main changing only studio.json is a gap" 1 run_in "$R" "$GUARD" audit "$S"
expect_out "audit: and is named a direct commit" "gap: direct commit to main touching reviewed paths" run_in "$R" "$GUARD" audit "$S"
R="$(new_repo cfg2)"
expect "config: with no studio.json the defaults apply and apps is reviewed" 0 run_in "$R" "$GUARD" push
commit "$R" apps/a/code.js 'x=c2' "code under a default reviewed path"
expect "config: and a default reviewed path fails" 1 run_in "$R" "$GUARD" push
cfg "$R" '{"core": {"review": {"reviewed_paths": ["src"]}'
expect "config: a broken working-tree studio.json fails closed with exit 2" 2 run_in "$R" "$GUARD" push
expect_out "config: and says the config could not be read" "could not read core.main_branch" run_in "$R" "$GUARD" push
git -C "$R" reset -q --hard origin/main
for bad in '{"core": {"review": {"reviewed_paths": ["src"]}' '{"core": {"review": {"reviewed_paths": []}}}' '{"core": {"review": {"reviewed_paths": 7}}}'; do
  R="$(new_repo "cfgbad$RANDOM")"
  # Pushed straight to the remote main, then the working tree reverts to no
  # config, so only the remote copy is bad.
  cfg_main "$R" "$bad"
  git -C "$R" rm -q .claude/studio.json && git -C "$R" commit -q -m "local: drop the config"
  expect "config: a bad remote studio.json ($bad) fails closed with exit 2" 2 run_in "$R" "$GUARD" push
done
expect_out "config: and says the remote copy could not be read" "from origin/main:.claude/studio.json" run_in "$R" "$GUARD" push
# A working tree naming another main branch than the remote main's committed
# copy stops.
R="$(new_repo cfgmain)"
cfg_main "$R" '{"core": {"main_branch": "main"}}'
git -C "$R" push -q origin main:trunk
cfg "$R" '{"core": {"main_branch": "trunk"}}'
expect "config: the working tree and the remote main naming different main branches is exit 2" 2 run_in "$R" "$GUARD" push
expect_out "config: and says so" "land the config change through review" run_in "$R" "$GUARD" push
# A repo whose main branch is master, with no config committed on the remote
# yet: the working tree's names locate the branch, and the defaults are the
# reviewed paths. Before, the guard compared master with the default main and
# exited 2, which the push hook turned into a deny of the push landing the
# config.
d="$TMP/master"
git init -q --bare -b master "$d.git"; git clone -q "$d.git" "$d" 2>/dev/null
mkdir -p "$d/apps/a"; echo 'x=1' > "$d/apps/a/code.js"
git -C "$d" add -A && git -C "$d" commit -q -m base && git -C "$d" push -q origin master
cfg "$d" '{"core": {"main_branch": "master", "review": {"push_hook": true}}}'
expect "config: master, no config on the remote, nothing local, passes" 0 run_in "$d" "$GUARD" push
expect "config: and with the default reviewed paths too" 0 env -u STUDIO_REVIEWED_PATHS bash -c 'cd "$1" && "$2" push' _ "$d" "$GUARD"
commit "$d" apps/a/code.js 'x=m' "code on master"
expect "config: master, no remote config, a default reviewed path still fails" 1 env -u STUDIO_REVIEWED_PATHS bash -c 'cd "$1" && "$2" push' _ "$d" "$GUARD"
expect_out "config: and names master" "unreviewed local commit on master" run_in "$d" "$GUARD" push
git -C "$d" reset -q --hard origin/master
git -C "$d" add .claude/studio.json && git -C "$d" commit -q -m "config, unreviewed"
expect "config: master, no remote config, a local studio.json commit still fails" 1 env -u STUDIO_REVIEWED_PATHS bash -c 'cd "$1" && "$2" push' _ "$d" "$GUARD"
# A main branch named trunk, from the config, and from the environment.
d="$TMP/trunk"
git init -q --bare -b trunk "$d.git"; git clone -q "$d.git" "$d" 2>/dev/null
git -C "$d" checkout -q -b trunk 2>/dev/null || true
mkdir -p "$d/apps/a"; echo 'x=1' > "$d/apps/a/code.js"
git -C "$d" add -A && git -C "$d" commit -q -m base && git -C "$d" push -q origin trunk
cfg_main "$d" '{"core": {"main_branch": "trunk", "review": {"branch_prefix": "rev/"}}}' trunk
expect "config: core.main_branch trunk, nothing local, passes" 0 run_in "$d" "$GUARD" push
commit "$d" apps/a/code.js 'x=t' "code on trunk"
expect "config: core.main_branch trunk, a local code commit fails" 1 run_in "$d" "$GUARD" push
expect_out "config: and names trunk" "unreviewed local commit on trunk" run_in "$d" "$GUARD" push
expect "config: move refuses a branch without the configured prefix" 2 run_in "$d" "$GUARD" move review/2026-01-01-x
expect_out "config: move moves to a branch with the configured prefix" "move: pushed rev/2026-01-01-x" run_in "$d" "$GUARD" move rev/2026-01-01-x
rm "$d/.claude/studio.json"
commit "$d" apps/a/code.js 'x=t2' "code on trunk again"
expect "env: STUDIO_MAIN_BRANCH overrides the default main" 1 env STUDIO_MAIN_BRANCH=trunk bash -c 'cd "$1" && "$2" push' _ "$d" "$GUARD"
expect "env: without it the guard looks for main and stops with exit 2" 2 run_in "$d" "$GUARD" push
git -C "$d" remote rename origin upstream
expect "env: STUDIO_REMOTE names the remote" 1 env STUDIO_MAIN_BRANCH=trunk STUDIO_REMOTE=upstream bash -c 'cd "$1" && "$2" push' _ "$d" "$GUARD"

exit "$FAILS"
