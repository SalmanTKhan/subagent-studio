# TASKS

The queue index: one line per open task, read whole by every run. A task's
text lives in `tasks/T-nnn.md`, opened only when the task is picked.

Legend:
- Line: `- [ ] T-nnn · owner · status · P# · title — tasks/T-nnn.md — added YYYY-MM-DD[ — depends: T-x][ — plan: plans/x.md]`
- owner: `claude` | `human`
- status: `todo` | `doing` | `blocked-human` (with ` — thread: <link>`) | `blocked-external`
- P0: nothing else can proceed. P1: on the critical path to the next milestone. P2: needed, not blocking.
- Pick: top-most `claude` task at `todo` or `doing`, P0 first, top to bottom; skip blocked tasks and unmet `depends:`.

## P0

## P1
- [ ] T-1 · claude · todo · P1 · Add input validation to the import command — tasks/T-1.md — added 2026-01-05 — plan: plans/_example.md

## P2
- [ ] T-2 · human · blocked-human · P2 · Approve the hosting spend for staging — tasks/T-2.md — added 2026-01-05 — thread: <link>
