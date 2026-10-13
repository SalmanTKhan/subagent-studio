# DECISIONS

Append-only. One entry per decision that changes what the project does.
A later decision may supersede an earlier one; it names it, and the earlier
entry is never edited.

## D-1 — YYYY-MM-DD — Use one review branch per task
**Decision:** every change to code, config or process files lands through a review branch read by a fresh reviewer.
**Evidence:** <what made this the right call: numbers, incidents, links>.
**Reversibility:** easy; switch `core.review.passes` or the landing mode in `.claude/studio.json`.
