# The plan file's life: saving it, re-plans, closing

## Saving the plan
A planner cannot write files. The orchestrator:
1. saves the returned text as `plans/<slug>.md` (slug: the task id plus a
   short name, for example `t-12-csv-export`);
2. commits it as `plan: T-nnn <title>`, by path
   (`git add -- plans/<slug>.md && git commit -m "plan: T-nnn <title>" -- plans/<slug>.md`),
   and pushes it, **before the first builder starts**;
3. adds `plan: plans/<slug>.md` to the task's line, if the project keeps a
   task queue.

Where the commit goes: when `plans/` is not in `core.review.reviewed_paths`
and `core.review.docs_only` is true, commit it on the main branch and push,
then cut the review branch from the remote main (skill `self-review` step 1), so
the branch starts with the plan in it. Otherwise make the plan the first
commit on the review branch, and it is reviewed with the rest.

An open question that only a human can answer (money, a login or signature
only they hold, a stop) goes to that human once; the build starts on the
steps that do not depend on the answer. Any other question the orchestrator
decides and records.

## Re-plans
A step that fails its acceptance twice, or an approach the world refuses (an
API, a policy or a platform says no), goes back to a planner. Launch a fresh
`studio-core:planner` with the plan, the failing step, the builders' reports
and the evidence. Take the amendment it returns into `## Amendments`, or its
revised plan. **The exception:** when the fix changes a new app's
architecture, or the core architecture a `planner-max` plan set, the re-plan
goes to `studio-core:planner-max`. The orchestrator never quietly does the
step itself.

## Closing
1. **Review.** Skill `self-review`, run by the orchestrator and never by a
   builder. The step commits get their review passes on the review branch
   before anything reaches the main branch. The plan's close adds no further
   review round. A builder's report and a step's re-proof do not replace the
   fresh review of the whole branch. A step that ends a session unreviewed
   stays on its pushed review branch.
2. **Step commits.** The orchestrator has already committed each step on the
   branch, by explicit path and never `-A`, and pushed it, as each builder
   reported and before that step's check (`checking-a-step.md`); parallel
   builders in one worktree own disjoint files, so each step's paths are
   committed on their own.
3. **Out of scope.** Each `## Out of scope` item becomes a task.
4. **Outcome.** The plan file stays in `plans/` as the record. Add
   `## Outcome`: the date, what shipped, what changed from the plan and why,
   what was cut and the task it went to. Name the plan and how many builder
   runs it took in the session's record.

## A session with no Agent tool
It writes what it needs into the project's record and queue and does not
improvise the plan or the build itself. A later session with the Agent tool
picks it up.
