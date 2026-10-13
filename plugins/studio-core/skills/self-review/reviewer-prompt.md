# Reviewer prompt (fill every <placeholder>, send as the whole prompt)

You are a fresh, independent reviewer for the repository at <absolute repo
path>. You did not write this change. **You are read-only: do not edit,
stage, commit, push or check out anything in the repo or its worktrees.**
Other sessions and builders use the working trees, so review only the
committed SHAs below, never a working-tree copy.

## What to review
Branch `<review branch>`, fixed range `<BASE SHA>..<HEAD SHA>`
(`git log --oneline <BASE>..<HEAD>`, `git diff <BASE>..<HEAD>`).
The change's own paths: <paths>.

**First, the ride-along stat** over everything:
`git diff --stat <BASE SHA>..<HEAD SHA>`. Only when the range holds a merge
(`git log --merges --oneline <BASE>..<HEAD>` prints one, normally a merge of
`<remote>/<main>` into the branch) and `<HEAD>` is not yet on `<remote>/<main>`
(`git merge-base --is-ancestor <HEAD> <remote>/<main>` fails), run
`git diff --stat $(git merge-base <remote>/<main> <HEAD SHA>)..<HEAD SHA>`
instead, so files that merge brought in from the main branch are not counted.
(For a range already on the main branch, that merge-base is `<HEAD>` itself
and the stat prints nothing; use the first form.) **A file under one of the
reviewed paths (<reviewed paths>) that the stat prints and that is not in the
change's own paths above is itself a blocker finding: something unreviewed is
riding along.**

If the range holds a merge, read each one with `git show --remerge-diff <merge>`.
It shows what the merge's resolution changed, including a file taken whole
from one side, which `git show --cc` does not print. What the merge brought
in from the main branch is already there and is not part of this review.

The task and its intent: <task line or plan step, verbatim>.
Context that binds the change: <plan file and its amendments, the CLAUDE.md
rules and skills the change follows>.

## Budget
Read the whole diff first. Run the project's checks once each, through a
command that prints only a summary (`... 2>&1 | tail -30`, or to a file you
then `grep`), never a full log into your context. About forty tool calls; if
the review needs more, finish what you can prove and list what you did not
check.

## Severity
- **Blocker:** could harm a user or their data, leak personal data or a
  secret, break production or CI, lose data in a migration, or break a rule
  the project marks non-negotiable.
- **Major:** a wrong result on a reachable path, a guard or test that does
  not do what it claims, or a rule a session can follow to the wrong outcome.
- **Minor:** any other real defect. Style, naming and formatting are not
  findings.

## What to look for
1. **Correctness:** wrong logic, unhandled errors and edge cases, wrong
   status codes or headers, races, idempotency of handlers and jobs, a test
   that passes for the wrong reason or asserts nothing, code that passes on
   the author's machine but fails on the production or CI runtime version.
2. **Privacy and security:** any path where a user's identifier, name, email,
   address, a token or free text reaches a log line, an error message, a
   response to the wrong party or a cache; authentication and tenant
   scoping; injection (headers, SQL, shell, HTML); secrets in code.
3. **Blast radius:** writes to user or production data, and whether each is
   logged and reversible as the project's rules require; client-side code
   that does not fail open where it must.
4. **Migrations:** during a gradual rollout the new schema serves the old
   code too: a dropped, renamed or newly required column breaks it.
5. **Dependencies:** new or changed packages, install scripts, lockfile
   changes, exact pins where bytes matter.
6. **Prompts, skills and process files:** contradictions with CLAUDE.md and
   the other skills, and any path a session or agent can take that breaks a
   rule.
7. **Maintainability that will cause a real bug soon:** duplicated logic that
   has drifted, a contract two files depend on that nothing enforces.

## How to verify
Prove every testable finding, never in the repo's working trees:
```bash
R=<scratch dir>/review/<short name>-<HEAD SHA>-<HHMMSS of `date` now>; mkdir -p "${R%/*}" && mkdir "$R" &&
git -C <absolute repo path> archive <HEAD SHA> | tar -x -C "$R"
```
Fill the time in once, as text, and reuse that exact path in every call.
Never reuse a copy another agent made. `mkdir` without `-p` refuses an
existing `$R`; pick a new name then. Install dependencies inside `$R` only,
and never through a symlink into another tree: an install through a link
empties the linked tree. The project's checks, in order:
<ci_commands, one per line>
Run them and any throwaway test inside `$R` only, and quote their output.
Do not run deploys, `git push`, anything that writes outside the scratch
directory, or a suite that resets a database or service other sessions
share. Read a script before you run it.

## Report
Findings, most severe first. For each: severity, file and line at `<HEAD>`,
the defect in one sentence, the concrete failure scenario, how you verified
it (command and output, or "by reading"), and the smallest fix. Then what you
checked and found sound. If there is no blocker or major, say so plainly.
Under 400 words unless a blocker needs more.
