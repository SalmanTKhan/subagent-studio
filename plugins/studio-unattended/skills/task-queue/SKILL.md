---
name: task-queue
description: How to read, pick from, add to, split, block and close tasks in the queue. TASKS.md is the short index every run reads whole; each task's text lives in tasks/T-nnn.md; closed tasks go to TASKS-DONE.md and tasks/done/. Use whenever the queue changes.
---
# Task queue

An open task lives in two places. The index (`TASKS.md`) is read whole by
every run, one line per task. The task file (`tasks/T-nnn.md`) is the task
itself, opened only when that task is picked or edited. Keeping the text
out of the index keeps every run's start cheap.

File names are the defaults of `unattended.files` (`tasks`, `tasks_done`,
`task_dir`); read them with
`python3 ${CLAUDE_PLUGIN_ROOT}/scripts/studio_config.py get unattended.files --format json`
and use the configured names. If your Bash cannot see
`CLAUDE_PLUGIN_ROOT`, the plugin root is two levels above this skill's
base directory.

## The index line
One line per task, never wrapped:

`- [ ] T-nnn · owner · status · P# · title — tasks/T-nnn.md — added YYYY-MM-DD[ — depends: T-x][ — plan: plans/x.md]`

- **owner:** `claude` or `human`.
- **status:** `todo`, `doing`, `blocked-human`, `blocked-external`.
  `blocked-human` carries the thread link of its ask (skill `notify`) at
  the end of the line: ` — thread: <link>`. `blocked-external` carries a
  dated note in the file of what is awaited and when to re-check.
- **P#:** P0 nothing else can proceed (and anything users are waiting on);
  P1 on the critical path to the next milestone; P2 needed but not
  blocking; anything later stays P2 at the bottom or goes into a separate
  later file of the same format.
- **title:** the head of the task's title, cut at a word boundary with `…`
  when it is long (about 55 characters keeps a big queue in budget).
- **depends:** the ids that must be closed first, on the line so a run can
  skip without opening the file.
- **plan:** the saved plan when the task is planned work.

## The task file
```
# T-nnn · title
Owner: <owner> · Status: <status> · Priority: <P#> · Added: <YYYY-MM-DD>

## Line as queued
<the index line as it stood the day it was queued>

## Acceptance
<one line: the command or check that proves it done>

## Notes
(later runs append dated notes here)
```
The line under `## Line as queued` is never edited. Everything learned
later is a dated note under `## Notes`.

## Rules
- **Pick:** the top-most task with owner `claude` and status `todo` or
  `doing`; P0 before P1 before P2, top to bottom within a priority. Skip
  `blocked-*`, and skip a task whose `depends:` ids are not all in done.
  Choose from the index lines alone; then open only the picked task's
  file. Never read `tasks/` whole.
- **Ids:** the next number above the highest id in the index and done
  together. Never reuse an id.
- **Split:** a task that cannot finish in one run is replaced, before work
  starts, by 2 to 5 sub-tasks with new ids that each can. Each gets its own
  file. The parent's file moves with the parent line, to `tasks/done/`
  when the parent closes. A task still `doing` after three runs is split
  or becomes a question.
- **Add:** anything found mid-task that is not this task. Give it a
  priority and a one-line acceptance. Do not do it now. An add is one
  index line plus its file, written in the same edit; the acceptance goes
  in the file, not the index line.
- **Depends:** a task waits until every id in its `depends:` is in done. A
  human-blocked task never blocks an unrelated one.
- **Block:** `blocked-human` needs a thread link, `blocked-external` a
  dated note. The run then continues with the next unblocked task.
- **Edit:** owner, status and priority change in two places only: the
  index line and the metadata line of the file. Details and progress are
  dated notes in the file, never a longer index line.
- **Human tasks** (`owner · human`) are asked once and polled; the runs
  never do them. When one completes, unblock its dependents.
- **Close:** delete the line from the index; append to done
  `- YYYY-MM-DD · T-nnn · title — result (one line) — <landing SHA>`; then
  `git mv tasks/T-nnn.md tasks/done/T-nnn.md`, so the task's history stays
  readable and out of every run's context.
- **Beside a queue-holding run:** when the lock shows one (wake-up skill,
  `reference/optional-steps.md`), every edit above but setting the picked
  task `doing` is held until its line is gone.

## Budgets
The index stays under 16,000 bytes and a task file under 12,000 (the
defaults of studio-context's budgets, checked at every close-out when it is
installed). When a new task would tip the index over, shorten the longest
titles; never drop a line, and never move a task's text back into the
index.
