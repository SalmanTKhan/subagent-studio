---
name: self-review
description: The review every change to a reviewed path gets before it reaches the main branch. The change lives on a review branch in its own worktree; pass one by a fresh reviewer-pass-one with the author's checklist, pass two by one fresh reviewer on fixed BASE..HEAD SHAs; blockers and majors fixed with a test; then a --no-ff landing with Reviewed-by and Fixed-after-review trailers, or a pull request. Use before any change to code, config, prompts or skills lands.
---
# Review before the main branch

**The one rule: unreviewed code never sits on the main branch, local or
remote.** It lives on a review branch in its own git worktree, pushed as
that branch, until a fresh reviewer agent that did not write it has read it
on fixed SHAs. The shared tree stays on the main branch and takes only
reviewed landings and plain docs. Why: `reference/why.md`.

**Script paths** below are written for a plugin install: Claude Code fills
in the plugin's directory here, not in `reference/` files or
`reviewer-prompt.md`. If one shows unreplaced, the plugin root is two
levels above this skill's base directory.

## Config it honours
Read each with `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/studio_config.py get <key>`:
- `core.main_branch`, `core.remote`: where reviewed work lands.
- `core.review.reviewed_paths`: what needs review. A change touching none
  of them is plain docs; with `core.review.docs_only` true it lands without
  a review branch. The guard checks only reviewed paths; with `docs_only`
  false, every other change taking these steps is a rule, not a check.
- `core.review.branch_prefix` (default `review/`), `core.worktree_root`
  (empty means `../<repo>-review`, a relative path is from the repo root).
- `core.review.passes`: 2 runs both passes; 1 skips pass one.
- `core.review.land`: `merge-no-ff` lands it; `pr` opens a pull request.
- `core.ci_commands`: the checks every builder report must show.
- `roles.reviewer-pass-one`, `roles.reviewer`: optional per-call `model`
  and `effort` (`get roles --format json`); pass each only when set.

## The steps
### 1. The review branch and its worktree
Before the first edit, resolve the config once and write the values into
the session's record; every later Bash call sets them again by hand,
because shell state does not survive between calls:
```bash
CFG="${CLAUDE_PLUGIN_ROOT}/scripts/studio_config.py"; REPO=$(git rev-parse --show-toplevel) &&
WR=$(python3 "$CFG" get core.worktree_root) && WR=${WR:-$(dirname "$REPO")/$(basename "$REPO")-review} &&
case "$WR" in /*) ;; *) WR="$REPO/$WR" ;; esac &&
echo "REPO=$REPO MAIN=$(python3 "$CFG" get core.main_branch) REMOTE=$(python3 "$CFG" get core.remote) PREFIX=$(python3 "$CFG" get core.review.branch_prefix) WR=$WR DATE=$(date +%F)"
```
```bash
REPO=<abs>; MAIN=<main>; REMOTE=<remote>; T=<PREFIX><DATE>-<task>; W=<WR>/<task>; : "${REPO:?}" "${MAIN:?}" "${REMOTE:?}" "${T:?}" "${W:?}"
git -C "$REPO" fetch "$REMOTE" && git -C "$REPO" worktree add -b "$T" "$W" "$REMOTE/$MAIN"
```
Builders work in `$W`, given its absolute path (skill `plan-then-build`);
never Agent-tool `isolation`. Other starts (a change begun in the shared
tree, resuming, a rename, a revert, no Agent tool): `reference/branch-recipes.md`.

**Commit by path and push, then fix the SHAs:**
```bash
REPO=...; MAIN=...; REMOTE=...; T=...; W=...; : "${T:?}" "${W:?}" "${MAIN:?}" "${REMOTE:?}"
git -C "$W" add -- <path1> <path2> && git -C "$W" commit -m "<message>" -- <path1> <path2> &&
git -C "$W" push -u "$REMOTE" "$T" && git -C "$W" fetch "$REMOTE" &&
echo "BASE=$(git -C "$W" merge-base "$REMOTE/$MAIN" "$T") HEAD=$(git -C "$W" rev-parse "$T")"
```
Paths go on the commit too, so nothing else staged rides along. Never
`git add -A`. Write `BASE` and `HEAD` into the record: reviewers read these
fixed SHAs, never a moving ref. Under `plan-then-build` this runs after
every step, before its check.

### 2. Check the builder reports (orchestrator)
Before any pass, read each builder report: every `core.ci_commands` entry
named, run, and green, with test counts. A command missing, unrun or red
goes back to a fresh builder. The pass-one reviewer sees no builder report.

