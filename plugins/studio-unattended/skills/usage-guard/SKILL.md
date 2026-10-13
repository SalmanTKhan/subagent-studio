---
name: usage-guard
description: The weekly usage guard. How a scheduled run reads the plan's usage meter, and what it does when the week is used past unattended.usage_guard_pct (default 85), so the last share of the week keeps the cheap runs that watch production alive until the reset. Production watchers are never guarded. Read by the wake-up at its pick step.
---
# Usage guard

## Why
A subscription plan has one weekly limit shared by every run. When it runs
out, every scheduled run stops at its first message until the reset,
including the checks that watch production, which can then go unwatched
for most of a day. The guard keeps the last part of the week for those
cheap runs.

## Threshold
`python3 ${CLAUDE_PLUGIN_ROOT}/scripts/studio_config.py get unattended.usage_guard_pct`
(default 85). If your Bash cannot see `CLAUDE_PLUGIN_ROOT`, the plugin
root is two levels above this skill's base directory.

## Reading the meter
Use whatever usage tool the host offers. Some hosts expose a session
management tool that reports plan usage (look for a tool whose name ends in
`get_usage`; in scheduled runs it may be deferred, so load it first with
ToolSearch). Take the weekly window that covers all models: its percent
used and its reset time. Write the reset as `YYYY-MM-DD HH:MM` in the
project's time zone.

The meter is **unreadable** when no such tool exists, the call fails, the
plan status is not ok, or the weekly window is missing. Unreadable never
stops a run: carry on unguarded. Say so in the journal once per run:
`usage guard: meter unreadable`.

**Tripped** means the percent used is at or above the threshold.

## The wake-up
Read the meter at the pick step before the first task, and again each
time the close-out sends the run back for another. When it trips:
1. Start no new task, except one urgent task per run (below). The task in
   hand is closed out fully first, never left half done.
2. Do any stand-in for a production watcher that is due (wake-up
   `reference/optional-steps.md`).
3. Write a journal line: `usage guard: weekly <n> %, resets <YYYY-MM-DD HH:MM>`.
4. Tell the humans once per week window. The window began seven days
   before the reset. Search the journal since that day for a line with the
   same reset date ending `, told`
   (`grep -n 'resets <YYYY-MM-DD' journal/*.md`). None found: send a short
   plain note with `${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh ops "<text>"`
   and end this run's journal line with `, told`. For example: "This
   week's usage is 87 % spent. Building is paused until the reset on
   Sunday at 14:00. Production checks keep running."
5. Close out and exit.

**One urgent task.** While the guard is on, a run may still take ONE task
per run that is P0 and is for users waiting on you, production (an
incident, a rollback follow-up), a red CI on the main branch, or a gap a
review audit found (unreviewed code on the main branch). It takes it as
usual, closes it out, then does steps 2 to 5. Everything else waits for
the reset.

## Other guarded runs
A steering or planning run reads the meter once and writes
`Plan: weekly <n> %` in its log. When it trips it still runs, but it queues
only P0 work and launches no agent beyond its usual checks.

## Never guarded
Production watchers (health checks, incident triage), the daily report,
and the humans' own sessions. They never read the meter for this rule and
never stop for it.
