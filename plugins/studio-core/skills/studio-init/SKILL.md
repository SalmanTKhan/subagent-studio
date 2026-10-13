---
name: studio-init
description: Sets up a project for the studio plugins. Detects the language and check commands, proposes the reviewed paths, asks about review passes, landing and the push hook, writes .claude/studio.json, validates it, and adds a short marked block to CLAUDE.md. Run it by hand once per project, and again to change the answers.
disable-model-invocation: true
---
# Set up a project

Run from the project's root. Change nothing until the user has answered.

**Script paths.** `${CLAUDE_PLUGIN_ROOT}` is replaced with the plugin's
directory when this skill loads. If it shows unreplaced, the plugin root is
two levels above this skill's base directory. In a copy-in install the
scripts are under `scripts/studio/`.

## 1. Read what is there
```bash
cd "$(git rev-parse --show-toplevel)" && ls -a && test -f .claude/studio.json && cat .claude/studio.json
```
An existing `.claude/studio.json` is the starting point: keep every section
and key the user set, and change only what the answers below change.

## 2. Detect the check commands (propose `core.ci_commands`)
Look only at files that exist, in this order, and keep commands the project
already defines:
- **`package.json`:** read its scripts with
  `python3 -c "import json; print(list(json.load(open('package.json')).get('scripts', {})))"`.
  Use the runner its lockfile names (`pnpm-lock.yaml` pnpm,
  `yarn.lock` yarn, `bun.lockb` bun, else npm). Propose `<runner> run lint`,
  `<runner> run typecheck`, `<runner> test`, `<runner> run build` for each
  script that exists, in that order.
- **`pyproject.toml`, `setup.cfg`, `tox.ini`:** `ruff check .` when ruff is
  configured or listed; `mypy <package dir>` when mypy is; `python -m pytest -q`
  when pytest is or a `tests/` directory exists.
- **`Makefile`:** the targets among `lint`, `typecheck`, `check`, `test`
  (`grep -E '^(lint|typecheck|check|test):' Makefile`), as `make <target>`.
  Prefer these over the language defaults when they exist.
- **`go.mod`:** `go vet ./...`, `go test ./...`.
- **`Cargo.toml`:** `cargo clippy --all-targets -- -D warnings`, `cargo test`.
- A CI workflow (`.github/workflows/*.yml`) that runs other commands: show
  them and prefer what CI runs.
Nothing found: propose an empty list and say the builders will then have no
checks to run.

## 3. Propose `core.review.reviewed_paths`
The top-level directories that hold code, plus the files that change how it
builds or runs:
```bash
git ls-files | awk -F/ 'NF>1 {print $1}' | sort -u
git ls-files | grep -E '\.(py|js|jsx|ts|tsx|mjs|cjs|go|rs|java|kt|rb|php|cs|c|cc|cpp|h|swift|sh|sql)$' | awk -F/ '{print (NF>1 ? $1 : $0)}' | sort | uniq -c | sort -rn
```
Propose every top-level directory with code files, plus those present of
`.github`, `.claude`, `CLAUDE.md`, `package.json`, the lockfile,
`pyproject.toml`, `go.mod`, `Cargo.toml`, `Makefile`, `Dockerfile`.
Everything else counts as plain docs.

## 4. Ask
Use the AskUserQuestion tool when it is available; otherwise ask in one
message and wait. Ask together:
1. **The checks and paths:** confirm or edit the lists from steps 2 and 3.
2. **Review passes:** `2` (pass one by a reviewer with the author's
   checklist, then one fresh reviewer; recommended) or `1` (the fresh
   reviewer only).
3. **Landing:** `merge-no-ff` (the session lands reviewed work itself with a
   merge commit; for solo projects) or `pr` (the session opens a pull request
   carrying the review trailers; for teams).
4. **Push hook:** on (a hook refuses `git push` to the main branch when an
   unreviewed commit would go with it) or off.
Also confirm the main branch
(`git symbolic-ref --short refs/remotes/<remote>/HEAD | sed 's#^<remote>/##'`
gives it, with `<remote>` the remote's name, usually `origin`) and the
remote when they are not `main` and `origin`.

## 5. Write and validate
Write `.claude/studio.json` with the answers under `core`:
```json
{
  "core": {
    "main_branch": "main",
    "remote": "origin",
    "ci_commands": ["<command>", "<command>"],
    "review": {
      "passes": 2,
      "reviewed_paths": ["src", ".github", ".claude", "CLAUDE.md"],
      "land": "merge-no-ff",
      "push_hook": false
    }
  }
}
```
Merge into an existing file instead of replacing it. Then:
```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/studio_config.py validate && echo valid
```
Fix and rerun until it prints `valid`. Per-role `model` and `effort`
(`roles.<role>`) are optional; mention them, do not ask.

## 6. The CLAUDE.md block
Add, or replace, only the text between the two markers. Never touch any
other line. Create `CLAUDE.md` when there is none. Write the block to a
scratch file first, then:
```bash
python3 - CLAUDE.md <block file> <<'EOF'
import sys, os
path, block_path = sys.argv[1], sys.argv[2]
begin, end = "<!-- subagent-studio:begin -->", "<!-- subagent-studio:end -->"
block = begin + "\n" + open(block_path).read().strip() + "\n" + end
text = open(path).read() if os.path.exists(path) else ""
if text.count(begin) > 1 or text.count(end) > 1 or (begin in text) != (end in text):
    sys.exit("markers are broken; fix CLAUDE.md by hand")
if begin in text:
    i, j = text.index(begin), text.index(end) + len(end)
    text = text[:i] + block + text[j:]
else:
    text = text.rstrip("\n") + ("\n\n" if text else "") + block + "\n"
open(path, "w").write(text)
EOF
```
The block (keep it this short):
```
## How this project uses subagents
- The main session coordinates; fresh agents do hands-on work (skill
  `orchestrator-rules`). It never edits code, runs tests, reads diffs or
  deploys, and reads `git diff --stat` only.
- Big work starts with a plan (skill `plan-then-build`); each step goes to a
  fresh `studio-core:builder`.
- Changes to <reviewed paths> reach <main> only through skill `self-review`:
  <passes> review pass(es), landed by <merge-no-ff | pull request>.
- Lookups go to `studio-core:searcher`. Agent reports stay under 400 words.
- Config: `.claude/studio.json`.
```

## 7. Report
Tell the user what was written, the validate result, whether the push hook
is on, and that `.claude/studio.json` and `CLAUDE.md` go through the review
they just configured when they next change.
