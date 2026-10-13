---
name: research-run
description: A phased, resumable research pipeline. One research-lead frames the question into gather blocks, cheap Haiku gatherers read live public pages in parallel with every figure carrying its URL and read date, a research-lead writes the report against a user rubric, and a fresh reviewer re-reads every figure a conclusion rests on. Use for a research run, a market or vendor comparison, "which library or vendor should we adopt", "is this market worth entering", a research plan, a fact-checked report, or resuming a research run from its log.
---
# Research run: frame, gather, write, check, close

The run finds and judges against a rubric the user wrote. The session that
runs this skill is the **host**: it launches agents, checks their reports,
commits their files and writes `log.md`. It reads no page and writes no
finding itself. Every agent is fresh: never continue an agent across
phases or blocks.

## 0. Config and paths
Read the config with the loader:
```
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/studio_config.py get research --format json
```
If Bash cannot see `CLAUDE_PLUGIN_ROOT`, the plugin root is two levels
above this skill's base directory.

- `research.out_dir` (default `research`): runs live in `<out_dir>/<slug>/`.
- `research.rubric` (default `research/rubric.md`): the criteria and
  thresholds. No rubric file: stop and tell the user, pointing at the
  kit's `templates/research/rubric.md`. Never invent criteria.
- `research.max_gatherers` (default 6): most gatherers at once.
- `research.browser` (default false): run phase 3.
- `roles.research-lead`, `roles.gatherer`, `roles.gatherer-browser` (falls
  back to `roles.gatherer`), `roles.reviewer`: when `model` or `effort` is
  set, pass them on the Agent call; otherwise the agent file decides.

`<slug>` is a short kebab-case name for the question, fixed at the start.
The run writes only `<out_dir>/<slug>/`: `question.md`, `research-plan.md`,
`facts/<block>.md`, `report.md`, `log.md`.

## 1. Start or resume
1. A `<out_dir>/<slug>/log.md` with no `phase=done` line: resume it. Read
   `log.md` and skip every phase whose file is committed. An existing plan
   or fact file is reused, never redone.
2. A new run: write the user's question verbatim to `question.md`, start
   `log.md` with `<ISO time> phase=start file=<slug>/question.md`, commit
   both by path.
3. Log line shape, one per event, time from `date -u +%Y-%m-%dT%H:%M:%SZ`:
   `<ISO time> phase=<start|frame|gather|browser|write|check|done> <what happened> file=<path|none>`

## 2. Frame (one research-lead)
- Skipped when `research-plan.md` is committed.
- Launch `studio-research:research-lead` with the framer's brief in
  `reference/framing.md`. It writes `research-plan.md`: candidates, the
  rubric's thresholds copied word for word, the questions per criterion,
  and gather blocks, each naming its sources and the exact figures wanted.
- Check the plan (`reference/framing.md`, "What the host checks"). A
  failed check gets one fix by a fresh research-lead. Commit, log
  `phase=frame`.

## 3. Gather (Haiku, in parallel)
- One fresh `studio-research:gatherer` per block with no fact file, briefed
  as `reference/gathering.md` says. Up to `max_gatherers` at once.
- **One scraper at a time against a single site.** Blocks that fetch from
  the same site in bulk run one after another; two at once drew HTTP 429.
  The plan names such blocks.
- Each report: check the file (`reference/gathering.md`), commit it by
  path, log `phase=gather file=facts/<block>.md`.
- A gatherer that returns nothing is relaunched once with the same brief.
  A second failure is logged and its questions become `not read`.

## 4. Browser read (only when `research.browser` is true)
- Trigger: any unmarked line under `## Needs a browser` in a committed
  fact file. One fresh `studio-research:gatherer-browser` reads them all
  and marks each line (`reference/gathering.md`, "The browser reader").
- Run this check again before the writer when resuming, so a session that
  died between the gather commits and the read loses no page.
- With `browser` false, those pages stay unread and the report names them.

## 5. Write (one research-lead)
- Launch `studio-research:research-lead` with the writer's brief in
  `reference/writing.md`. It writes `report.md` from the fact files only,
  against the rubric and the report shape. A figure no fact file sources
  is an unknown. A conclusion that fails a criterion is never a winner.
- Commit, log `phase=write`.

## 6. Check (one fresh reviewer)
- Launch a fresh `studio-core:reviewer` with the checker's brief in
  `reference/writing.md`. It is read-only and runs the five checks:
  1. re-fetches every figure a conclusion or criterion rests on;
  2. each threshold equals the rubric's, word for word;
  3. every section of the report shape is present;
  4. no winner on a failed or `not read` criterion;
  5. no private person is named.
- Log `phase=check check=<5 of 5 | n of 5, failed: <numbers>>`.
- A failed check gets one fix by a fresh research-lead with the findings
  verbatim, then one re-check. What still fails goes at the top of the
  report's "Unread sources" and into the close.

## 7. Close (`reference/close-and-failures.md`)
1. Every file committed by path. Push as the project pushes.
2. One short line out: if the studio-unattended plugin's notify script is
   installed, post one line with it; otherwise a summary to the user: the
   question, the verdict or "nothing passes" with the closest candidate,
   and any check still failing.
3. `phase=done file=<slug>/report.md` in `log.md`; commit it.

## 8. Never
- Sign in, open a page behind a login, fill a form, spend or post
  anywhere but the one close line.
- Write a private person's name, username or handle anywhere.
- Lower, round or reinterpret a rubric threshold.
- Present a winner on a failed or unread criterion.
- Type a figure without its URL and read date.
- Frame, gather or write in the host session, or read pages for a gatherer.
- `git add -A`: commit only the run's own paths.

## 9. Budget and why it is shaped this way
- **A full run:** 2 to 3 research-lead agents (framer, writer, and a fixer
  when a check fails), 4 to 9 gatherers, 1 checker, plus 1 browser reader
  when pages need it. A small run: 2 leads, 3 gatherers, 1 checker.
- **Over budget:** the writer writes what came in and names what was not
  read.
- **Gatherers are on Haiku** because reading is cheap and judging is not:
  the gatherer collects, the Opus writer judges.
- **The checker exists** because nothing else re-checked the cheap model's
  figures. It re-fetches the figures that decide the verdict, not all.
- **Each phase fits one session** and its state is in committed files, so
  any later session resumes from `log.md`.

## Reference files
| Open when | File | What it holds |
|---|---|---|
| Framing (2) | `reference/framing.md` | The framer's brief, the plan's shape, the host's checks |
| Gathering, browser read (3, 4) | `reference/gathering.md` | The gatherer's brief, the fact file, public-page rules, reading lessons, the browser reader |
| Writing, checking (5, 6) | `reference/writing.md` | The writer's brief, the report shape, the checker's brief and five checks, the fix |
| Commit, close, a failure (7) | `reference/close-and-failures.md` | Commit and push, the close line, every failure case |
