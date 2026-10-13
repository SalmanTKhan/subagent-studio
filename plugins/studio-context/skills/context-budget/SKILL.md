---
name: context-budget
description: Keep the files every session loads small, and measure what context costs. Use at every close-out, when CLAUDE.md, the state snapshot, the task index, a SKILL.md or an agent file grows past its budget, when a section must move out of CLAUDE.md word for word, to prove a move lost nothing, to read tokens per run type each week, or to check the effort level runs and agents really used.
---

# Context budget

Scripts live in `${CLAUDE_PLUGIN_ROOT}/scripts/`. If your Bash cannot see
`CLAUDE_PLUGIN_ROOT`, use this skill's base directory: the plugin root is two
levels above it. Every script takes `--help`.

## Why size is the cost

Every request re-reads the whole context. Most of it comes from the prompt
cache, but cached tokens still count against usage. So the cost of a run is
roughly its context size times its request count, and a file loaded into
every request is paid for on every request of every session and every agent.

- CLAUDE.md is injected into every request. It says so at its top, and that
  it is never read again with a tool.
- The orientation files (the state snapshot, the task index) are read at the
  start of every run.
- A SKILL.md is loaded whole when the skill is invoked.
- An agent's tool list is loaded on every request of that agent. Unused tool
  schemas are pure cost. Measured once: a builder on a general-purpose agent
  started near 80k tokens of context; a lean type with eight tools started
  near 20k.

Moving text is free. Deleting a rule is not. What grows moves out, never
gets deleted.

## The budgets

Budgets live in `.claude/studio.json` under `context`:
- `budgets`: a list of `{"path_glob", "max_bytes"}`. A file matched by
  several entries takes the last one's budget, so put the exceptions after
  the general globs. Defaults: CLAUDE.md 32000, STATE.md 8000, TASKS.md
  16000, each SKILL.md 8000, each agent file 6000.
- `orientation_total_bytes`: the total for the orientation set (every
  literal path in `budgets` except CLAUDE.md, or `--orientation FILE...`).
  Default 40000, about 10k tokens before any work starts.

Run at every close-out:

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/context_budget.py          # table, exit 1 when over
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/context_budget.py --quiet  # verdict only
```

A budget entry that matches nothing prints "not present" and is not a
failure. An OVER line is the next thing to fix, by moving text, never by
cutting a rule.

## Procedure: a file is over budget

1. **Pick what moves.** Keep in CLAUDE.md what every request needs: the
   non-negotiables, the operating model, the rules every write follows.
   Move what only some runs need: long tables, history, procedures for one
   kind of run.
2. **Move word for word.** Put each long section into
   `docs/claude/NN-<slug>.md`, where NN is the section number, with
   its heading and numbering intact. Change no wording.
3. **Leave a stub.** In CLAUDE.md, keep the section's heading and number
   and one or two lines: where the text now lives and when to open it
   (which run, which question). Every "see section N" elsewhere in the repo
   still resolves.
4. **Prove nothing was lost.** Before committing, from the project root:
   ```bash
   python3 ${CLAUDE_PLUGIN_ROOT}/scripts/check_moved_text.py \
     --old git:HEAD:CLAUDE.md --new CLAUDE.md docs/claude/*.md
   ```
   Every non-blank line of the old file must appear in the new set. Exit 1
   lists what is missing; put it back.
5. **Re-run** `context_budget.py`. Record the move in your decision log
   with the reason and the byte counts.

The same move works for the state snapshot (detail into `state/<area>.md`),
the task index (one line per task, full text in `tasks/T-nnn.md`) and a
skill (detail into its `reference/`). See `reference/moving-text.md`.

## Skills and agents

- Keep each SKILL.md under 8 KB: the procedure only. Recipes, background
  and rare cases go word for word into `reference/*.md` files that the
  procedure names, so they are read only when needed. Keep every trigger
  word in the description.
- Keep each agent type's tool list short: only the tools its job uses. A
  reviewer that never writes gets no Edit or Write. Use a general-purpose
  agent only when a step really needs a tool the lean types lack.
- Make the orchestrating run thin: it hands each hands-on step to a fresh
  agent with a brief and reads back a short report, so its own context
  grows only with briefs, reports and decisions.

## Measure every week

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/token_usage.py --days 7 --runs
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/my_context.py --minutes 10
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/effort_check.py --days 2
```

- `token_usage.py`: tokens per run type per day, this week against last,
  with DOUBLED beside a run type whose per-run average doubled. Read it
  once a week and treat a doubling as a task: find what grew.
- `my_context.py`: the live context size of the sessions active now. It
  measures; no rule hangs on the number.
- `effort_check.py`: the effort level each scheduled run ended at, against
  `context.expected_effort`, and each agent's level against the `effort:`
  line of its agent file. Exit 1 on a mismatch.

How they find the transcripts, name run types and read levels:
`reference/scripts.md`.
