# studio-core

The build loop: lean agent types, plan-then-build, the two-pass review and
the guard that enforces it. Every other plugin builds on it. Depends on
nothing.

## What it adds

**Agents** (`plugins/studio-core/agents/`, generated from `shared/agents/`):

| Agent | Model, effort | Tools | Job |
|---|---|---|---|
| `studio-core:builder` | opus, medium | Bash, Read, Edit, Write, Grep, Glob, WebFetch, WebSearch | builds one step in the worktree it is given, runs the CI commands, reports; never commits |
| `studio-core:builder-sonnet` | sonnet, high | same as builder | same body; only for fully specified, mechanical steps |
| `studio-core:reviewer` | opus, high | Bash, Read, Grep, Glob, WebFetch | the fresh second pass, and step checks; read-only, fixed SHAs |
| `studio-core:reviewer-pass-one` | opus, high | same as reviewer | same body; the author's pass one |
| `studio-core:planner` | opus, high | Bash, Read, Grep, Glob, WebFetch, WebSearch | read-only; returns a plan for a big feature, re-plan or amendment |
| `studio-core:planner-max` | opus, high | same as planner | same body; work that is hard to reverse, or complex and critical |
| `studio-core:searcher` | haiku, high | Bash, Read, Grep, Glob | lookups, reported as `path:line` with quotes; never judges |

**Skills:**
- `plan-then-build`: what counts as big, which planner, the plan shape, the
  builder brief, the four conditions for `builder-sonnet`, checking a step
  with a fresh reviewer, re-plans, the `## Outcome` section.
- `self-review`: the review branch in its own worktree, fixed `BASE..HEAD`,
  pass one, one fresh reviewer, severities, fixes with tests, the `--no-ff`
  landing or a pull request, cleanup, the docs-only path. The reviewer's
  prompt is `self-review/reviewer-prompt.md`.
- `orchestrator-rules`: what the main session does and never does, and the
  table of which agent type does which work.
- `studio-init`: writes `.claude/studio.json` and the `CLAUDE.md` block. Run
  by hand only (`disable-model-invocation`).
- `effort-low`, `effort-medium`, `effort-high`, `effort-xhigh`: set the
  session's effort level from a scheduled prompt.

**Scripts** (`${CLAUDE_PLUGIN_ROOT}/scripts/`, or `scripts/studio/` in a
copy-in install, where the installed skills call the main checkout's copy
by an absolute path, never one relative to a review worktree):
- `review_guard.sh push [--source REV] | audit FROM | move BRANCH`: the
  guard, the audit, and moving unreviewed local commits off main onto a
  review branch. `push` walks the first-parent commits the remote main
  lacks, up to the local main or, with `--source`, up to REV (what a push of
  REV to main brings). Each that touches a reviewed path fails, unless it is
  a landing merge that passes the same checks as the audit (its
  `Reviewed-by:` range, and `Fixed-after-review:` range if any, end at what
  it lands, and it brings nothing else into a reviewed path).
  Exit 0 clean, 1 findings, 2 usage or git error (it fails closed). It
  reads its config from the remote main's committed `.claude/studio.json`,
  never the working tree's, and always treats that file as reviewed, so an
  unreviewed local commit cannot switch it off. Until the remote main has
  that file, the reviewed paths are the defaults and the working tree's
  `core.main_branch`, `core.remote` and branch prefix say where to look, so
  a repo whose main branch is `master` can land its first config.
- `review_path.py [--repo DIR] BASE HEAD`: prints `docs-only` or `full` for
  a range, read in DIR (a review worktree) or the current directory.
- `worktree_sweep.sh [--remove]`: removes review worktrees that are fully on
  main, clean, idle, unlocked and unused. A dry run without `--remove`.
  `SWEEP_IDLE_MINUTES` (default 360) sets the idle time.
- `push_guard_hook.py`: the hook below.
- `studio_config.py get <key> | validate [--file PATH]`: the config loader
  every plugin carries a copy of. `--file` reads a given copy (`-` for
  stdin) instead of the project's.

