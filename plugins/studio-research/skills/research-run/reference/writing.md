# Writing and checking: the writer's brief, the report shape, the checker and the fix

Open when launching the writer or the checker, or fixing what the checker
found (SKILL.md sections 5 and 6). The writer is one fresh
`studio-research:research-lead`; the checker is one fresh
`studio-core:reviewer`.

## The writer's launch
```
Agent { subagent_type: "studio-research:research-lead",
        description: "Research <slug>: write",
        prompt: <the brief below>,
        model/effort: from roles.research-lead when set }
```

## The writer's brief (paste, with the fields filled in)
```
You are the writer of the research run <slug> (skill research-run). You turn the gatherers' facts into the report. You write from their fact files only: a figure they did not read is an unknown under "Unread sources", never fetched by you and never estimated.

Tree: <repo root>. You write one file: <out_dir>/<slug>/report.md. You never commit, stage, push or post; the host commits. This prompt names the tree you write in, and it wins over your agent file.

Read: <slug>/question.md, <rubric path>, <slug>/research-plan.md, every file in <slug>/facts/, <report template path, if it exists>, and <this skill's base directory>/reference/writing.md (the report shape, and the five checks the checker runs on your file).

Judge each criterion exactly as the rubric writes it, with its threshold copied word for word. A criterion with no figure read is "not read", never a pass. A candidate that fails or has not read a criterion is never the winner. Plain short sentences, no em or en dashes. Never a private person's name. Report in under 300 words: the path, the verdict or "nothing passes" with the closest candidate, the criteria that decided it, and the unknowns.
```
The report template is `report-template.md` in the rubric's directory
when the user put one there (the kit ships one in `templates/research/`);
otherwise the shape below, which is the same.

## The report shape
```
# <the question, in one line>
Question: <slug>/question.md · Rubric: <rubric path> · Facts: <slug>/facts/*.md, read <first date> to <last date> · Written: <date>
```
1. **Question.** The user's question, verbatim, and the candidates.
2. **Method.** What was read, by which block, on which dates; the
   commands used; what the budget or a stop rule left out.
3. **Findings per criterion.** A sub-heading per criterion. Under each, a
   table: `| Candidate | Figure | Source (URL, read date) | Threshold | Result |`,
   the threshold copied from the rubric word for word and the result
   `pass`, `fail` or `not read`. A failed criterion is recorded as failed.
   An argument that its purpose still holds may follow as a note; it
   never changes the result.
4. **Verdict.** The candidate that passes every criterion, with the one
   line that decides it among several passers (the rubric's tie-break if
   it has one). With no passer: `Nothing passes.`, then the closest
   candidate and what would have to change.
5. **What would change the verdict.** Each figure that would flip a
   criterion, its current value and source, and the value that flips it.
6. **Unread sources.** Any check still failing after the fix (at the
   top), every criterion `not read`, every page `not readable on <date>`,
   every `Needs a browser` page left unread, what the budget cut.
7. **Sources.** Every URL with its read date, one per line, grouped by
   fact file.

A section with nothing to say keeps its heading and says `none` and why.

## The checker's launch
```
Agent { subagent_type: "studio-core:reviewer",
        description: "Research <slug>: check",
        prompt: <below>,
        model/effort: from roles.reviewer when set }
```
```
You are the checker of the research run <slug> (skill research-run). You are read-only: you write nothing and fix nothing, and you review the files in the tree, not a commit range. Tree: <repo root>. This prompt wins over your agent file. Run the five checks of <this skill's base directory>/reference/writing.md on <slug>/report.md and every file in <slug>/, against the rubric <rubric path>. Report in under 300 words: each check with pass or fail, and for each fail the file, the line numbers and what is wrong. Give a name the name check finds by its line number, never quoted.
```

## The five checks
1. **Every figure a conclusion rests on is re-read.** Each figure in
   every section that carries one (Findings, Verdict, What would change
   the verdict, and any other) traces to a fact file row with a URL and a
   read date. A figure with no row fails the check. For each figure a criterion's pass or fail rests on, the checker
   fetches the row's URL itself and confirms the value. A mismatch fails
   the check. A row read in a browser, which WebFetch cannot open, is
   named in the report as not re-read. The gatherers run on a cheap model;
   this is the only place their figures are checked.
2. **Thresholds word for word.** Each threshold in the plan and the report
   equals the rubric's. Compare with `grep -F` per threshold, not by eye.
3. **Every section of the report shape is present,** in order.
4. **No winner on a failed criterion.** The verdict's pick passes every
   criterion in Findings as written. `not read` is not a pass.
5. **No private person is named.** Read every row sourced from a forum,
   a review or a comment for names, usernames and handles. When a fetch
   cached personal-name fields (a review's author, a post's poster), grep
   the run's files for each cached name with word boundaries and judge
   each hit: an ordinary word that happens to be a name is not a finding.

## After the check
- The host logs `<ISO time> phase=check check=<5 of 5 | n of 5, failed: <numbers>>`.
- **A failed check gets one fix,** by a fresh research-lead with the
  checker's findings verbatim, editing only what they name:
  - a figure with no source or a mismatch: the fact file's value and
    source, or the figure moved to Unread sources as unknown, and the
    criterion marked again;
  - a threshold that differs: the rubric's restored, the criterion marked
    again from the facts;
  - a missing section: its heading, with `none` and why;
  - a winner on a failed criterion: the pick withdrawn, the Verdict reads
    `Nothing passes.` with the closest candidate;
  - a name: removed, the sentence kept without it.
- Then the checker runs once more. A check still failing goes at the top
  of Unread sources and into the close line. When check 4 still fails, the
  close recommends nothing and says the finding needs another look.
