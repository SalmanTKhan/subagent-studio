---
name: effort-low
description: Sets this session's effort level to low. Call it first in a scheduled or headless run's prompt that is meant to run at low, and again after each background agent's task notice. Never call it unless a run's prompt or the user names it.
effort: low
---
# Effort low

Calling this skill through the Skill tool is the whole job: its `effort`
frontmatter sets the effort level to low while the skill is active,
overriding the session's level (but not the `CLAUDE_CODE_EFFORT_LEVEL`
environment variable, a `maxEffortLevel` setting or an organization cap).

**Call it first** in a scheduled run's prompt, and **call it again after
each background agent's task notice**: the level can fall back to the
session default when a new turn starts. The docs promise the level only
while the skill is active and do not say it outlasts the turn. In practice
it has held for a whole run, and has also been seen to drop back after a
background agent's notice.

**The reliable paths:**
- For the session: start the run with `--effort low` or
  `CLAUDE_CODE_EFFORT_LEVEL=low` (`claude -p --effort low ...`).
- For agents: pass `effort` on each Agent call, from `roles.<role>.effort`
  in `.claude/studio.json` (Claude Code v2.1.292 or later). An agent
  without it takes its type's frontmatter `effort`, and a type that names
  none works at the launching session's level.

There is nothing else to do here. Go back to the procedure that sent you and
carry on. Do not call another `effort-` skill in the same run.
