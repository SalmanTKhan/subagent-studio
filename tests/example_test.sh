#!/usr/bin/env bash
# Builds the toy example (examples/make_toy_repo.sh) in a temp directory and
# checks it with the kit's own review guard and the repo's own config.
#   bash tests/example_test.sh
# Exit 1 if any case fails.
set -euo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$KIT/plugins/studio-core/scripts/review_guard.sh"
CONFIG="$KIT/plugins/studio-core/scripts/studio_config.py"
unset CLAUDE_PROJECT_DIR STUDIO_REVIEWED_PATHS STUDIO_MAIN_BRANCH STUDIO_REMOTE
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
expect() { # name, wanted exit ("nonzero" for any failure), command...
  local name="$1" want="$2" got out; shift 2
  set +e; out="$("$@" 2>&1)"; got=$?; set -e
  if [[ "$got" == "$want" ]] || { [[ "$want" == nonzero ]] && (( got != 0 )); }; then
    echo "ok   $name"
  else
    echo "FAIL $name: exit $got, wanted $want"; echo "$out" | sed 's/^/     /'; FAILS=1
  fi
}
run_in() { (cd "$1" && shift && "$@"); }

expect "make_toy_repo.sh builds the example" 0 bash "$KIT/examples/make_toy_repo.sh" "$TMP/ex"
R="$TMP/ex/toy"
ROOT="$(git -C "$R" rev-list --max-parents=0 HEAD | head -n 1)"

expect "the toy config validates" 0 python3 "$CONFIG" validate --root "$R"
expect "audit from the root commit passes" 0 run_in "$R" bash "$GUARD" audit "$ROOT"
expect "the landing carries both trailers" 0 \
  sh -c "git -C '$R' log -1 --format=%B origin/main | grep -q '^Reviewed-by: fresh reviewer agent, ' && git -C '$R' log -1 --format=%B origin/main | grep -q '^Fixed-after-review: author, '"
expect "the landing is a merge" 0 sh -c "test \"\$(git -C '$R' rev-list --parents -n 1 origin/main | wc -w)\" -eq 3"
expect "the review worktree and branch were cleaned up" 0 \
  sh -c "test -z \"\$(git -C '$R' branch --list 'review/*')\" && test -z \"\$(git -C '$R' ls-remote --heads origin 'review/*')\" && test \"\$(git -C '$R' worktree list | wc -l)\" -eq 1"
expect "the unit tests pass" 0 run_in "$R" python3 -m unittest discover -s tests
expect "push passes with nothing local" 0 run_in "$R" bash "$GUARD" push

# A direct, unreviewed commit to src/ on main.
printf '\n\ndef shout(name):\n    return name.upper()\n' >> "$R/src/toy/__init__.py"
git -C "$R" commit -q -m "toy: shout, unreviewed" -- src/toy/__init__.py
expect "push refuses a direct commit to src/" nonzero run_in "$R" bash "$GUARD" push
expect "push exits 1 for it" 1 run_in "$R" bash "$GUARD" push

# Pushed anyway, behind the guard's back: the audit names it.
git -C "$R" push -q origin main
expect "audit names the direct commit as a gap" 1 run_in "$R" bash "$GUARD" audit "$ROOT"

if (( FAILS )); then echo "example_test: FAILED"; exit 1; fi
echo "example_test: all passed"
