# Adopting the kit in an existing project

This walks through putting the kit into a project that already has code, a
remote and some kind of CI. Take it in order; each step is small.

## 1. Pick modules

- **`studio-core`** is the one you need: the agent types, plan-then-build,
  the review and the guard. Start with it alone.
- **`studio-context`** when `CLAUDE.md` or your skills are growing, or you
  want to see tokens per run type. It stands alone and can come later.
- **`studio-unattended`** when you want scheduled runs that pick tasks from
  a queue with nobody watching. Needs `studio-core`.
- **`studio-research`** when you research before you build (a library, a
  vendor, a market) and want every figure sourced and re-checked. Needs
  `studio-core`.

Install as plugins:

```
/plugin marketplace add priyanshujha/subagent-studio
/plugin install studio-core@subagent-studio
```

or copy in:

```bash
./install.sh --modules core --target /path/to/project --dry-run   # see what it would write
./install.sh --modules core --target /path/to/project
```

In a copy-in install the agent names lose their prefix (`studio-core:builder`
becomes `builder`) and script paths become `scripts/studio/<name>`.

## 2. Run `studio-init`

```
/studio-core:studio-init
```

(In a copy-in install, ask for the `studio-init` skill.) It reads the
project, proposes values, asks, and only then writes `.claude/studio.json`
and a marked block in `CLAUDE.md`. Run it again later to change the answers;
it keeps keys you set by hand. The next four sections are the choices it
asks about.

## 3. Choose the CI commands

`core.ci_commands` is the list every builder runs and reports on, and every
reviewer checks. `studio-init` proposes them from `package.json`,
`pyproject.toml`, a `Makefile`, `go.mod`, `Cargo.toml` or your CI workflow.

- List what your CI actually runs, in the order it runs them: lint,
  typecheck, tests, build. A check that only CI runs is a check that will
  go red on main after a landing.
- Keep each command runnable from the repo root with no setup a fresh
  agent would not know about. If tests need a database, make the command
  start it or say so in `CLAUDE.md`.
- An empty list is allowed, but then builders have nothing to prove a step
  with but the step's own acceptance line.

## 4. Choose the reviewed paths

`core.review.reviewed_paths` decides what must go through review. Anything
outside them counts as plain docs and, with `core.review.docs_only` true
(the default), can land on main directly.

- Include every directory with code, plus what changes how the code builds
  or runs: `.github`, `.claude`, `CLAUDE.md`, the package manifest and
  lockfile, `Dockerfile`, `Makefile`.
- Leave out notes, plans, the journal and the task queue, so the session can
  keep its records without a review branch per line.
- When unsure about a path, include it. A reviewed path costs a review; an
  unreviewed one is where an unread change lands.

The defaults (`src`, `lib`, `app`, `apps`, `packages`, `scripts`, `.github`,
`.claude`, `CLAUDE.md`) are a starting point, not a guess about your repo.

## 5. One pass or two, and how to land

**Passes** (`core.review.passes`). Two is the default: the author's
checklist through `reviewer-pass-one`, then a fresh `reviewer`. One skips
the checklist pass. Two catches the cheap things (a secret in the diff, a
CI command nobody ran) before the expensive reviewer reads the change.
Choose one when cost matters more and your CI already gates most of what
the checklist covers.

**Landing** (`core.review.land`).
- `merge-no-ff` (default): the session lands reviewed work on main itself,
  with a `--no-ff` merge carrying the trailers. Suits a solo developer.
- `pr`: the session pushes the branch and opens a pull request whose body
  carries the trailers. A human merges it, with a merge commit (never
  squash, never rebase) whose message keeps both trailer lines; otherwise
  the audit reports that landing as a gap.

## 6. Try one small task

Give the session a small, real change, for example a bug fix with a test.
It should skip planning, cut a review branch in a worktree under
`../<repo>-review/`, launch one builder, then pass one, then a fresh
reviewer, then land. Check afterwards:

```bash
git log -1 --format=%B origin/main        # the Reviewed-by line is there
<plugin root>/scripts/review_guard.sh audit <the commit before the landing>
git worktree list                          # the review worktree is gone
```

If the session edited code itself or read the whole diff, point it at skill
`orchestrator-rules`, or say in `CLAUDE.md` that it applies to every session.

## 7. Try one planned task

Then something that spans a few files, and ask for it with
`studio-core:plan-then-build`. Read the saved plan in `plans/` before the
first builder starts. You are checking three things: the steps have
acceptance lines a command can prove, the right planner was picked, and the
step checks come back with figures and not just "looks good".

## 8. Turn on the push hook

Once the loop works, set `core.review.push_hook` to `true`. The plugin's
`PreToolUse` hook then runs `review_guard.sh push` before any `git push` the
session makes to main and denies the push when the guard fails. It acts
only on pushes that could update main, and it fails open on its own errors,
so a broken hook does not block unrelated work. In a copy-in install the
hook is in `.claude/settings.json`.

Add the audit to something regular: a scheduled run, a daily cron, or a CI
job on main. Keep the SHA each audit ended at (its last line says
`audited through <sha>`) and start the next one from it.

## 9. Add your own agent types

The kit ships the roles every build loop needs. Projects grow others; the
original project had a content writer, a designer, an incident diagnoser
for production errors and a marketing planner. Add one when the same kind
of step keeps going to a `general-purpose` agent, or keeps needing the same
long brief.

**In your project:** write `.claude/agents/<name>.md` with `name`,
`description` (when to pick it, and when not), `tools` (only what the job
uses), `model` and `effort` in the frontmatter, and a short body: what it
does, what it never does, the shape of its report. Add a line for it to the
table in `orchestrator-rules`, or to your `CLAUDE.md`.

**In a fork of the kit:** add the body as `shared/agents/<role>.body.md`,
add an entry to `shared/agents/variants.json` (`plugin`, `name`, `body`,
`description`, `model`, `effort`, `tools`), and run
`python3 tools/build_agents.py`. Two variants that share one body (a cheap
and a strong one) are two entries with the same `body`.

## 10. Override a role's model or effort

`roles.<role>` in `.claude/studio.json` sets `model` and `effort` per role.
The orchestrating skills read it and pass the values on that role's Agent
call; a key left out means the agent file's frontmatter decides.

```json
{
  "roles": {
    "reviewer-pass-one": { "effort": "medium" },
    "planner-max": { "model": "opus", "effort": "xhigh" },
    "searcher": { "model": "haiku" }
  }
}
```

Role names are the agent names without the plugin prefix. Extra names are
allowed, for your own agent types. Per-call `model` and `effort` need a
recent Claude Code (v2.1.292 or later); on older builds, edit the agent
file's frontmatter instead.

For a scheduled run's own level, start it with `--effort <level>` or call
one of the `effort-low|medium|high|xhigh` skills first in its prompt (skill
text explains the limits). `studio-context`'s `effort_check.py` shows
whether the levels held.
