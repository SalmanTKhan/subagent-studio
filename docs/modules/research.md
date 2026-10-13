# studio-research

A phased, resumable research pipeline: one lead frames the question, cheap
gatherers read public pages in parallel, a lead writes the report against
your rubric, and a fresh reviewer re-checks the figures the verdict rests
on. Depends on `studio-core`, whose `reviewer` is the checker.

## What it adds

**Agents** (generated from `shared/agents/`):

| Agent | Model, effort | Tools | Job |
|---|---|---|---|
| `studio-research:research-lead` | opus, high | Bash, Read, Edit, Write, Grep, Glob, WebFetch, WebSearch | frames the research plan, writes the report from the fact files only, fixes after the check |
| `studio-research:gatherer` | haiku, high | Bash, Read, Edit, Write, Grep, Glob, WebFetch, WebSearch | runs one gather block; every figure with its URL and read date; never estimates or decides |
| `studio-research:gatherer-browser` | haiku, high | inherits every tool the session has | the same body, for pages that need a browser MCP server |

**Skill:** `research-run`. The phases, each resumable from the committed
files and `log.md`:
1. start or resume, with the question written verbatim;
2. frame: `research-plan.md` in gather blocks, the rubric's thresholds
   copied word for word;
3. gather: one fresh gatherer per block, in parallel, one at a time per
   site when scraping in bulk;
4. browser read (optional): the pages gatherers listed as needing one;
5. write: `report.md` from the fact files only;
6. check: a fresh `studio-core:reviewer` re-fetches every figure a
   conclusion rests on and runs five checks;
7. close.

Briefs, the fact file and report shapes, and every failure case are in
the skill's `reference/` files.

**Templates** (the kit's `templates/research/`): `rubric.md`,
`research-plan-template.md`, `report-template.md`.

No scripts beyond the config loader, no hooks.

## Config keys

| Key | Default | Meaning |
|---|---|---|
| `research.out_dir` | `research` | runs live in `<out_dir>/<slug>/` |
| `research.rubric` | `research/rubric.md` | the criteria and thresholds the run judges against; the run stops when it is missing |
| `research.max_gatherers` | `6` | most gatherers at once |
| `research.browser` | `false` | run the browser read with `gatherer-browser` |
| `roles.research-lead`, `roles.gatherer`, `roles.gatherer-browser`, `roles.reviewer` | unset | per-call `model` and `effort`; `gatherer-browser` falls back to `gatherer` |

## What it changes in your repo

Each run writes only `<out_dir>/<slug>/`: `question.md`,
`research-plan.md`, `facts/<block>.md`, `report.md` and `log.md`,
committed by path as it goes. You write the rubric once, from
`templates/research/rubric.md`.
