# The builder brief, in full

Every builder gets a new brief. Never resume or continue a builder: a new
step is a new agent.

## What it carries
1. **The step's text, verbatim** from the plan.
2. **The plan's Goal and Constraints sections**, and the plan's path.
3. **Amendments.** Any `## Amendments` entry that corrects this step, with the
   line: "FOLLOW THE AMENDMENT, NOT THE STEP LINE IT CORRECTS."
4. **The absolute path of the review worktree** as the only tree it edits
   (skill `self-review` step 1 creates it before the first builder). Never use
   the Agent tool's `isolation: "worktree"`: that makes a separate
   throwaway tree on another branch, and the step's work never reaches the
   review branch.
5. **The project's checks.** Every command in `core.ci_commands`, in order,
   run in the worktree, with each command's pass or fail line and the test
   counts in the report. Read them with
   `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/studio_config.py get core.ci_commands`
   and paste them into the brief as a numbered list, so the builder needs no
   config access. A step whose change a command does not cover still runs it:
   a red main branch has come from the one check neither pass ran.
6. **The oracle rule.** "The expected figures, fixtures and oracles are
   read-only. A disagreement is a finding about the code, not a reason to
   change the fixture."
7. **Parallel builders.** When another builder runs at the same time: the
   files that belong to the other builder, and how to make any shared edit
   (a test config's include list) surgically.
8. **The limits.** "Never commit, push, rebase, merge, stash, reset, deploy
   or launch an agent. The orchestrator does all of that after reading your
   report."
9. **The report instruction.** "Report in under 400 words: what you changed
   (paths, one line each), what you ran and its result (the command and the
   pass or fail line, not the log), anything that did not match the plan,
   the decisions the step left open and how you took them, and what the
   orchestrator must check or decide. Do not widen the step."

## Template
```
Agent { subagent_type: "studio-core:builder",
        model: <roles.builder.model>,      # only when set
        effort: <roles.builder.effort>,    # only when set
        description: "Build T-nnn step k",
        prompt: """
Step k of plans/<slug>.md, verbatim:
<step text>

Goal and constraints (from the plan):
<Goal>
<Constraints>

<AMENDMENTS that touch this step, if any, in capitals as above>

Work only in <absolute worktree path>. Never another tree.

Run, in order, in that worktree, and report each result:
1. <ci command 1>
2. <ci command 2>

<oracle rule> <parallel files, if any> <limits> <report instruction>
""" }
```
For `studio-core:builder-sonnet`, read `roles.builder-sonnet` instead.

## Why the brief is this shape
A builder that is told only the step guesses at the context and widens the
change. A builder that is given a summary of the plan rather than the step
verbatim drops the one sentence that mattered. A builder that is not told the
fixtures are read-only will, sooner or later, make a failing test pass by
editing the expected figure.
