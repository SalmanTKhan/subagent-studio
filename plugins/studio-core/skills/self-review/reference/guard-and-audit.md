# The guard, the push hook and the audit

`<plugin root>` below is the path SKILL.md showed for
`${CLAUDE_PLUGIN_ROOT}`; a copy-in install uses `scripts/studio/`.

## Pushing to the main branch from the shared tree
Before any push to the main branch, run from the repo:
```bash
<plugin root>/scripts/review_guard.sh push
```
It reads `core.review.reviewed_paths` and the branch prefix from the remote
main's committed `.claude/studio.json`, never the working tree's, so an
unreviewed local commit that narrows the list cannot switch the guard off;
`.claude/studio.json` itself is always a reviewed path. The working tree's
`core.main_branch` and `core.remote` only say what to fetch, and a mismatch
with the remote main's copy is exit 2. Until the remote main has that file,
the reviewed paths are the defaults and the working tree's names are used,
so the push that lands the first config is not blocked. The audit reads the
same remote copy. It checks the local main ref, not `HEAD`, so it gives the
same answer from any worktree; `push --source REV` checks what a push of REV
to main would bring instead, and passes a landing merge the audit would
pass. Anything but exit 0 means push nothing:
- **exit 1:** a local commit on the main branch that the remote lacks
  touches a reviewed path. Move the commits to a review branch
  (`review_guard.sh move <branch>`, or the "Move a change out of the shared
  tree" recipe) and take them through review.
- **exit 2:** git or config trouble (the fetch failed, no main branch, git
  could not list the local commits or their paths, a config that cannot be
  read). Record it.

## The push hook
With `core.review.push_hook` true, the plugin's `PreToolUse` hook on Bash
(`push_guard_hook.py`) catches a `git push` to the main branch and runs the
guard first, refusing the push when the guard fails. It checks what the push
sends: `git push origin review/x:main` is checked as review/x, and the
landing push from `$W` as the landing merge there (`--source`). When it
cannot name what is sent (after a `cd`, a `$` or backtick it cannot read,
`--git-dir` or `--work-tree`, or git run by `bash -c`, `eval`, `sudo`,
`env`, `xargs` and the like) it checks both the local main and `HEAD`: a
false alarm costs a fetch. A `grep` for "git push" runs nothing. It
enforces the rule in
the harness instead of trusting the prompt alone. With the flag false the
hook does nothing; run the guard by hand.

## Deploys
Deploy production only from a reviewed main branch with a clean tree and the
guard passing. No builder, reviewer or review worktree deploys production.
The deploy script, if the project has one, should refuse otherwise and read
CI for the commit before it builds.

## Detecting a bypass: the audit
```bash
<plugin root>/scripts/review_guard.sh audit <FROM>
```
Run it regularly (daily for an unattended project). `<FROM>` is the SHA the
previous audit ended at (its last line says "audited through <sha>"); keep
it in a record file. It audits by commit graph, not by date, so a skipped
day or an old commit date leaves no hole. The first audit starts at the
first parent of the landing that introduced this rule; older commits predate
it.

Every commit on the main branch's first-parent line after `FROM` that
touches a reviewed path must be a landing merge whose `Reviewed-by:` range,
and its `Fixed-after-review:` range when it has one, covers what it brought
in. Each gap line is a top-priority task: review that commit now, fix what
the review finds, and record how it got through. Each open review branch on
the remote older than a day is a task too.
