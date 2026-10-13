#!/usr/bin/env bash
# Builds the toy example: a tiny Python project with one change made the
# kit's way (plan, review branch in its own worktree, a fix after review,
# a --no-ff landing merge with the review trailers, cleanup).
#
#   examples/make_toy_repo.sh <dir>
#
# Creates, inside <dir> (which must not exist or must be empty):
#   <dir>/origin.git          a bare repository standing in for the remote
#   <dir>/toy                 the working clone, on main
# and leaves <dir>/toy-review empty: the default worktree root
# (../<repo>-review), where the review worktree lived until the cleanup.
#
# Nothing here calls Claude Code. The agent steps (planner, builder, the two
# review passes) are written as commits and messages the way a session would
# leave them, so the result can be inspected and audited offline.
# Plain bash 3.2, git 2.28 or later (for init -b).
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <dir>" >&2
  exit 2
fi
OUT="$1"
if [[ -e "$OUT" ]] && [[ -n "$(ls -A "$OUT" 2>/dev/null)" ]]; then
  echo "make_toy_repo: $OUT exists and is not empty" >&2
  exit 2
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
ORIGIN="$OUT/origin.git"
REPO="$OUT/toy"
WR="$OUT/toy-review"

# A fixed identity and no user or system config, so the result is the same
# on every machine.
export GIT_AUTHOR_NAME="Toy Author" GIT_AUTHOR_EMAIL="author@example.invalid"
export GIT_COMMITTER_NAME="Toy Author" GIT_COMMITTER_EMAIL="author@example.invalid"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

git init -q --bare -b main "$ORIGIN"
git clone -q "$ORIGIN" "$REPO" 2>/dev/null
git -C "$REPO" checkout -q -b main 2>/dev/null || true

# ---------------------------------------------------------------- the base
mkdir -p "$REPO/src/toy" "$REPO/tests" "$REPO/.claude"

cat > "$REPO/src/toy/__init__.py" <<'EOF'
"""A toy package for the subagent-studio example."""

__version__ = "0.1.0"
EOF

cat > "$REPO/tests/test_toy.py" <<'EOF'
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src"))

import toy  # noqa: E402


class VersionTest(unittest.TestCase):
    def test_version(self):
        self.assertEqual(toy.__version__, "0.1.0")


if __name__ == "__main__":
    unittest.main()
EOF

cat > "$REPO/.claude/studio.json" <<'EOF'
{
  "core": {
    "main_branch": "main",
    "remote": "origin",
    "ci_commands": ["python3 -m unittest discover -s tests"],
    "review": {
      "passes": 2,
      "reviewed_paths": ["src", "tests", ".claude", "CLAUDE.md"],
      "land": "merge-no-ff",
      "push_hook": false
    }
  }
}
EOF

cat > "$REPO/CLAUDE.md" <<'EOF'
# Toy project

A tiny Python package used to show the subagent-studio workflow.

<!-- subagent-studio:begin -->
## How this project uses subagents
- The main session coordinates; fresh agents do hands-on work (skill
  `orchestrator-rules`). It never edits code, runs tests, reads diffs or
  deploys, and reads `git diff --stat` only.
- Big work starts with a plan (skill `plan-then-build`); each step goes to a
  fresh `studio-core:builder`.
- Changes to src, tests, .claude and CLAUDE.md reach main only through skill
  `self-review`: 2 review passes, landed by merge-no-ff.
- Lookups go to `studio-core:searcher`. Agent reports stay under 400 words.
- Config: `.claude/studio.json`.
<!-- subagent-studio:end -->
EOF

cat > "$REPO/README.md" <<'EOF'
# toy

Run the tests with `python3 -m unittest discover -s tests`.
EOF

git -C "$REPO" add -- src tests .claude CLAUDE.md README.md
git -C "$REPO" commit -q -m "toy: base package, tests and studio config"
git -C "$REPO" push -q origin main

# ---------------------------------------------------------------- the plan
# plans/ is not a reviewed path, so the saved plan goes straight to main
# before the first builder starts (skill plan-then-build, step 4).
mkdir -p "$REPO/plans"
cat > "$REPO/plans/add-greeting.md" <<'EOF'
# Plan: t-1-add-greeting
Task: T-1 · Written: 2026-10-13 · Planner: studio-core:planner

## Goal
The package offers `toy.greet(name)`, which returns `Hello, <name>!` for a
name and refuses an empty one. Acceptance: `python3 -m unittest discover -s tests`
passes with tests for both cases.

## What I read and what I found
- `src/toy/__init__.py` holds only `__version__`.
- `tests/test_toy.py` is a unittest module that puts `src/` on `sys.path`.
- `.claude/studio.json` names one CI command:
  `python3 -m unittest discover -s tests`.

## Constraints that bind this work
- Standard library only; Python 3.9 and later.
- `src/`, `tests/`, `.claude/` and `CLAUDE.md` are reviewed paths: the change
  lands through skill `self-review`.

## Steps
### Step 1: add greet and its tests
Files: `src/toy/__init__.py`, `tests/test_toy.py` · Does: adds
`greet(name: str) -> str` returning `f"Hello, {name}!"`, with a test ·
Acceptance: `python3 -m unittest discover -s tests` passes and includes a
greet test · Risk: none beyond the function · Parallel with: none ·
Model: sonnet (the file, the behaviour and the acceptance are all given)

