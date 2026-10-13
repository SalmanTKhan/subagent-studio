# Pass one in full

Skipped when `core.review.passes` is 1. The author of record is the
orchestrating session, which does not read the diff itself. It launches a
fresh `studio-core:reviewer-pass-one` briefed with the branch, `BASE..HEAD`,
the change's paths, this checklist and "What to look for" from
`reviewer-prompt.md`, reads its report, and has a fresh `studio-core:builder`
fix what it found. The fixes are committed and pushed, and pass two reads the
new `HEAD`.

A session working by hand, with no builder, reads its own whole diff as if
someone else wrote it and runs the checks itself.

## Before pass one: the builder reports
The pass-one reviewer is given no builder report. So the orchestrator first
reads every builder report line by line against `core.ci_commands`: each
command named, its result, the test counts. A command missing, unrun or red
goes back to a fresh builder, and pass one starts only once the list is
whole. Write the counts into the record beside `BASE` and `HEAD`.

## The checklist
Run on the change's own paths, never `git add -A` (other sessions and
builders share the trees).

1. **Secrets.**
   `git -C "$W" diff <BASE>..<HEAD> -- <paths> | grep -nEi 'xox[abp]-|hooks.slack.com|AKIA|BEGIN (RSA|EC|OPENSSH)|api[_-]?key\s*[:=]|ghp_|sk-[A-Za-z0-9]'`
   Any hit is a blocker until shown to be a placeholder.
2. **Blast radius and privacy.** Every write outside the repo stays within
   the tier the project allows; no personal data reaches a log, an error or
   a third party.
3. **Every `ci_command` ran.** Each entry of `core.ci_commands`, in order,
   green, in the builder reports or run by the reviewer in a scratch copy
   when no builder ran. A test for any bug the change fixes. A finding in a
   prompt or skill has no test; its proof is re-reading the fix against the
   finding's failure scenario. Two red main branches in two days once came
   from a check neither pass ran; a third from a runtime difference CI saw
   first, which is why the landing ends by reading CI.
4. **Scope.** A new dependency, permission, scope or cost is a line in the
   record; a cost goes wherever the project tracks money.
5. **Wording sweep.** A change that rewrites a rule's wording starts with a
   grep over the whole tree, and any live scheduled prompts, for the old
   wording and its variants, not with the files you remember. Every hit is
   fixed in the same change or named in the record as deliberately left.
   Historical records (decision logs, journals, done lists) stay as written.

## Template
```
Agent { subagent_type: "studio-core:reviewer-pass-one", run_in_background: false,
        model: <roles.reviewer-pass-one.model>,    # only when set
        effort: <roles.reviewer-pass-one.effort>,  # only when set
        description: "Pass one <task>",
        prompt: "Branch <T>, range <BASE>..<HEAD>, paths <paths>, repo <abs path>.
You are read-only. Run this checklist: <items 1 to 5>. Then look for:
<'What to look for' from reviewer-prompt.md>. Report findings with
severity, file:line, failure scenario and smallest fix, under 400 words." }
```
