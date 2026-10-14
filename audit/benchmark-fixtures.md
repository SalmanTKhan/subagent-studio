# Benchmark fixture specification — v1

Status: candidate tasks, **not frozen and not executed**.

Use separate, immutable fixture repositories or commits. Each arm receives the same base SHA and the same task text. Never benchmark on a live production branch.

| ID | Tier | Task | Independent acceptance |
| --- | --- | --- | --- |
| S01 | Small | Add CSV export escaping for commas, quotes and newlines | Exact golden output and round-trip parse |
| S02 | Small | Reject invalid configuration enum values | Invalid fixtures fail with documented errors |
| S03 | Small | Fix Unicode path handling | Cross-platform fixture with non-ASCII names |
| S04 | Small | Add bounded retry for transient failures | Fake clock verifies attempts and backoff |
| M01 | Medium | Add paginated JSON endpoint | Contract, boundary and authorization tests |
| M02 | Medium | Add reversible schema migration | Forward/backward migration and data preservation |
| M03 | Medium | Implement undo/redo for two operations | State-machine property tests |
| M04 | Medium | Fix concurrency race in job queue | Deterministic concurrency regression |
| M05 | Medium | Add import with duplicate handling | Idempotency and malformed-input tests |
| L01 | Large | Implement persistent background job lifecycle | Crash/restart and recovery tests |
| L02 | Large | Refactor parser to typed intermediate representation | Compatibility corpus and differential tests |
| L03 | Large | Introduce cache with explicit invalidation | Property tests and stale-read regressions |
| L04 | Large | Implement offline state synchronization | Conflict-resolution and replay fixtures |
| H01 | Critical | Harden path authorization boundary | Traversal, symlink and TOCTOU adversarial cases |
| H02 | Critical | Make save writes crash-safe | Fault injection across write/rename/fsync |
| H03 | Critical | Validate merge provenance enforcement | Crafted Git DAGs and malformed metadata |

## Freeze criteria

Before collecting results, create each fixture with: repository URL or local fixture artifact; immutable SHA; runtime/dependency lockfile; task prompt; timeout; test command; expected acceptance; prohibited shortcuts; evaluator instructions; SHA256 of fixture package. Exclude tasks for which no independent oracle exists.

## Execution matrix

- Arm A: single Claude Code session without studio plugins.
- Arm B: studio-core plan/build/review using same allowed model and effort budget.
- Optional Arm C: studio-core + studio-context.
- Run at least two replicates per task/arm, randomized in order. Declare cache regime and reset semantics.
- Report intent-to-treat failures, not just completed tasks. Do not change fixtures after seeing results.
- Review quality with blinded evaluators and a fixed acceptance suite.
- Record subscription interruptions separately from API-equivalent usage.
