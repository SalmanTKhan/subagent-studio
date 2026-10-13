# Changelog

All notable changes to this project are listed here. Versions follow
[Semantic Versioning](https://semver.org/).

## 0.1.0 (2026-10-13)

First public release.

- **studio-core:** the agents `builder`, `builder-sonnet`, `reviewer`,
  `reviewer-pass-one`, `planner`, `planner-max` and `searcher`; the skills
  `plan-then-build`, `self-review`, `orchestrator-rules`, `studio-init` and
  `effort-low|medium|high|xhigh`; `review_guard.sh` (push, audit, move),
  `review_path.py`, `worktree_sweep.sh`; an optional push hook.
- **studio-context:** the `context-budget` skill; `context_budget.py`,
  `check_moved_text.py`, `token_usage.py`, `effort_check.py`,
  `my_context.py`.
- **studio-unattended:** the skills `wake-up`, `task-queue`, `journal`,
  `usage-guard` and `notify`; `wake_lock.sh`, `notify.sh`; the permission
  gate and prompt alarm hooks; templates for the state file, the queue, the
  journal, decisions, plans, the wake-up prompt and scheduling.
- **studio-research:** the agents `research-lead`, `gatherer` and
  `gatherer-browser`; the `research-run` skill; rubric, plan and report
  templates.
- One config file, `.claude/studio.json`, with a JSON schema; per-role
  `model` and `effort` overrides.
- `install.sh` for copy-in installs without plugin support.
- A toy example repo, the test suite and CI.
