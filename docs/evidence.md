# Evidence

What the project this kit came from measured while it ran this way. Read
the caveats first.

## Caveats

- **The token drop below has several causes, and the data does not
  separate them.** In the three weeks it covers, the scheduled runs moved
  from a larger model to Opus, and Opus stood in for planning and research
  when the larger model hit its limit; the effort levels were lowered
  twice; and wake-ups ran more often (every six hours, then four, then
  three: about 40 runs a week at the start, 55 at the end), so each run
  had less to do. Part of the fall per run is shorter runs, not cheaper
  ones.
- **The lean agent types did not cause that drop.** They landed, with the
  context budgets, on the second day of its first week, so the high
  starting figure already had them. What can honestly be claimed for them
  is the smaller starting context of each agent below, not the weekly
  fall.
- **The counts come from the project's own logs** (its task archive, its
  plan files, its git history and its session transcripts), not from an
  independent measurement. Nobody outside the project checked them.
- **One project, one operator.** Five weeks of one person running most of
  the work through Claude Code, mainly scheduled runs. Your project, your
  team and your mix of work will differ.
- The review finding counts are rough. They were tallied from landing
  messages and logs and mix the two passes together.

## What was measured

| What | Figure |
|---|---|
| Tasks closed | about 490 in 5 weeks |
| Written plans | 48 |
| Reviewed landings | about 400 |
| Review findings logged | roughly 7 blockers, 75 majors, 466 minors (both passes mixed) |
| Tokens per scheduled wake-up run, before the review process | about 18M |
| The same, once plan-then-build and fresh review landed | about 111M |
| Tokens per wake-up run over the next three weeks | about 82M, then 44M, then 29M |
| All tokens in those three weeks | 3,925M, then 2,497M, then 1,765M |
| Starting context of a builder or reviewer | the project's estimate: about 80k tokens as a general-purpose agent, about 20k as a lean type with 5 to 8 tools |
| Of that 80k, measured as tool schemas the agent never used | 46k |
| Share of tokens that were cache reads | 97% |

**How the token figures were counted.** Each week's figure is the
project's latest count of that week, read from session transcripts a week
or more later. The first week was counted twice: on its last day at 3,324M
in all and 76M per wake-up, and a week later, with more transcripts in, at
the 3,925M and 82M shown. The 18M and 111M come from an earlier read of
every transcript of the project's first week.

**Why the budgets came first.** The process this kit packages first made
runs more expensive, not less. Once plan-then-build and fresh-agent review
landed, a wake-up cost about six times what it had: each agent call carried
a large starting context, and the orchestrating run's own context grew
with every file it read. That rise is what led to the context budgets and
the lean agent types. Read the later fall with the caveats above.

**Why cache reads matter.** With 97% of tokens served from the prompt
cache, cost tracked context size times request count, not the length of
the new text in each request. That is why the kit spends its effort on
small agent contexts and a thin orchestrator rather than on shorter
prompts.

**Review effort.** A blind replay of 8 past reviews ran pass one at two
effort levels on the same commits. At high effort it caught 3.0 of 4
confirmed majors on average; at xhigh, 2.5. High cost 39% less. Eight
reviews is a small sample; the result was enough to keep pass one at high,
not to claim high is better in general.

**Reviewers per landing.** An earlier count found 90 reviewer agents for 46
landings: reviews were being run per plan step as well as per change. That
led to the rule of one fresh reviewer per branch, with step checks as
separate, cheaper proofs.

## One month in: cost per task, roles, review and skills

Later counts, read from the same project's session transcripts and git
history for its scheduled wake-up runs from Sep 12 to Oct 12 (181 runs, 2,278
subagents, 463 tasks finished and merged). Dollars are the tokens of every
request, subagents included, priced at public API list rates per model; the
project paid a flat subscription, so they measure compute, not a bill.

**Caveats for this section.** A "finished task" is one entry in the
project's closed-task log, credited to the run whose commit closed it; tasks
vary in size, and the queue split big ones into steps. Periods are stretches
when the setup held still, and the last one is only 6 runs. The first five
days, when one session worked alone with no planning or review, are left
out: it was a different job, not a cheaper version of this one.

| Period | Lead | Builders | Reviewers | Cost per finished task |
|---|---|---|---|---|
| Sep 12–13 | Opus 5, xhigh | Opus 5, xhigh | Opus 5, xhigh | $30.11 |
| Sep 14–18 | Opus 5, xhigh | Opus 5, xhigh | Opus 5, xhigh | $32.67 |
| Sep 19–22 | larger model, xhigh | Opus 5, high | Opus 5, xhigh | $22.59 |
| Sep 22–Oct 4 | Opus 5.5, medium | Opus 5.5, medium | Opus 5.5, xhigh | $7.45 |
| Oct 5–10 | Opus 5.5, medium | Opus 5.5, medium; Sonnet 5.5, high for spelled-out steps | Opus 5.5, high and xhigh | $7.15 |
| Oct 11–12 | Opus 5.5, medium | as above | Opus 5.5, high | $6.90 |

**Per run, by role** (Sep 14–21, 44 runs, against Oct 5–12, 23 runs):
builders $26.44 to $5.68, the lead session $16.20 to $5.08, reviewers $7.19
to $3.94 (with more reviews per run, 3.8 to 4.7), other specialists $6.32 to
$3.61, planners $2.73 to $0.79. The whole run: $58.90 to $19.10.

**Review findings at the final gate.** Every landing records what the fresh
final reviewer found. Over 410 such landings: 11 blockers, 174 majors and 938
minors, with blockers and majors fixed before the merge. Serious findings
per change fell as cost fell: 0.64 (Sep 12–21), 0.40 (Sep 22–Oct 4), 0.27
(Oct 5–12), and the share of changes with no serious finding rose from 57% to
77%. Part of that drop is pass one catching more before the final review.
No merge was reverted.

| Change size | Changes | Final review found a blocker or major |
|---|---|---|
| under 50 lines | 55 | 9% |
| 50–199 lines | 97 | 33% |
| 200–799 lines | 145 | 35% |
| 800+ lines | 110 | 38% |

By what a change touched: application code 25% (261 changes), scripts and
CI 41% (97), process documents, skills and agent files 51% (49). Process
text is where the reviewers found the most, so it should not get a lighter
review than code.

**Skills.** The project kept 31 skills holding about 180k tokens of how-to;
a run loaded about 6 of them, when needed. Counting every skill a run did not
load as context its requests would otherwise have re-read, had it all lived
in the always-loaded instructions, keeps about 10M tokens out of each run:
at least $503 over the month at the cheapest token price (cache reads), lead
session only. The largest savings came from long manuals that most runs did
not need.

## Failures that changed the process

Each of these happened, and each left a rule or a script behind.

- **A shell variable holding several paths, passed as one word, let an
  unreviewed draft reach main.** The guard compared one long string with
  the reviewed paths and matched none of them. The push guard now fails
  closed on anything it cannot parse, and the recipes write paths out.
- **A commit pushed without pass one failed the CI typecheck** and was
  caught only by the fresh review. Both passes now run the CI commands, and
  the orchestrator checks every builder report for them before pass one.
- **Scheduled runs hung on permission prompts** that nobody was there to
  answer. The permission gate hook now answers them in unattended runs,
  and an alarm fires when a prompt still waits.
- **The weekly usage limit ran out and every run failed for about 20
  hours,** including the checks that watch production. The usage guard now
  stops new work at a set share of the week and keeps the rest for those
  checks.
- **Nothing re-checked the cheap model's figures.** A research conclusion
  could rest on a misread number. The checker now re-reads every figure a
  conclusion rests on before the report stands.
