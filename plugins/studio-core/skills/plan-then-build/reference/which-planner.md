# Which planner plans it, in full

Both planners return the same plan shape into the same file. The split puts
the most care where a wrong plan costs the most.

## `studio-core:planner-max`
- **A new app or service:** its plan carries the architecture and the build
  steps to its skeleton. Always `planner-max`, never `planner`.
- **Core architecture that is hard to reverse:** an engine the code is built
  around, a shared library's design that several apps import, a new stack, a
  data model designed from scratch.
- **A module or task that is both complex and critical.**
  - Complex: many parts that interact, concurrency or ordering, state that
    must stay consistent, a hard algorithm, or a change to live data.
  - Critical: a mistake would harm a user, lose or corrupt data, make a
    legal document wrong, or weaken production or security.
  - Complex but harmless, or critical but simple, is `planner`'s.

## `studio-core:planner`
- Every other big feature: work inside an existing app on its existing
  architecture (a migration, a new document type, a billing change inside
  the existing plans, a new extension, a new flow).
- Infrastructure and security configuration; a legal, compliance or security
  review and its fixes.
- Every re-plan and amendment, with one exception: a re-plan that changes
  architecture a `planner-max` plan set goes back to `planner-max`.

## When unsure
When unsure whether it is a new app, `planner-max` plans. For anything else,
when unsure, `planner` plans. The test for `planner-max` is two questions:

1. If this plan were wrong, would we rebuild an app or a shared library?
2. Is the work both hard to get right and harmful to get wrong?

A yes to either is `planner-max`.

**Calibration examples.**
- `planner-max`: a tax and legal rules engine; a document renderer and the
  choice of its engine; a shared library several apps import; handing out a
  legally required sequential number under concurrent clicks; the deny
  policies on a production sign-in.
- `planner`: credit notes on an existing numbering; a compliance review; one
  new rule and one new column.

## Typical Sonnet steps (plan-then-build §6)
Unit tests for cases the plan lists; a test added to an existing suite;
strings and translations from a given table; a fixture file; a rename across
files; a docs page from an outline; a mechanical move of text between files.
A read-only proof ("run this, report the figures") runs on the `reviewer`
type, with `model: "sonnet"` on the call when it meets the four conditions.

A judged minor finding's fix, written out with its check, is Sonnet's when
all four conditions hold and it is none of the never-Sonnet list. The
orchestrator has that check re-run before it records the fix tip; a fix that
fails it is redone by `studio-core:builder`.
