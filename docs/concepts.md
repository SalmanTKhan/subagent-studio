# Concepts

The kit rests on six ideas. Each one came from something that went wrong
when the work was done another way. The failures are told here without the
project's details; the skills' `reference/why.md` and reference files hold
the full reasoning.

## 1. One agent type per role

Each role is its own agent file: `builder`, `builder-sonnet`, `reviewer`,
`reviewer-pass-one`, `planner`, `planner-max`, `searcher`, and in the
research plugin `research-lead`, `gatherer` and `gatherer-browser`. The
frontmatter fixes the model, the effort level and the tool list. The body
holds only the rules that role needs.

**What it fixes.** A general-purpose agent carries every tool schema the
session has, and an agent's tool list is loaded on every one of its
requests. A builder launched as a general-purpose agent once started near
80k tokens of context; the same builder as a lean type with 5 to 8 tools
started near 20k. Most of the difference was tool schemas it never used.

A type also holds a role in place. A reviewer with no Edit or Write cannot
"just fix it" and blur who wrote what. A searcher that has only read tools
cannot drift into deciding.

Pairs share one body. `builder` and `builder-sonnet` differ only in model
and effort, as do `reviewer` and `reviewer-pass-one`, and `planner` and
`planner-max`. The bodies live once in `shared/agents/` and
`tools/build_agents.py` writes every agent file from them, so a rule
changed in one twin cannot be forgotten in the other.

**Which builder.** `builder-sonnet` takes a step only when four conditions
hold: the files are named, the behaviour is given, the acceptance is a
command, and nothing in it touches what a user sees, money, personal data,
a migration or security. It stops and reports anything not written down
instead of deciding it. A Sonnet step that fails goes to `builder`, never
to a second Sonnet run.

## 2. The orchestrator never touches code

The main session is re-read on every request, so its context is the
largest cost of a run. It picks, briefs, reads reports, decides and runs
the branch and landing git commands. It does not edit code, run a test
suite, read a diff or deploy, and it reads `git diff --stat` instead of
the diff. Every hands-on step is a fresh agent with a written brief and a
report under 400 words. An agent is never continued into the next step.

**What it fixes.** A session that does the work itself grows its context
with every file it reads and every test log it prints, and it pays for that
on every later request. It also checks its own work against its own
understanding, which is where mistakes hide. Skill `orchestrator-rules`
holds the rules and the table of which type does which work.

## 3. Plan first for big work

Big work (a new module or service, a feature that spans more than one
session, anything touching money, the data model, authentication, personal
data, a public API or a new external service) starts with a read-only
planner. The plan comes back in a fixed shape: goal, what was read, the
constraints, numbered steps each with Files, Does, Acceptance, Risk,
Parallel with and Model, then out of scope, risks and open questions. The
session saves it to `plans/<slug>.md` and commits it before the first
builder starts. When the work ships, an `## Outcome` section records what
landed and what differed.

**Which planner.** Work that is hard to reverse, or both complex and
critical, goes to `planner-max`: a new app's architecture, a shared
library's design, a data model from scratch. Everything else, every
re-plan and every amendment goes to `planner`. Today both run the same
model; the split exists so the expensive end can move to a stronger model
on its own. The test is two questions: if this plan were wrong, would we
rebuild an app or a shared library? Is the work both hard to get right and
harmful to get wrong?

**What it fixes.** A big task without a plan sprawls across sessions and
each one re-decides what the last one decided. A plan with a checkable
acceptance line per step lets a fresh agent take each step, and lets the
orchestrator check it without re-reading the code. After two failed
acceptances on a step, or when an outside system refuses the approach, the
work is re-planned rather than pushed through.

**Checking a step.** A builder's report is evidence, not proof. The step
is checked by a fresh read-only reviewer that re-proves the acceptance
outside the builder's own suite, makes a guard that should fail actually
fail, checks the expected fixtures were not edited, reads the diff and
answers the questions the report raised.

## 4. Two review passes and an enforced landing

The rule: unreviewed code never sits on the main branch, locally or on the
remote. A change lives on a review branch in its own worktree until a
fresh agent that did not write it has read it.

- **Pass one** is the author's own checklist: a secrets grep, blast radius
  and privacy, every CI command run and green with a test for any bug
  fixed, any new dependency or cost recorded, and a grep across the tree
  for a rule whose wording changed. It runs as a fresh
  `reviewer-pass-one`, so the orchestrator still never reads the diff.
- **Pass two** is one fresh `reviewer`, launched once per change when the
  branch is whole, on `BASE..HEAD` SHAs written down beforehand. Its first
  command is `git diff --stat` over the range: a reviewed file in the stat
  that the change did not list is a blocker. It reads any merge in the
  range with `git show --remerge-diff`.
- **Severities.** A blocker could harm a user or their data, leak a secret,
  break production or CI, or break a non-negotiable rule. A major is a
  wrong result on a reachable path, or a guard or test that does not do
  what it claims. Everything else that is a real defect is a minor. Style
  is not a finding.
