---
name: orchestrator-rules
description: The rules for the main session when it runs work through subagents. It coordinates and decides; fresh agents of the right type do every hands-on step. Read at the start of any session that will build, review or research through agents, and whenever unsure which agent type a piece of work needs.
---
# The orchestrator's rules

The main session's context is re-read on every request, so it is the
largest cost of a run. It stays small by coordinating and never doing the
hands-on work.

## The main session
- **Never** edits code, runs a test suite, reads a diff or an app source
  file, or deploys. It picks the work, writes briefs, reads reports, decides,
  runs the git commands of the review branch and the landing, and keeps the
  project's records.
- **Reads `git diff --stat`, never the diff.** `tail` every output; write
  long output to a file and read its summary.
- **Sends a report over 400 words back** for a summary instead of reading it
  whole.
- **Hands lookups to `studio-core:searcher`** when finding something would
  mean reading more than a few files. Keep its brief narrow; it reports
  `path:line` with the quoted lines.
- A session whose tool set has no Agent tool records what it needs and does
  not improvise the hands-on work itself.

## Agents
- **Every hands-on step is a fresh agent** with a written brief and a short
  report. An agent is never continued or reused across steps or tasks: a new
  step is a new agent with a new brief.
- **The right type for the work** (table below). A type carries its model,
  effort and a lean tool set, so it starts with a small context. Use
  `general-purpose` only when the step needs a tool the type lacks (a
  browser, a connector, the Skill tool), and record why.
- **Per-call model and effort.** When `roles.<role>` in `.claude/studio.json`
  sets `model` or `effort`, pass it on that role's Agent call; otherwise the
  agent file decides.
- **Haiku reads, never judges.** The searcher looks things up. It never
  builds, fixes, reviews, plans, or decides a finding.

| Work | Agent type |
|---|---|
| Find or read something across many files | `studio-core:searcher` |
| Plan a new app, core architecture, a complex and critical module | `studio-core:planner-max` |
| Plan any other big feature, a re-plan, an amendment | `studio-core:planner` |
| Build a step, fix a blocker or major finding | `studio-core:builder` |
| Build a menial, fully defined step (all four conditions of `plan-then-build` §6) | `studio-core:builder-sonnet` |
| Check a step's acceptance, a read-only proof | `studio-core:reviewer` |
| Review pass one, with the author's checklist | `studio-core:reviewer-pass-one` |
| Review pass two, the fresh review before landing | `studio-core:reviewer` (a new one) |
| A step needing tools no type carries | `general-purpose` |
| Research that decides what to build (when installed) | `studio-research:research-lead` |
| Web reading for research (when installed) | `studio-research:gatherer` |

## The work
- **Big work starts with a plan:** skill `plan-then-build`.
- **Every change to a reviewed path lands through review:** skill
  `self-review`.
- **Split big tasks before starting**, so every session finishes something
  and a hard stop loses nothing. **A task still unfinished after three
  runs** gets split, or becomes a question for a human.
- **Write a skill the second time you do something.** Rediscovery is waste;
  a new or changed skill goes through review like code.
- Anything not committed and pushed did not happen.
