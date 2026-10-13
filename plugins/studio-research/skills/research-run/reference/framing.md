# Framing: the framer's brief, the plan's shape and the host's checks

Open when launching the framer or checking its plan (SKILL.md section 2).
The framer is one fresh `studio-research:research-lead`. It plans the
research and decides no winner.

## The launch
```
Agent { subagent_type: "studio-research:research-lead",
        description: "Research <slug>: frame",
        prompt: <the brief below>,
        model/effort: from roles.research-lead when set }
```

## The framer's brief (paste, with the fields filled in)
```
You are the framer of the research run <slug> (skill research-run). You write the research plan. You decide no winner, and you fetch a page only to confirm that a source the plan names exists.

Tree: <repo root>. You write one file: <out_dir>/<slug>/research-plan.md. You never commit, stage, push or post; the host commits your file. This prompt names the tree you write in, and it wins over your agent file.

Read, in this order:
1. <out_dir>/<slug>/question.md (the question, verbatim from the user)
2. <rubric path> (the criteria and their thresholds: copy them word for word, never lower one)
3. <plan template path, if it exists> or the plan's shape in this file
4. <this skill's base directory>/reference/framing.md (the plan's shape and rules) and reference/gathering.md (what a gatherer can and cannot read)

Public pages only: nothing behind a login, no sign-in, no spend, no post. Report in under 300 words: the path, the candidates, each block with its minutes and its sources, and any question the public pages cannot answer.
```
The plan template is `research-plan-template.md` in the rubric's
directory when the user put one there (the kit ships one in
`templates/research/`); otherwise the shape below, which is the same.

## The research plan's shape
```
# Research plan: <slug>
Question: <slug>/question.md · Rubric: <rubric path> · Scope: full | small · Framed: <date>
```
**1 Candidates.** One row each: an id (`C1`, `C2`), what it is, and
whether it came from the question or was added, with the reason.

**2 Thresholds.** Every criterion of the rubric with its threshold copied
word for word, and the figures it needs. A criterion the rubric leaves
open to reading is quoted, and the plan says which figure answers it. It
never re-words or lowers a threshold.

**3 Questions.** For each candidate and each criterion: the question; the
figure that answers it; the exact source (a URL, a search term, a
command); the block that reads it.

**4 Blocks** `B1` to `Bn`. Each block carries:
- a title and a slug; its file is `facts/<slug>.md`;
- the candidates and the questions of 3 it answers;
- the exact pages, searches and commands, in order;
- `bulk fetch from <site>: yes | no`. Blocks that fetch in bulk from the
  same site never run at once;
- the stop rules of 5 that apply to it;
- its minutes, under 60.

Rules: a full run has 4 to 9 blocks, a small run 3. Name which block runs
first and which run beside it.

**5 Stop rules.**
- A candidate that fails a criterion the rubric marks as a knock-out on
  its first read is dropped before the costlier reads. It keeps its row,
  with the criterion and the figure that dropped it.
- A paginated list sorted by last activity stops on last activity, never
  on creation date (`reference/gathering.md`, "Reading lessons").

**6 Data that would change the verdict.** Each figure that would flip a
criterion, with its source and the block that reads it.

## What the host checks before gathering
- Every block names its pages and commands, and its minutes are under 60.
- Every rubric threshold appears in section 2 word for word: compare them
  with `grep -F` on each threshold line, never by eye.
- Every question of section 3 belongs to a block.
- No two blocks fetch in bulk from the same site at once.

A plan that fails a check gets one fix: a fresh research-lead with the
host's findings verbatim, editing only what they name. If it still fails,
the host notes it in `log.md` and gathers with the plan as it is; the
writer names the gap.
