---
name: journal
description: Append a run entry to journal/YYYY-MM-DD.md at the end of every scheduled run, ending in the close paragraph that also replaces the state file's "Last run". Use at every close-out.
---
# Journal

One file per day in the journal folder (`unattended.files.journal_dir`,
default `journal/`), named `YYYY-MM-DD.md`, append-only. Never edit an
earlier entry; a correction is a new line in a later one.

## Entry
```
## Run: <HH:MM> · <task ids> · <outcome: done | partial | blocked | nothing-to-do>
**Did:** 2 to 6 bullets. Concrete: what changed, where, links and ids.
**Learned:** gotchas, dead ends, numbers, anything the next run must not rediscover.
**Next:** the task the next run should pick, if it differs from queue order.

**Close (<time read from date>).** <the close paragraph>
```
Take the time from `date`, never from memory, in the project's time zone.

## The close paragraph
In bold, starting `**Close (<time>).**`: what finished and where it
landed (branch, SHA), what is in flight with its branch, worktree and
where to resume, side effects outside the repo, what went into memory or a
skill, and `**Next run:**` what to pick up.

The same paragraph replaces the "Last run" section of the state file
(`unattended.files.state`, default `STATE.md`). The next run reads it
there, so it never has to open the journal at its start.

## Reading the journal
Never whole. By grep: `grep -n 'T-12' journal/*.md` for a task's history,
or one entry by its heading (`grep -n '^## Run' journal/<date>.md`, then
`sed -n` that range).

## Writing well
Write for the next run, not for a person. A gotcha that costs 10 minutes
to rediscover belongs here and, if it repeats, in a skill. Keep large
results legible at a glance: a daily summary built from these entries
should need no other source.