- **Fixes.** Blockers and majors are fixed on the branch, each with a test
  that fails without the fix, or rebutted with a command and its output.
  One that can be neither fixed nor disproved keeps the branch off main.
  There is no second fresh review: the fixes are named on the landing.
- **Landing.** A `--no-ff` merge onto the remote's main, pushed from the
  worktree, never from the shared tree and never after a rebase. Its
  message carries `Reviewed-by:` with the reviewed range and
  `Fixed-after-review:` with the fix range.

Three things enforce it:

- `review_guard.sh push` refuses a push when a local commit on main that
  the remote lacks touches a reviewed path.
- The optional hook (`core.review.push_hook`) runs that guard on every
  `git push` to main the session tries, so the rule holds in the harness
  and not only in the prompt.
- `review_guard.sh audit <from>` walks main's first-parent history and
  names every commit touching a reviewed path that is not a landing merge
  whose trailers cover exactly what it brought in. It re-merges each
  landing's parents with `git merge-tree` to catch a hand-resolved conflict
  in a reviewed path.

**The failures behind it.**
- Fresh reviewers kept finding what the author could not: in one session
  they found several majors in code the author had already pushed, and
  blockers in each of the first two drafts of this very rule.
- Reviewing each plan step separately once roughly doubled the reviewer
  count per landing with no extra findings that mattered. Now there is one
  fresh reviewer per change, and step checks are separate, cheaper proofs.
- A reviewer that reads a branch name reads whatever the branch is when it
  looks. Fixed SHAs make what was read and what landed comparable.
- A commit made with `git add -A` carried unrelated files into a reviewed
  range. Commits are made by path, and the ride-along stat is a blocker.
- A shell variable holding several paths, passed as one word, let an
  unreviewed draft reach main: the guard compared one long string to the
  reviewed paths and matched nothing. The guard now fails closed on
  anything it cannot parse.
- A commit pushed without pass one failed the CI typecheck and was caught
  only by the fresh review. Both passes now run the CI commands.
- A review copy that linked another tree's dependency folder, then ran an
  install, emptied the other tree. Reviewers install only inside their own
  scratch copy.

**Rounds.** Rounds after the first fresh review found smaller and smaller
things for the time they took, so there are two passes and no third.

## 5. Cheap models read and never judge

`searcher` (Haiku) answers lookups: where a symbol or rule lives, which
files mention something, a count from a log, reported as `path:line` with
quotes and the command behind each count. In the research plugin,
`gatherer` (Haiku) reads public pages and writes fact files where every
figure carries its URL and read date.

Neither one builds, reviews, plans or decides. In research, an Opus
`research-lead` writes the report from the fact files alone, and a fresh
`reviewer` then re-fetches every figure a conclusion rests on.

**What it fixes.** Reading is cheap and judging is not, so the split puts
each on the model that suits it. But nothing re-checked the cheap model's
figures at first, and a conclusion can rest on a figure that was misread.
The checker now re-reads those figures before the report stands.

## 6. Context is a budget

Every request re-reads the whole context. Most of it is served from the
prompt cache, but cached reads still count against usage, so the cost of a
run is roughly its context size times its request count. A file loaded into
every request is paid for on every request of every session and agent.

So the files every run loads have byte budgets (`context.budgets`):
`CLAUDE.md` 32000, the state file 8000, the task index 16000, each
`SKILL.md` 8000, each agent file 6000. When a file goes over, text moves out
word for word into `docs/claude/NN-<slug>.md` (or a skill's
`reference/`, or a task's own file), behind a stub that says where it went
and when to open it. Nothing is deleted. `check_moved_text.py` proves that
every non-blank line of the old file appears in the new set.

**What it fixes.** Without budgets the always-loaded files grow a little
with every lesson until each request carries a long history nobody needs
that turn. Cutting text to fit loses rules that were learned the hard way.
Moving it keeps the rule and drops the cost from runs that do not need it.

**Measuring.** `token_usage.py` reports tokens per run type per day and
flags a run type whose per-run average doubled. `effort_check.py` checks
that scheduled runs and agents really ran at the effort level they were
meant to: a run was once seen dropping back to the default after a
background agent's notice.

## The unattended layer

`studio-unattended` adds what scheduled runs need on top of these ideas: a
lock so runs never overlap, a task queue whose index stays short, a journal,
one short notification per run, a `NEEDS HUMAN` format for the only three
things a run cannot do itself (money, a human's own login or signature, a
stop), and two guards that came from outages:

- Scheduled runs hung on permission prompts nobody could answer. The
  permission gate hook now answers them in unattended runs, and an alarm
  fires when one still waits.
- The weekly usage limit ran out, and every run failed for about 20 hours,
  including the checks that watch production. The usage guard now stops
  new work at a set share of the week (`unattended.usage_guard_pct`,
  default 85) and keeps the rest for those checks.
