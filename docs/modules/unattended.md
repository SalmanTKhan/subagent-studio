# studio-unattended

Scheduled runs with nobody watching: a lock, a task queue, a journal, a
usage guard, short notifications and a permission gate. Depends on
`studio-core`, whose plan-then-build and review every run uses.

## What it adds

**Skills:**
- `wake-up`: one scheduled run. Take the lock, orient from the repo's files,
  pick tasks (usage guard first), work them through `plan-then-build` and
  `self-review`, close each out, release the lock, send one summary.
  Optional steps (polling a human's thread, standing in for another job
  that missed its slot, sharing the lock with a queue-only run) are in
  `reference/optional-steps.md`.
- `task-queue`: the one-line-per-task index, a file per task, and the pick,
  split, depends, block and close rules.
- `journal`: the run entry and the close paragraph that also replaces the
  state file's "Last run".
- `usage-guard`: at a set share of the weekly usage limit, start no new
  task except one urgent one. Skips itself when the host has no usage meter.
- `notify`: one short summary per run, and the `NEEDS HUMAN` format for the
  three things only a human can do (money, their own login or signature, a
  stop).

**Scripts** (`${CLAUDE_PLUGIN_ROOT}/scripts/`, or `scripts/studio/`):
- `wake_lock.sh add <id> | remove <id> | remove --stale | check [--holder-class P]`:
  one line per run in the lock file; `check` exits 4 when another run is at
  work.
- `notify.sh <channel> "<text>"`: posts `{"text": ...}` to the channel's
  webhook. Exit 0 sent, 2 unknown channel, 3 no webhook, else refused or
  unreachable.

**Hooks** (`hooks/hooks.json`):
- `permission_gate.py` on `PermissionRequest`: in an unattended run
  (its first prompt starts with `unattended.scheduled_prompt_prefix`), it
  allows ordinary tools, denies `AskUserQuestion` and scheduled-task changes
  with a message, and denies a list of dangerous Bash commands (a recursive
  delete of a protected path, a force push of main, `sudo`). In an attended
  run it decides nothing, not even on the dangerous list: the person sees
  the normal prompt and decides. A session whose transcript cannot be read
  counts as unattended only when its permission mode is
  `bypassPermissions` or `dontAsk`; otherwise it counts as attended.
- `prompt_alarm.py` on `Notification` (`permission_prompt`): when a prompt
  still waits in a scheduled run, it posts an alarm to `needs-human`, at
  most once per session per 30 minutes.
Both keep state and a log (`permission-gate.log`) in `$CLAUDE_PLUGIN_DATA`,
falling back to `~/.config/subagent-studio/`.

**Templates** (the kit's `templates/` folder; copy the ones you use into
your repo): `STATE.md`, `TASKS.md`, `TASKS-DONE.md`, `tasks/T-1.md`,
`tasks/T-2.md`, `journal/YYYY-MM-DD.md`, `DECISIONS.md`, `plans/_example.md`,
`prompts/wake-up.md`, and `docs/scheduling.md`, which covers desktop
scheduled tasks, cron with `claude -p`, and GitHub Actions.

## Config keys

All under `unattended`.

| Key | Default | Meaning |
|---|---|---|
| `lock_file` | `.wake-lock` | the lock file |
| `stale_hours` | `4` | a lock line older than this is stale |
| `max_tasks_per_run` | `4` | most tasks one run starts |
| `run_minutes` | `90` | rough time budget of one run |
| `usage_guard_pct` | `85` | share of the weekly limit at which a run starts no new task |
| `scheduled_prompt_prefix` | `<scheduled-task` | how the gate and the alarm recognise a scheduled run |
| `notify.channels` | `["ops", "needs-human"]` | channel names `notify.sh` accepts |
| `notify.env_file` | `~/.config/subagent-studio/notify.env` | the webhook URLs, one `STUDIO_WEBHOOK_<CHANNEL>=` line each; never in the repo |
| `permission_gate.enabled` | `true` | let the gate answer prompts in unattended runs |
| `permission_gate.protected_paths` | `[]` | extra paths a recursive delete may never hit, added to the built-in list |
| `permission_gate.deny_message_ask` | a sentence telling the run to decide or record a blocker | returned when a run asks the user a question |
| `permission_gate.deny_message_schedule` | a sentence telling the run to record the change as a task | returned when a run tries to change scheduled tasks |
| `files.state` | `STATE.md` | current-state snapshot |
| `files.tasks` | `TASKS.md` | the task index |
| `files.tasks_done` | `TASKS-DONE.md` | closed tasks |
| `files.task_dir` | `tasks` | one file per task |
| `files.journal_dir` | `journal` | one file per day, append-only |
| `files.decisions` | `DECISIONS.md` | append-only decision log |
| `files.plans_dir` | `plans` | saved plans |

The gate also reads `core.worktree_root`, to know which folder's children a
recursive delete may remove.

## What it changes in your repo

- The runs keep the state file, the task index and files, the done list,
  the journal and the decision log, at the paths in `files`. Seed them from
  `templates/`.
- The lock file appears while a run is at work; add it to `.gitignore`.
- The scheduled prompt (`prompts/wake-up.md`) is yours to edit; it lives in
  your repo, under review like any other process file if you list it in
  `core.review.reviewed_paths`.
- Nothing outside the repo except the plugin data folder and whatever your
  webhooks post.
