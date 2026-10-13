# studio-context

Byte budgets for the files every session loads, a check that moved text
lost nothing, and reports on tokens and effort levels. Optional and
standalone: it depends on nothing.

## What it adds

**Skill:** `context-budget`. Keep `CLAUDE.md`, the state file, the task
index, each `SKILL.md` and each agent file under budget by moving text out
word for word behind a stub, prove the move, and measure tokens weekly.
Detail in `reference/moving-text.md` and `reference/scripts.md`.

**Scripts** (`${CLAUDE_PLUGIN_ROOT}/scripts/`, or `scripts/studio/` in a
copy-in install). Each takes `--help`.
- `context_budget.py [--root DIR] [--quiet] [--orientation FILE...]`: a
  table of every budgeted file against its budget, plus the orientation
  total. Exit 1 when anything is over.
- `check_moved_text.py --old <file | git:REF:path> --new FILE...`: every
  non-blank line of the old file must appear in the new files. Exit 1 lists
  what is missing. `--ignore REGEX`, `--min-chars N` (default 8).
- `token_usage.py --days N [--runs] [--strip-prefix P]`: tokens per run type
  per day from the session transcripts, this week against last, with
  `DOUBLED` beside a run type whose per-run average doubled.
- `effort_check.py --days N`: the effort level each scheduled run ended at,
  against `context.expected_effort`, and each agent's level against its
  agent file. Exit 1 on a mismatch.
- `my_context.py --minutes N`: the live context size of sessions active now.
- `transcripts.py`: prints the transcript folder the scripts would read.

No agents, no hooks.

## Config keys

All under `context`.

| Key | Default | Meaning |
|---|---|---|
| `context.budgets` | `CLAUDE.md` 32000, `STATE.md` 8000, `TASKS.md` 16000, `.claude/skills/*/SKILL.md` 8000, `.claude/agents/*.md` 6000 | a list of `{"path_glob", "max_bytes"}`; a file matched by several entries takes the last one |
| `context.orientation_total_bytes` | `40000` | budget for everything a run reads to orient itself: every literal path in `budgets` except `CLAUDE.md` |
| `context.timezone` | `UTC` | IANA zone used to bucket runs by day |
| `context.transcripts_dir` | `""` (auto-detect under `~/.claude/projects/`) | where the session transcripts are |
| `context.expected_effort` | `{}` | run name to effort level, checked by `effort_check.py`; empty means runs are not checked |

The transcript scripts read the transcripts on the machine where the
sessions ran, so run them there.

## What it changes in your repo

Nothing by itself; the scripts only read. The skill's procedure, when you
follow it, moves sections out of `CLAUDE.md` into
`docs/claude/NN-<slug>.md` (or detail into a skill's `reference/`, or
a task's text into `tasks/T-nnn.md`) and leaves a stub behind.
