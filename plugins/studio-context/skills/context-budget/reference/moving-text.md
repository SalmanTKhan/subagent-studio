# Moving text out of a file that is over budget

## The stub shape

A moved section leaves its heading and number behind, so every reference
to it still resolves, and one or two lines that say where it went and when
to open it:

```markdown
## 7. Release process
Moved verbatim to `docs/claude/07-release.md`: the version rules, the
changelog steps and the checklist, with their numbers. Read it before
tagging a release.
```

Say near the top of CLAUDE.md that it is in every request and is never read
again with a tool, and that its long sections live under
`docs/claude/` with their numbers, behind stubs that say when to open
them. A reference to a moved section number then means that file's section.

## What stays, what moves

Stays in CLAUDE.md: what binds every request (the non-negotiables, the
rules for every write, the operating model, the file map).

Moves out: tables and lists one kind of run reads, history, the as-planned
record next to an as-built one, long procedures that belong to one job.

## The same move elsewhere

| File | Budget idea | Where the detail goes |
|---|---|---|
| CLAUDE.md | under 32 KB | `docs/claude/NN-*.md` |
| state snapshot | one page, under 8 KB | `state/<area>.md`, opened when a task touches the area |
| task index | one line per task | `tasks/T-nnn.md`, opened when the task is picked; `tasks/done/` when closed |
| SKILL.md | under 8 KB, the procedure | `reference/*.md`, named by the procedure |

Prove every move with the check, naming the old file at the last commit and
the full new set:

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/check_moved_text.py \
  --old git:HEAD:STATE.md --new STATE.md state/*.md
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/check_moved_text.py \
  --old git:HEAD:.claude/skills/my-skill/SKILL.md \
  --new .claude/skills/my-skill/SKILL.md .claude/skills/my-skill/reference/*.md
```

## How the check matches

- Every non-blank line of the old text must appear, whitespace collapsed,
  in the new files joined with spaces. A re-wrapped paragraph still matches.
- A heading's `#`s, a list marker and a table's pipes are stripped first,
  and a trailing period, colon, semicolon or comma is not required.
- Markdown decoration (rules, table separators, fences) and lines shorter
  than `--min-chars` (default 8) are skipped.
- `--ignore <regex>` drops old lines you changed on purpose, such as the
  section body a stub replaced. Use it sparingly and say why in the commit.

A failed check prints `MISSING n of m lines` and each line. Put the text
back; never widen `--ignore` to make it pass.
