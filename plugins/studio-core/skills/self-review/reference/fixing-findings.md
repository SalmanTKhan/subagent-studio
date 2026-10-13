# Severity, fixing findings, and why there is no second round

## Severity (the gate)
- **Blocker:** could harm a user or their data, leak personal data or a
  secret, break production or CI, lose data in a migration, or break a rule
  the project marks non-negotiable. An unreviewed reviewed-path file riding
  along in the range is a blocker.
- **Major:** a wrong result on a path that can be reached, a guard or test
  that does not do what it claims, or a rule a session can follow to the
  wrong outcome.
- **Minor:** everything else that is a real defect. Style is not a finding.

## Fixing (the author, no second reviewer)
- **Blocker and major:** fixed on the review branch by a fresh
  `studio-core:builder`, each with a test that fails without the fix (a
  prompt or skill finding is re-read against its failure scenario instead).
  The orchestrator checks each fix: the test fails before and passes after,
  and the failure scenario no longer happens.
- **Rebut only with evidence.** A finding you think is wrong is rebutted with
  the command and its output that disproves it, written in the record and in
  the landing message.
- **An unfixable blocker keeps the branch off the main branch.** A blocker or
  major you can neither fix nor disprove that way stays off.
- **A fix changes only what its finding names.** A finding that needs a
  redesign (new source files other than the fix's tests, a new dependency, a
  changed migration, a different approach) is not fixed on this branch: the
  branch stays off the main branch, and the redesign is a new change with
  its own review.
- **Minor:** fixed if small, otherwise a task quoting it. A minor's fix may
  go to `studio-core:builder-sonnet` under skill `plan-then-build` §6 (judged,
  written out with its check, all four conditions). The orchestrator re-runs
  that check before it records `FIX`, because nobody reads it after; a fix
  that fails is redone by `studio-core:builder`.
- Commit the fixes by path on the branch and push. Record the last reviewed
  `HEAD` and the new tip `FIX`.

## No second review round
The fresh review is the last review. Its fix commits (`HEAD..FIX`) reach the
main branch without another reader, and the landing names them on a
`Fixed-after-review:` line, which `review_guard.sh audit` checks: the range
must start at the reviewed `HEAD` and end at the landed tip.

A merge of the main branch into the review branch after the review (to
resolve a conflict in a reviewed path) is part of that range too. Read it
first with `git show --remerge-diff <merge>`.

Why one round: rounds after the first fresh review found smaller and smaller
things for the time they took.

## Trailer formats
```
Reviewed-by: fresh reviewer agent, <BASE7>..<HEAD7>, 1 round (<b> blocker, <m> major, <k> minor; <f> fixed, <q> queued)
Fixed-after-review: author, <HEAD7>..<TIP7>, <n> fixes (<which findings, no commit ranges>)
```
`<BASE7>` is the first seven characters of the SHA. The docs-only path's
`Reviewed-by:` form is in `docs-only-path.md`.
