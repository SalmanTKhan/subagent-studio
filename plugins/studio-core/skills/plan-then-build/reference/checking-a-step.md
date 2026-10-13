# Checking a step, amendments, parallel builders, and what the plan left out

## The five checks
A builder's report is evidence, not proof. The orchestrator does not re-prove
it by hand, because its own context is the costliest in the session.

**First, commit the step.** Builders never commit, and a reviewer reads only
committed SHAs (`git archive`, never a working tree), so uncommitted step
work is invisible to it. After a builder reports, the orchestrator commits
that step's files on the review branch, by explicit path, never `-A`, and
pushes the branch. The branch is unreviewed by definition, so a commit there
is allowed; the self-review passes still read the whole branch at the end.
```bash
W=<worktree>; T=<review branch>; REMOTE=<remote>; : "${W:?}" "${T:?}" "${REMOTE:?}"
PREV=$(git -C "$W" rev-parse HEAD) &&
git -C "$W" add -- <step paths> && git -C "$W" commit -m "T-nnn step k: <title>" -- <step paths> &&
git -C "$W" push -u "$REMOTE" "$T" && echo "STEP=$PREV..$(git -C "$W" rev-parse HEAD)"
```
Write the step range into the session's record. Then launch a fresh
`studio-core:reviewer` (read-only) briefed with the acceptance line, the
plan's path, the builder's report, the repo's absolute path, the step range
`<prev step SHA>..<step SHA>` and these five checks, and read the figures it
returns:

1. **Re-prove the acceptance line outside the builder's own suite.** Export
   the step SHA (`git archive <step> | tar -x -C <scratch>`), write a
   throwaway test or script in a scratch directory, print the figures the
   acceptance names, delete it. A suite the builder wrote can pass for the
   wrong reason; the same numbers out of a second harness cannot.
2. **Prove a guard bites.** When the step ships a test or check whose job is
   to fail, make it fail: add the forbidden thing in a scratch copy, watch
   the message, and confirm the repo's trees are untouched. The builder's own
   account of it is worth less than doing it once.
3. **Check the oracle was not edited.** `git diff --stat <prev>..<step> -- <fixture dirs>`
   must be empty. Every builder is told the expected figures are read-only.
4. **Read the diff, not the summary** (`git diff <prev>..<step>`). Decisions the plan had not settled are
   visible in the code even when they are not errors. They belong in the
   project's record, not only in the code.
5. **Answer the questions the report asks.** A good builder names the calls
   it had to make and offers to reverse them. Decide, say so, and record the
   decision where the next session will find it.

The reviewer reports in under 400 words: each check, pass or fail, with the
command and its figure. A step that fails any check goes back to a fresh
builder with the finding; its fix is committed the same way and checked as a
new range. When the proof must write something (run a
migration on a scratch database, deploy to a test environment), launch a
`studio-core:builder` for it instead, told to change no file.

Template:
```
Agent { subagent_type: "studio-core:reviewer", run_in_background: false,
        model: <roles.reviewer.model>,     # only when set
        effort: <roles.reviewer.effort>,   # only when set
        description: "Check T-nnn step k",
        prompt: "Acceptance: <line>. Plan: plans/<slug>.md step k. Repo:
<abs path>. Step range: <prev step SHA>..<step SHA>. Builder's report:
<report>. Run the five checks: <list>. You are read-only; review the committed
range only and work in a scratch copy. Report each check with its command
and figure, under 400 words." }
```

## Amendments
A finding from a completed step that corrects a later step goes into an
`## Amendments` section at the foot of the plan: the step it corrects, the
correction, and the evidence. A builder follows the amendment, not the line it
fixes, and the step's brief says so in capitals. One early step's
amendments once caught a currency rule that would have refused most of the
plan's own test cases.

## Parallel steps share one working tree
When the plan marks two steps independent, launch both. Tell each builder
which files belong to the other and how to make any shared edit surgically.
Builders that share a resource outside the tree (a local test database, a
port) need a lock or a separate instance named in each brief; two suites that
drop and recreate the same database at once fail each other at random.

## Queue what the plan left out
The `## Out of scope` section is a list of tasks nobody has written yet. Turn
each into a real task at close, or it is lost.
