# Branch recipes

Every recipe starts with its variables set by hand and checked, because each
Bash call is a new shell. Write `T` (the branch) and `W` (the worktree path)
into the record the moment you choose them. Chain steps with `&&` so a failed
step stops the rest.

```bash
REPO=/abs/path/repo; MAIN=main; REMOTE=origin; T=review/2026-01-31-t-12; W=/abs/path/repo-review/t-12; : "${REPO:?}" "${MAIN:?}" "${REMOTE:?}" "${T:?}" "${W:?}"
```

**Never put several paths in one variable.** In zsh, and in bash when quoted,
a variable holding several paths is one word. A guard once took such a
variable as a single path, matched nothing, and let an unreviewed change
reach the main branch; the guard now fails closed. Write paths out on the
command line.

## Move a change out of the shared tree
It was started there by mistake:
```bash
cd "$REPO" && git fetch "$REMOTE" &&
git stash push -u -m "$T" -- <path1> <path2> &&
S=$(git stash list --format='%H %gs' | awk -v t="$T" 'index($0, t) {print $1; exit}') && : "${S:?no stash made}" &&
git worktree add -b "$T" "$W" "$REMOTE/$MAIN" &&
git -C "$W" stash apply "$S"
```
`-u` takes new files too; the paths are written out. Stop at the first
failure. Resolve a conflict on `stash apply` inside `$W`, never in the shared
tree. Drop the stash only after the branch is pushed:
`git stash drop "$(git stash list --format='%gd %H' | awk -v h="$S" '$2 == h {print $1}')"`.
Never a bare `git stash pop`: it takes whatever stash is on top, which may be
another session's.

## Resume a branch that exists on the remote
```bash
cd "$REPO" && git worktree prune && git fetch "$REMOTE" &&
{ [ -d "$W" ] || git worktree add "$W" "$T"; } &&
git -C "$W" status --short && git -C "$W" log --oneline -1 && git rev-parse "$REMOTE/$T"
```
`git worktree add "$W" "$T"` makes a local tracking branch when there is
none. The worktree's `HEAD` must equal `$REMOTE/$T`; if not, stop and find
out why before touching it.

## A rename or deletion
The old path goes on the commit only, never on the `git add`, because
`git add -- a` fails once `git mv` or `git rm` has staged the removal:
```bash
git -C "$W" mv a b && git -C "$W" add -- b && git -C "$W" commit -m "<message>" -- a b
```

## Split out a blocked commit
`git revert` it on the branch, never `git reset` in a tree someone else may
use. The revert lands as a fix after review.

## Where worktrees live
Under `core.worktree_root` (empty means `../<repo>-review`). Never a system
temp directory that the OS may clear. Never the Agent tool's
`isolation: "worktree"`, which makes a separate throwaway tree on another
branch. Builders get `$W`'s absolute path in their brief.

## When there is no Agent tool
The session brings no code to the main branch. It commits the change on a
review branch in its own worktree and pushes the branch, or, if it cannot,
stashes it with `git stash push -u -m "unreviewed <task>" -- <paths>`. It
writes the branch or the stash hash and the reason into the record and the
queue, and the next session with the Agent tool reviews it.
