---
name: plan-then-build
description: Use for big work (a new module, a big feature, anything hard to reverse). A read-only planner agent returns the plan, the session saves it to plans/<slug>.md and commits it, then one fresh builder agent runs each step and a fresh reviewer checks each step against its acceptance line. Says what counts as big, which planner plans it, and gives the exact Agent calls.
---
# Plan then build

Big work first gets a plan, and fresh agents execute it. The session that
picked the task orchestrates: it launches the planner, saves the plan,
launches the builders, has each step checked and closes out. It never does
the big work itself (skill `orchestrator-rules`).

**Script paths.** `${CLAUDE_PLUGIN_ROOT}` is replaced with the plugin's
directory in this file only, not in `reference/` files: use the path shown
here. If it shows unreplaced, the plugin root is two levels above this
skill's base directory. Config is read with
`python3 ${CLAUDE_PLUGIN_ROOT}/scripts/studio_config.py get <key>`.

## 1. What must go through this
- A new app, service or module, from the first decision to the skeleton.
- A big feature: more than one session of work, the core feature of a
  milestone, or anything that touches money or billing, the data model (a
  migration), authentication or security, personal data, a public API or
  file format, or a new external service or account.
- Each line of `core.plan.big_also` (the project's own additions):
  `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/studio_config.py get core.plan.big_also`.

Skip it for a bug fix, strings, one route or component, a config change.
When unsure, plan: a plan costs ten minutes, a big task without one a day.

## 2. Which planner plans it
**`studio-core:planner-max`** plans what is hard to reverse or hard to get
right: a new app's or service's architecture and the steps to its skeleton;
core architecture (an engine the code is built around, a shared library's
design, a data model from scratch); a module that is both complex and
critical. **`studio-core:planner`** plans every other big feature, every
re-plan and every amendment. When unsure whether it is a new app,
`planner-max`; otherwise `planner`. The two-question test and examples:
`reference/which-planner.md`.

## 3. Per-call model and effort
Read `roles` once: `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/studio_config.py get roles --format json`.
When `roles.<role>` sets `model` or `effort`, pass it on that role's Agent
call; when it does not, leave the field out and the agent file's
frontmatter decides. The role is the agent name without `studio-core:`.
Every template below takes these optional fields:
`model: <roles.<role>.model>, effort: <roles.<role>.effort>`.

## 4. The plan (read-only)
```
Agent { subagent_type: "studio-core:planner-max" or "studio-core:planner",
        run_in_background: false, description: "Plan T-nnn",
        prompt: <the brief> }
```
Never the built-in `Plan` type. The brief carries the task's text, the
constraints that bind (CLAUDE.md rules, safety tiers, the plan's milestone
and exit criteria if any), the files to read first, and the instruction to
explore read-only and return the plan in exactly this shape:
```
# Plan: <slug>
Task: T-nnn · Written: YYYY-MM-DD · Planner: studio-core:planner-max | studio-core:planner
## Goal
One paragraph: what done looks like, ending with the task's acceptance line.
## What I read and what I found
Facts with file paths. Unknowns named as unknowns.
## Constraints that bind this work
## Steps
### Step 1: <title>
Files: … · Does: … · Acceptance: <one checkable line> · Risk: … · Parallel with: none | step n · Model: opus | sonnet (§6)
### Step 2: …
## Out of scope
What this deliberately does not do.
## Risks and how each is caught
Tests, checks, rollback.
## Open questions
Only what a human must answer (money, a login or signature only they hold,
a stop). Everything else the plan decides, with the reasoning.
```
A planner cannot write files. Save the text as `plans/<slug>.md` (slug:
task id plus a short name, e.g. `t-12-csv-export`), commit it as
`plan: T-nnn <title>` and push it **before the first builder starts**, then
cut the review branch (skill `self-review` step 1). Details, and where the plan
commit goes when `plans/` is a reviewed path: `reference/close-out.md`.

## 5. The build: one fresh builder per step
For each step in order, or in parallel where the plan marks steps
independent, a **new** agent with a new brief, never continued across steps.
The orchestrator never does a step itself.
```
Agent { subagent_type: "studio-core:builder",   # or "studio-core:builder-sonnet" under §6
        description: "Build T-nnn step k", prompt: <the builder brief> }
```
The builder brief (in full: `reference/builder-brief.md`): the step
verbatim; the plan's Goal and Constraints; any `## Amendments` that touch
the step, flagged in capitals; **the absolute path of the review worktree**
as the only tree it edits (never Agent-tool `isolation`); every command of
`core.ci_commands`, run in order with each result in the report; fixtures
and expected figures are read-only; never commit, push, rebase, deploy or
launch agents; report under 400 words.

A step needing a tool the builder lacks (a browser, a connector, the Skill
tool) runs as `general-purpose`; record why.

**Parallel builders own disjoint files.** Tell each which files belong to
the other and how to make any shared edit surgically.

## 6. Which model builds a step (the four conditions)
The default `studio-core:builder`. `studio-core:builder-sonnet` builds a
step only when all four hold:
1. the files it touches are named in the step;
2. the behaviour is given, not chosen: concrete cases with expected results,
   a table of strings, an outline, or a pattern in the repo named by path;
3. the acceptance is mechanical: a command that passes or fails, or a figure
   that must match, no judgement;
4. nothing in it decides behaviour a user sees, or touches money, personal
   data, a migration, a legal sentence, security, or a write to production
   data.
Never Sonnet: core logic, a route's control flow, a migration, a legal rule,
a blocker or major finding's fix, a review, a plan. A Sonnet step that fails
its acceptance is redone by `studio-core:builder`, never a second Sonnet
run. Typical Sonnet steps: `reference/which-planner.md`, its end.

## 7. Checking a step: a fresh reviewer, never by hand
A report is evidence, not proof. Builders never commit and a reviewer
reads only committed SHAs, so the orchestrator commits the step's
files by path (never `-A`) on the review branch, unreviewed by definition,
and pushes. A fresh read-only agent then checks the step's range:
```
Agent { subagent_type: "studio-core:reviewer", run_in_background: false,
        description: "Check T-nnn step k",
        prompt: <acceptance, plan path, report, <prev step SHA>..<step SHA>, the five checks> }
```
The five checks: re-prove the acceptance outside the builder's suite; make
a guard bite; fixtures unedited; read the diff, not the summary;
answer the report's questions. In full, with the commit recipe:
`reference/checking-a-step.md`. A step missing or red goes to a fresh
builder.

**Re-plan after two failed acceptances**, or when the world refuses the
approach (an API, a policy, a platform says no): `reference/close-out.md`.

## 8. Close
Skill `self-review`, run by the orchestrator and never by a builder: the
step commits, made as each step was checked, get their review passes before
anything reaches the main branch. Turn each `## Out of scope` item into a
task. Add `## Outcome` to the plan. In full: `reference/close-out.md`.

## Reference files (each in `reference/`)
| Open when | File |
|---|---|
| choosing the planner, typical Sonnet steps | `which-planner.md` |
| writing a builder's brief | `builder-brief.md` |
| a builder's report is in | `checking-a-step.md` |
| saving the plan, a re-plan, closing | `close-out.md` |