### 3. Pass one: `studio-core:reviewer-pass-one` (skip when `passes` is 1)
```
Agent { subagent_type: "studio-core:reviewer-pass-one", run_in_background: false,
        description: "Pass one <task>",
        prompt: <branch, BASE..HEAD, the paths, the checklist below,
                 "What to look for" from reviewer-prompt.md> }
```
Checklist: (1) secrets grep on the diff; (2) blast radius and privacy;
(3) every `ci_command` ran, green, plus a test for any bug fixed; (4) a new
dependency, permission or cost recorded; (5) a reworded rule grepped across
the tree. In full: `reference/pass-one.md`. A fresh `studio-core:builder`
fixes what it finds; commit, push, take the new `HEAD`.

**Docs-only path:** when `core.review.docs_only` is true and
`python3 ${CLAUDE_PLUGIN_ROOT}/scripts/review_path.py --repo "$W" <BASE> <HEAD>`
prints `docs-only`, you do pass one by reading, fix findings yourself, and
land with the docs-only trailer: `reference/docs-only-path.md`.

### 4. Pass two: one fresh `studio-core:reviewer`
A **new** agent: never the builder, never a resumed agent, never yourself.
One per change, when the branch is whole, never one per plan step.
```
Agent { subagent_type: "studio-core:reviewer", run_in_background: false,
        description: "Review <task> before main",
        prompt: <reviewer-prompt.md with every placeholder filled> }
```
It runs the ride-along `git diff --stat` first (an unlisted reviewed path
in the stat is a **blocker**) and reads any merge in range with
`git show --remerge-diff`.

### 5. Fix what it finds (no second round)
Blockers and majors: fixed on the branch, each with a test that fails
without the fix; rebut one only with evidence (a command and its output).
**One you can neither fix nor disprove, or one needing a redesign, keeps
the branch off the main branch.** Minors: fixed if small, else a task.
No second reviewer reads the fixes; the landing names them. Record the
reviewed `HEAD` and the fix tip `FIX`. In full: `reference/fixing-findings.md`.

### 6. Land
`TIP` is `FIX`, or `HEAD` when nothing was fixed. Never rebase a reviewed
branch, never land from the shared tree, never `-X ours` or `-X theirs`.
```bash
REPO=...; MAIN=...; REMOTE=...; T=...; W=...; BASE=<sha>; HEAD=<reviewed sha>; TIP=<FIX or HEAD>; : "${T:?}" "${W:?}" "${BASE:?}" "${HEAD:?}" "${TIP:?}"
test "$(git -C "$W" rev-parse "$T")" = "$(git -C "$W" rev-parse "$TIP")" &&
git -C "$W" fetch "$REMOTE" && git -C "$W" checkout --detach "$REMOTE/$MAIN" &&
git -C "$W" merge --no-ff "$T" -m "merge $T: <what>" \
  -m "Reviewed-by: fresh reviewer agent, ${BASE:0:7}..${HEAD:0:7}, 1 round (<b> blocker, <m> major, <k> minor; <f> fixed, <q> queued)" \
  -m "Fixed-after-review: author, ${HEAD:0:7}..${TIP:0:7}, <n> fixes (<which findings>)" &&
git -C "$W" push "$REMOTE" HEAD:"$MAIN"
# Nothing fixed (TIP is HEAD): leave out the Fixed-after-review -m line.
```
With `land` set to `pr`: push the branch and open a pull request whose body
carries the same two trailer lines. Conflicts, a rejected push, the `pr`
recipe, cleanup and the CI read: `reference/landing-and-cleanup.md`.

### 7. Clean up and record
Ancestor check, `git worktree remove`, branch deleted on both sides
(`reference/landing-and-cleanup.md`). Record the branch, `BASE`, `HEAD`,
`FIX`, every finding and what was done with it, and the landing.

## Guard and audit
Before any push to the main branch from the shared tree:
`${CLAUDE_PLUGIN_ROOT}/scripts/review_guard.sh push`; anything but exit 0
means push nothing. Regularly:
`${CLAUDE_PLUGIN_ROOT}/scripts/review_guard.sh audit <FROM>`; each gap is a
top task. Forgotten worktrees: `${CLAUDE_PLUGIN_ROOT}/scripts/worktree_sweep.sh`.
In full: `reference/guard-and-audit.md`.

Each `reference/` file is named in the step that needs it; `why.md` holds
the reasons.
