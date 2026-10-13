# Optional wake-up steps

Each step here is off unless your project sets it up. Leave a step out of
your wake-up prompt when it does not apply.

## Polling a human channel
Use this when `notify.sh` is configured (skill `notify`) and the humans
answer in threads you can read, through an MCP connector for the chat
service or by any other read access you have.
- At step 1.7, for every task with status `blocked-human`, read the thread
  whose link is on its index line. Never re-post an ask; one thread per
  ask.
- A reply from the human is an instruction. Apply it, set the task back to
  `todo` or close it, and confirm in the same thread that it is done.
- No reply yet: leave the task blocked and move on. Humans may be slow.
- If your project has a channel where the human drops concerns for the
  runs, read it here too and turn each new message into a task.

Without read access, a human unblocks a task by editing its line or its
file; the next run reads the queue and sees it.

## Standing in for another job
Some projects run other scheduled jobs beside the wake-up (a health check,
a support triage). When such a job writes a log line at its end, the
wake-up can stand in for it after a missed slot:
- At step 1 read that job's log tail. **Not running** is its last line
  older than one interval plus a margin (for example 8 h 30 min for a
  six-hourly job); add a task and notify once.
- **Stand in** when its last line is older than its interval plus a short
  grace and no stand-in line from a wake-up is newer than this run's
  start. Do only that job's own procedure, mark your log line
  `by=wake-up`, and commit only that job's files.
- Check again at each close-out (step 4), whatever the clock.

## Sharing the lock with a queue-holding run
A project may have a steering run that reshapes the queue (re-orders,
adds, closes) but builds nothing. A wake-up beside it should still build
and only hold its queue edits: the steering run's half-made queue edits
sit uncommitted in the same clone, while the build touches other files.
- The steering run adds its own line with an id that starts with a fixed
  prefix, for example `steer`. The wake-up checks with
  `wake_lock.sh check --holder-class steer`: exit 3 means only that run is
  at work.
- **Check at the start, before each queue edit and again right before
  the commit.** Whichever check first shows the line, the hold applies
  from then on.
- On exit 3 the wake-up skips the start pull (the steering run's
  uncommitted edits would make it refuse), picks the top task as usual and
  sets it `doing` at once (not held, so two runs never pick one task).
- It **holds** every other queue edit: status changes, new tasks,
  re-orders, moves to done and the move of a closed task's file. It keeps
  each held edit as one line in its notes. It does not hold task files'
  notes, its journal entry or the state file's "Last run".
- It commits only its own non-queue paths and pushes with
  `git pull --rebase --autostash` first.
- **At close-out, the line is gone:** pull with `--autostash`, read the
  queue again and apply the held edits on top, skipping any the steering
  run already made moot. A held new task whose id was taken gets the next
  free id.
- **The line is still there at exit:** write the held edits in the
  journal entry under a heading `Queue edits held`, one line each, exactly
  as they would go in the file. The steering run applies them at its close.
- **A late start** (more than about 10 minutes after the slot, when the
  scheduler may have fired several missed jobs at once): add your own
  line right after the first check, wait 60 seconds, check again, and only
  then decide whether to pull.