**Hook** (`hooks/hooks.json`): a `PreToolUse` hook on Bash. When
`core.review.push_hook` is true, it reads each `git push` in the command
that could update the main branch and denies the push when the guard fails:
- When the refspec names its source (`SRC:main`, `SRC:refs/heads/main`,
  `main`, or `HEAD` or no refspec while main is checked out), it runs
  `review_guard.sh push --source SRC`, with SRC resolved where the push
  runs (its `-C` directory, else the session's directory). So
  `git push origin review/x:main` is checked as review/x, and the landing
  push `git -C "$W" push "$REMOTE" HEAD:"$MAIN"` as the landing merge in
  `$W`. A variable set once to a literal earlier in the same command (as
  the recipes do) is read; one set twice, or never, is not.
- When it cannot name the source (after a `cd`, a `$` or backtick left in
  the push, `--git-dir` or `--work-tree`, a wildcard refspec, a source that
  does not resolve, or git run by `bash -c`, `sh -c`, `eval`, `sudo`, `env`,
  `xargs` and the like), it checks both: `review_guard.sh push` (the local
  main) from the project root, and `--source HEAD` in each directory the
  push might run in (the session's, and any literal `cd` target).
- `--all`, `--mirror` and `--branches` are checked as the local main.

Only the string a shell runs (`bash -c`, `sh -c`, `zsh -c`, `eval`) and a
command substitution are read as commands, so `grep -rn "git push" .` runs
no guard. When the flag is false it exits at once. It fails open on its own
errors; the guard it runs fails closed. A copy-in install writes each hook
command so that a missing script exits 0 instead of blocking every call.

## Config keys

All under `core` in `.claude/studio.json`, except `roles`.

| Key | Default | Read by | Meaning |
|---|---|---|---|
| `core.main_branch` | `main` | guard, sweep, hook, skills | the branch reviewed work lands on |
| `core.remote` | `origin` | guard, sweep, skills | the remote pushed to |
| `core.worktree_root` | `""` (means `../<repo>-review`) | `self-review`, sweep | where review worktrees live; relative paths are from the repo root |
| `core.ci_commands` | `[]` | `plan-then-build`, `self-review`, agents' briefs | commands every builder runs and every reviewer checks |
| `core.plan.big_also` | `[]` | `plan-then-build` | extra criteria that make a task big enough to plan |
| `core.review.passes` | `2` | `self-review` | `2`: pass one, then a fresh reviewer; `1`: the fresh reviewer only |
| `core.review.reviewed_paths` | `src`, `lib`, `app`, `apps`, `packages`, `scripts`, `.github`, `.claude`, `CLAUDE.md` | guard, `review_path.py`, `self-review` | paths whose changes must land through review |
| `core.review.docs_only` | `true` | `self-review` | a change touching no reviewed path lands without a review branch, and text-only changes may take the docs-only path |
| `core.review.land` | `merge-no-ff` | `self-review` | `merge-no-ff` or `pr` |
| `core.review.push_hook` | `false` | hook | turn the push hook on |
| `core.review.branch_prefix` | `review/` | guard, `self-review` | prefix of review branches |
| `roles.<role>.model`, `roles.<role>.effort` | unset | `plan-then-build`, `self-review`, `orchestrator-rules` | per-call overrides; unset means the agent file decides |

`review_guard.sh` also takes `STUDIO_REVIEWED_PATHS`, `STUDIO_MAIN_BRANCH`
and `STUDIO_REMOTE` from the environment, for tests.

## What it changes in your repo

- `studio-init` writes `.claude/studio.json` and adds a block between
  `<!-- subagent-studio:begin -->` and `<!-- subagent-studio:end -->` in
  `CLAUDE.md`. Nothing else in `CLAUDE.md` is touched.
- Planned work writes `plans/<slug>.md`, one file per plan.
- Each change gets a branch `review/<date>-<task>` pushed to the remote and
  a worktree under the worktree root; both are removed after the landing.
- Landings are `--no-ff` merge commits on main with the trailers, or pull
  requests when `land` is `pr`.
- A copy-in install also puts the agents and skills in `.claude/`, the
  scripts in `scripts/studio/` and the hook in `.claude/settings.json`.