## Out of scope
Localised greetings.

## Risks and how each is caught
A wrong greeting string is caught by the unit test.

## Open questions
None.

## Outcome
Landed on main by a --no-ff merge of `review/2026-10-13-t-1-greeting`.
The fresh review found one major (an empty name gave `Hello, !`); the
author fixed it with a test before the landing.
EOF
git -C "$REPO" add -- plans/add-greeting.md
git -C "$REPO" commit -q -m "plan: T-1 add greeting" -- plans/add-greeting.md
git -C "$REPO" push -q origin main

# ---------------------------------------------- the review branch (step 1)
T="review/2026-10-13-t-1-greeting"
W="$WR/t-1-greeting"
mkdir -p "$WR"
git -C "$REPO" fetch -q origin
git -C "$REPO" worktree add -q -b "$T" "$W" origin/main

# What the builder wrote in the worktree.
cat > "$W/src/toy/__init__.py" <<'EOF'
"""A toy package for the subagent-studio example."""

__version__ = "0.1.0"


def greet(name: str) -> str:
    """Return a greeting for name."""
    return f"Hello, {name}!"
EOF
cat > "$W/tests/test_toy.py" <<'EOF'
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src"))

import toy  # noqa: E402


class VersionTest(unittest.TestCase):
    def test_version(self):
        self.assertEqual(toy.__version__, "0.1.0")


class GreetTest(unittest.TestCase):
    def test_greets_by_name(self):
        self.assertEqual(toy.greet("Ada"), "Hello, Ada!")


if __name__ == "__main__":
    unittest.main()
EOF
git -C "$W" add -- src/toy/__init__.py tests/test_toy.py
git -C "$W" commit -q -m "toy: add greet (T-1 step 1)" -- src/toy/__init__.py tests/test_toy.py
git -C "$W" push -q -u origin "$T" 2>/dev/null
git -C "$W" fetch -q origin
BASE="$(git -C "$W" merge-base origin/main "$T")"
HEAD_SHA="$(git -C "$W" rev-parse "$T")"

# ------------------------- passes one and two happen here (agents, offline)
# Pass two, the fresh reviewer on BASE..HEAD, reported one major:
# greet("") returns "Hello, !". The author's fix, with a test that fails
# without it (skill self-review, step 5):
cat > "$W/src/toy/__init__.py" <<'EOF'
"""A toy package for the subagent-studio example."""

__version__ = "0.1.0"


def greet(name: str) -> str:
    """Return a greeting for name. An empty or blank name is an error."""
    if not name.strip():
        raise ValueError("name must not be empty")
    return f"Hello, {name}!"
EOF
cat > "$W/tests/test_toy.py" <<'EOF'
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src"))

import toy  # noqa: E402


class VersionTest(unittest.TestCase):
    def test_version(self):
        self.assertEqual(toy.__version__, "0.1.0")


class GreetTest(unittest.TestCase):
    def test_greets_by_name(self):
        self.assertEqual(toy.greet("Ada"), "Hello, Ada!")

    def test_refuses_an_empty_name(self):
        with self.assertRaises(ValueError):
            toy.greet("")
        with self.assertRaises(ValueError):
            toy.greet("   ")


if __name__ == "__main__":
    unittest.main()
EOF
git -C "$W" add -- src/toy/__init__.py tests/test_toy.py
git -C "$W" commit -q -m "toy: greet refuses an empty name (review finding)" -- src/toy/__init__.py tests/test_toy.py
git -C "$W" push -q origin "$T" 2>/dev/null
FIX="$(git -C "$W" rev-parse "$T")"

# -------------------------------------------------------- landing (step 6)
TIP="$FIX"
test "$(git -C "$W" rev-parse "$T")" = "$(git -C "$W" rev-parse "$TIP")"
git -C "$W" fetch -q origin
git -C "$W" checkout -q --detach origin/main
git -C "$W" merge -q --no-ff "$T" -m "merge $T: greet" \
  -m "Reviewed-by: fresh reviewer agent, ${BASE:0:7}..${HEAD_SHA:0:7}, 1 round (0 blocker, 1 major, 0 minor; 1 fixed, 0 queued)" \
  -m "Fixed-after-review: author, ${HEAD_SHA:0:7}..${TIP:0:7}, 1 fix (major: empty name gave 'Hello, !')"
git -C "$W" push -q origin HEAD:main

# ------------------------------------------------------- cleanup (step 7)
git -C "$W" fetch -q origin
git -C "$W" merge-base --is-ancestor "$T" origin/main
test -z "$(git -C "$W" status --porcelain --untracked-files=no)"
git -C "$REPO" worktree remove --force "$W"
git -C "$REPO" push -q origin --delete "$T" 2>/dev/null
git -C "$REPO" branch -q -D "$T"
git -C "$REPO" pull -q --rebase origin main

echo "toy repo: $REPO"
echo "origin:   $ORIGIN"
echo "landing:  $(git -C "$REPO" log -1 --format='%h %s' origin/main)"
echo "audit it: (cd $REPO && <kit>/plugins/studio-core/scripts/review_guard.sh audit $(git -C "$REPO" rev-list --max-parents=0 HEAD | head -n 1))"
