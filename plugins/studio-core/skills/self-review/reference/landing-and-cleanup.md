# Landing, every conflict case, pull requests, cleanup and the CI read

## Why a `--no-ff` merge
The reviewed commits and the author's fixes land as they are, under a
`--no-ff` merge whose message carries the trailers. So the SHAs the reviewer
read, and the fixes after it, stay on the main branch, and
`review_guard.sh audit` can check them. With fixes, `TIP` is `FIX` and the
`Fixed-after-review:` line goes in; without, `TIP` is `HEAD` and the line is
left out.

- **Never rebase a reviewed branch** to land it: that makes new, unread SHAs.
- **Never land from the shared tree:** a later `git pull --rebase` there would
  flatten the merge.
- **Never `-X ours` or `-X theirs`.**

## Before the push
When the main branch moved since `BASE` in a reviewed path, run every
`core.ci_commands` entry in `$W` on the merge before the push, chained so a
red command stops it.

## Conflicts
- **Only in paths outside `core.review.reviewed_paths`** (notes, queue,
  docs): resolve inside the landing merge, keeping both sides' facts,
  `git -C "$W" add -- <those paths>`, then commit and push as one chain:
  `git -C "$W" commit --no-edit && git -C "$W" push "$REMOTE" HEAD:"$MAIN"`.
  The trailers stay; the audit accepts a docs-only resolution.
- **In a reviewed path:** `git -C "$W" merge --abort`, then on the branch
  `git -C "$W" checkout "$T" && git -C "$W" merge "$REMOTE/$MAIN"`, resolve,
  commit, push the branch, read that merge yourself with
  `git show --remerge-diff <merge>`, and land with the merge as `TIP` on the
  `Fixed-after-review:` line. The landing then merges clean. Never
  `git show --cc` for this: it prints nothing for a file taken whole from one
  side.
- **Never resolve a reviewed path inside the landing merge.** The audit merges
  the landing's two parents again with `git merge-tree`: a conflict in a
  reviewed path is a gap however it was resolved, and so is any reviewed path
  that differs from that clean merge.
- **Push rejected** (the main branch moved): fetch and repeat the landing
  block from `checkout --detach`. Never `pull --rebase` a merge.

## `core.review.land` set to `pr`
The branch is already pushed. Open a pull request whose body carries the same
trailer lines the merge message would:
```bash
gh pr create --base "$MAIN" --head "$T" --title "<what>" --body "$(printf '%s\n\n%s\n%s\n' '<summary>' 'Reviewed-by: fresh reviewer agent, <BASE7>..<HEAD7>, 1 round (<counts>)' 'Fixed-after-review: author, <HEAD7>..<TIP7>, <n> fixes (<which>)')"
```
Leave out the `Fixed-after-review:` line when nothing was fixed. Without
`gh`, push the branch and give the user the compare URL and the body text.
The pull request is merged with a **merge commit** (never squash, never
rebase), and the merge commit's message must keep both trailer lines, or the
audit names the landing as a gap. Clean up only after it has merged.

## Clean up
```bash
REPO=...; MAIN=...; REMOTE=...; T=...; W=...; : "${REPO:?}" "${T:?}" "${W:?}"
git -C "$W" fetch "$REMOTE" && git -C "$W" merge-base --is-ancestor "$T" "$REMOTE/$MAIN" &&
test -z "$(git -C "$W" status --porcelain --untracked-files=no)" &&
{ git -C "$REPO" worktree unlock "$W" 2>/dev/null; true; } &&
git -C "$REPO" worktree remove --force "$W" &&
git -C "$REPO" push "$REMOTE" --delete "$T" && git -C "$REPO" branch -D "$T" &&
git -C "$REPO" pull --rebase --autostash "$REMOTE" "$MAIN"
```
The ancestor check comes first, so a branch that has not reached the main
branch is never deleted. Remove any symlink you made inside `$W` (for
example a linked dependency directory) before `--force`, so removal never
walks into another tree. `--autostash` keeps another session's uncommitted
work in the shared tree; if its re-apply conflicts, stop and leave the stash
for that session. The last line assumes the shared tree is on the main
branch; skip it otherwise.

## The sweep
A worktree whose cleanup was missed (a session died, a block failed) is
removed by `worktree_sweep.sh --remove` once it is fully on the main branch,
clean, idle, unlocked and unused; without `--remove` it is a dry run. Lock a
worktree you will leave idle without landing it:
`git -C "$REPO" worktree lock --reason "<task>" "$W"`; the cleanup unlocks it.
An ignored file the sweep will not remove (neither rebuilt output nor a copy
of the shared tree's) needs a home first: commit it through a review branch,
keep it outside the repo, or delete it.

## Read CI
A landing that touches a path CI runs on starts a run on the main branch.
Read it once, a few minutes after the push, and check its newest line
carries the landed SHA. A red run is the next task before anything else, a
deploy included, and is fixed forward on a new review branch. A cancelled
run counts as red, unless a later push superseded it; then read the newer
run. A landing that touches no CI path starts no run and leaves nothing to
read.
