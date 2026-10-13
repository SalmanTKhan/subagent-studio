# Milestone 1 — Benchmark and security assessment

Status: protocol and audit scaffold; **no benchmark runs or security tests have been executed**.

## Objectives
1. Reproduce task-level compute and correctness measurements under controlled configurations.
2. Audit installation, hooks, Git landing controls, and unattended permission handling.
3. Fix confirmed high-severity findings before enabling unattended execution.

## Benchmark protocol
- Compare baseline Claude Code (single session) against studio-core, and optionally studio-core + context.
- Use 12–20 frozen tasks, stratified across small (<50 changed lines expected), medium, large, and high-risk changes. Record fixture commit SHA and acceptance criteria before starting.
- Randomize execution order; run each task in a fresh checkout/worktree with identical dependencies and clean caches or explicitly measured cache conditions.
- Pin Claude Code version, model, effort, tool permissions, environment, task instructions, and wall-clock/usage budgets. Record all deviations.
- Preserve raw session transcripts securely; redact secrets before publishing.
- Count all orchestration and subagent usage, including input, output, cache reads/writes, retries, reviews and repair rounds.
- Measure independently accepted tasks, escaped defects, CI results, wall time, intervention count, and API-equivalent compute cost. Do not equate API-equivalent cost with subscription charges.
- Require independent evaluator to inspect tests, diff and runtime behavior without knowing the arm.
- Report paired task results, medians, uncertainty, failures, and task exclusions. Do not infer causal model gains from historical before/after comparisons.

## Security audit scope
| Area | Threat to test | Required evidence |
| --- | --- | --- |
| install.sh / uninstall | Arbitrary writes, path traversal, overwrite, incomplete rollback | Temporary-repo tests, filesystem diff |
| Hook registration | Unsafe merge with existing hooks, executable trust, shell injection | Malicious path/config fixtures |
| Permission gate | Unexpected unattended command approval, prompt bypass | Denylist/allowlist adversarial tests |
| review_guard.sh | Fail-open, unreviewed changes, malformed trailers/path parsing | Positive and negative fixture history |
| Git landing | Direct push, force push, non-FF merge, race conditions | Branch protection + negative tests |
| Context scripts | Secret leakage, symlink escape, destructive move | Fixture tests and log inspection |
| Supply chain | Unpinned dependencies, remote scripts, plugin trust | Dependency inventory and checksum strategy |

## Gates
- G0: Audit inventory and test plan reviewed.
- G1: Reproducible negative tests for security controls.
- G2: Confirmed critical/high findings remediated, with regression tests.
- G3: Benchmark fixtures frozen and evaluator blinded.
- G4: Benchmark completed with raw metrics and caveats.
- G5: Explicit approval before unattended mode or default-branch landing.

## Non-goals
No claim of a 5x gain, no automatic subscription utilization promises, no production-repository deployment, and no bypass of human review.
