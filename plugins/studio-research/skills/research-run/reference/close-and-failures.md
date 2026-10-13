# The close and the failures: commit, push, the close line and every failure case

Open when committing a run's file, at the close, and when anything fails
(SKILL.md section 7).

## The commit (every file, as it lands)
1. Commit only the run's own paths, named on the commit:
   `git add <paths> && git commit -m "research <slug> <phase>: <what>" -- <paths>`.
   Never `git add -A`: another session may hold uncommitted work in the
   same tree.
2. If the add or the commit fails on `.git/index.lock`, try again after a
   few seconds, up to five times. Never delete `.git/index.lock`. If the
   fifth fails, leave the files, log `file=<path> commit failed on a stuck
   git lock`, and stop.

## The push
At the end of each phase and at the close, push the way the project
pushes. With studio-core installed and a push guard configured, run the
guard first and push only on exit 0. Any other exit: push nothing, keep
the commit local, and log the exit.

## The log
`<out_dir>/<slug>/log.md`, committed with the files: one line per event,
the time from `date -u +%Y-%m-%dT%H:%M:%SZ`, never estimated.
```
<ISO time> phase=<start|frame|gather|browser|write|check|done> <what happened> file=<path|none>
```
- Each fact file, the plan and the report get their own line when they
  are committed, so the log names every file the run wrote.
- Each agent's report is summed up on its line in a few words: the
  verdict, the questions not read, the pages that refused.
- The last line of a finished run: `<ISO time> phase=done file=<slug>/report.md`.
  A run abandoned for a newer one: `phase=done superseded by <slug>`.

## The close line
Once per run, at the close:
- **With studio-unattended's notify script installed:** one line to the
  configured channel: `Research <slug>: <verdict or "nothing passes; closest <candidate>">. <one clause on any check still failing>.`
- **Otherwise:** the same to the user in the session, plus the report's
  path.
A notify that fails is tried once more. If it still fails, `phase=done`
is not written and the next session runs the close again.

## Every failure case
- **A gatherer returns nothing** (no file, an empty file, no answers):
  launch a fresh one once with the same brief. A second failure: log
  `phase=gather B<N> failed twice`. The writer lists that block's
  questions under Unread sources, and the criteria they feed read
  `not read`.
- **A page refuses:** the gatherer retries once, then writes
  `not readable on <date>`. A 429 from a site means a second scraper ran
  against it: stop the parallel block and rerun it after the other.
- **A dead session:** the next session reads `log.md` and skips what is
  committed: the plan, each fact file, a checked report. It relaunches
  only what has no file. Before the writer it greps the fact files for
  unmarked `## Needs a browser` lines (`reference/gathering.md`, "The
  browser reader"). An uncommitted run file more than sixty minutes old
  was left by the dead session and is committed first; a younger one may
  be a live agent's, so wait.
- **Over budget:** the writer writes what came in; Unread sources names
  what was not read.
- **A report that fails check 3** (a section missing) twice goes back to
  a fresh writer.
- **A check still failing after the fix:** named at the top of Unread
  sources and in the close line. When it is check 4, the close recommends
  nothing: never a winner on a failed criterion.
