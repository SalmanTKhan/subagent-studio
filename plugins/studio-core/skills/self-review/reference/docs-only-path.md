# The docs-only path

A lighter review for a change that is text only but still touches a reviewed
path (a skill's prose, a process file). Used only when `core.review.docs_only`
is true; when it is false, every change takes the full steps.

## Deciding
Once the branch is committed, run the script on the range in `$W`,
naming the worktree with `--repo` instead of changing into it:
```bash
python3 <plugin root>/scripts/review_path.py --repo "$W" <BASE> <HEAD>
```
`<plugin root>` is the path SKILL.md showed. Never run a copy the branch
itself changed, from `$W` or by a path relative to it: the script that
decides is the one from the plugin or the main checkout.

The first line is `docs-only` or `full`. Docs-only means every changed path
is a `.md` file outside code paths, with no symlink, submodule or new
executable bit, and no `.claude/` frontmatter key changed except `name`,
`description` and `context`. So `tools`, `model`, `effort`,
`permissionMode`, `hooks` and `allowed-tools` changes make it full.

## The light path
- **Pass one** is your own reading of the diff with checklist items 1
  (secrets), 2 (blast radius, privacy), 4 (scope) and 5 (wording sweep).
  Moved text is checked to be word for word where it says it moved. No
  `reviewer-pass-one`.
- **Pass two** is the same fresh `studio-core:reviewer` as the full path.
- **Fixes:** you fix its findings yourself, text only, no builder, each
  re-read against its failure scenario.
- **Before landing, run the script again on `<BASE> <TIP>`.** On `full` the
  landing waits, because no pass one can follow a fresh review: the fixes go
  to a new branch with its own review, or are reverted.

## The landing line
```
Reviewed-by: fresh reviewer agent, <BASE7>..<HEAD7>, 1 round, docs-only path (<b> blocker, <m> major, <k> minor; <f> fixed, <q> queued)
```
Plus the `Fixed-after-review:` line when anything was fixed. On `full`, or in
doubt, take the steps as written.
