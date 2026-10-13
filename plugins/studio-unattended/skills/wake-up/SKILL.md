---
name: wake-up
description: The procedure of one scheduled, unattended run. Take the lock, orient from the repo's files, pick tasks with the usage guard first, work them through studio-core's plan-then-build and self-review, close each one out, release the lock and send one short summary. Use it as the whole body of a scheduled wake-up prompt.
---
# Wake-up

One scheduled run: lock, orient, pick, work, close, then pick again while
the budget lasts. Follow the steps in order. Do not skip one.

**Scripts.** Write them as `${CLAUDE_PLUGIN_ROOT}/scripts/<name>`. If your
Bash cannot see `CLAUDE_PLUGIN_ROOT`, the plugin root is two levels above
this skill's base directory.

**Config.** `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/studio_config.py get <key>`.
The file names below are the defaults of `unattended.files`
(`--format json` prints them all): `STATE.md`, `TASKS.md`,
`TASKS-DONE.md`, `tasks/`, `journal/`, `DECISIONS.md`, `plans/`. Use the
configured names wherever this skill says the default.

## 0. Ground rules
- **The repo is the memory.** Anything not committed and pushed did not
  happen. Every Bash call is a new shell, so state lives in files.
- **You orchestrate; fresh agents do the hands-on work.** You never edit
  code, run a test suite, read a diff or deploy. Each hands-on step is a
  fresh agent with a written brief and a report under 400 words
  (`studio-core:builder`, `studio-core:reviewer` and the rest). You pick,
  brief, read reports, decide, run the git commands and keep the queue,
  the state file and the journal. Read `git diff --stat`, never the diff.
  An agent is never continued across steps or tasks.
- **Your context is the largest cost of a run.** Read line ranges
  (`sed -n`, `grep -n`), never whole files; `tail` every output; send long
  output to a file and read its summary.
- **Only three things go to a human:** money, the human's own login or
  signature, and a stop. Everything else you decide and do, then record.
  When one of the three applies, send a `NEEDS HUMAN` ask (skill
  `notify`), mark the task `blocked-human` and move on.
- **Never idle.** A task blocked on a human never blocks a different task.
- Skills hold how-to knowledge. Check them before working something out;
  write one the second time you do anything.

## 1. Orient (read only)
1. Keep the start time from `date`. Then
   `${CLAUDE_PLUGIN_ROOT}/scripts/wake_lock.sh remove --stale` and
   `${CLAUDE_PLUGIN_ROOT}/scripts/wake_lock.sh check`. Exit 4 means another
   run is at work: exit now with no changes and no pull. Exit 0 goes on.
   If your project has a run that only holds the queue (optional, see
   `reference/optional-steps.md`), check with `--holder-class <prefix>`;
   exit 3 means that run is at work and you build but hold queue edits.
2. `git pull --rebase` from the main branch (`core.main_branch`,
   `core.remote`). If it fails, fix it or notify and stop.
3. Read the state file: where the project is, what is in build, open
   review branches, what waits on a human, and "Last run", the last run's
   close paragraph.
4. Read the task index (`TASKS.md`) whole; it is short by design. Open a
   task file only when you pick or edit that task. Read only the tail of
   done: `tail -20 TASKS-DONE.md`.
5. The journal is looked up, never read whole:
   `grep -n 'T-12' journal/*.md` for a task's history, or one entry by its
   heading (`grep -n '^## Run' journal/<date>.md`, then `sed -n`).
6. `git branch -r --list '<remote>/<core.review.branch_prefix>*'`: each open
   review branch is code waiting for its fresh review
   (`studio-core:self-review`), and its task comes before new build work.
7. If a notifier is set up and a task is `blocked-human` with a thread
   link, read that thread now (`reference/optional-steps.md`). A reply
   from the human is an instruction: apply it, update the task, continue.
8. If the permission gate is on, read its denials since the last run:
   `grep -E '"deny"|alarm' ~/.claude/plugins/data/studio-unattended*/permission-gate.log | tail`
   (copy-in installs: `~/.config/subagent-studio/`). A denial that
   blocked needed work becomes a task.

## 2. Pick the next task
Usage guard first, here and each time step 4.8 sends you back (skill
`usage-guard`). When it trips, pick nothing but one urgent P0.

Then follow skill `task-queue` "Pick": the top-most task with owner
`claude` and status `todo` or `doing`, P0 then P1 then P2, top to bottom.
Skip `blocked-*` and any task whose `depends:` ids are not all in done. If
nothing is unblocked: one journal line saying so, the state file's
"Waiting on human", the step 4.7 summary if this run finished anything,
then exit. Do not invent work.

`${CLAUDE_PLUGIN_ROOT}/scripts/wake_lock.sh add wake-up` (a fixed id,
never a task id, which changes during a run). Set the task `doing` at once
so two runs never pick it.

## 3. Work
- **Budget:** `unattended.run_minutes` (default 90) and
  `unattended.max_tasks_per_run` (default 4). Finish a task, close it out
  fully (step 4), then go back to step 2, until the minutes are spent, the
  task count is reached or the turn limit is near.
- **Split first.** A task too big for one run is split into 2 to 5
  sub-tasks before work starts (skill `task-queue`), so every run finishes
  something and a hard stop loses nothing. A task still `doing` after three
  runs is split or becomes a question.
- **Big work starts with a plan:** a new feature, a hard-to-reverse
  change or a deep research goes through `studio-core:plan-then-build`
  (its §1 says what counts as big and which planner plans it). Small tasks
  (a fix, strings, one route, a doc) are one fresh builder with the whole
  task as its brief.
- **Every change to code, config, prompts or process files** goes through
  `studio-core:self-review`: a review branch, the author's pass, then a
  fresh reviewer on fixed SHAs, the findings fixed, then the landing.
- A decision that changes what the project does gets an entry in the
  decisions file. Never lower a gate or a target to make progress look
  real.

## 4. Close (always, even after a failure)
1. **Queue** (skill `task-queue`): update statuses on the index lines.
   Close finished tasks (the line to done with the landing SHA, the file
   to `tasks/done/`). Add every new task you found: an index line and its
   file in the same edit.
2. **State file:** rewrite the parts that changed and replace "Last run"
   with this run's close paragraph, the same text the journal gets. Keep it
   under its budget (studio-context's `context_budget.py`, when installed,
   must exit 0); when over, move detail out, never delete a fact.
3. **Journal:** append a run entry (skill `journal`) ending in that close
   paragraph. Include what the next run needs: URLs, ids, gotchas, dead
   ends.
4. **Skills:** something repeatable gets a skill now, on its own review
   branch, never in this close-out commit.
5. `${CLAUDE_PLUGIN_ROOT}/scripts/wake_lock.sh remove wake-up` (only your
   own line).
6. **Commit and push.** Add your own paths by name, never `git add -A`.
   Before any push to the main branch, studio-core's
   `review_guard.sh push` must exit 0 (`studio-core:self-review` gives its
   path). Code still under review stays on its pushed review branch, named
   in the journal and on its task. If the push fails, retry once, then
   notify. Never leave work uncommitted.
7. **One summary** at whatever exit ends the run, three lines or fewer:
   `${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh ops "<text>"` (skill
   `notify`), only when a task finished, landed or deployed. None per
   task. Plain words for a person: no task ids, no file names.
8. Time and task count left? Go back to step 2. Otherwise exit.

## Optional steps
`reference/optional-steps.md`: polling a human channel, standing in for
another scheduled job that missed its slot, and sharing the lock with a
run that only holds the queue.
