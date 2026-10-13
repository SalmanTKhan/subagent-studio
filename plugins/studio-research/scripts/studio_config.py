#!/usr/bin/env python3
"""Load a project's .claude/studio.json over the built-in defaults.

Stdlib only, Python 3.9+. The source lives in shared/studio_config.py and
tools/sync_shared.py copies it into every plugin's scripts/ directory; edit
the source, never a copy.

Library use:
    import studio_config
    cfg = studio_config.load()                 # or load(root="/path/to/repo")
    studio_config.get(cfg, "core.review.passes")

Command line:
    python3 studio_config.py get core.review.reviewed_paths [--root DIR]
                                 [--file PATH] [--format lines|json|shell]

    --file PATH reads that file instead of the project's .claude/studio.json
    ("-" reads stdin), for a copy that is not in the working tree, such as
    the one on the remote main branch (`git show`). Defaults still apply.

    lines  scalars print as-is (booleans as true/false); an array prints one
           item per line, for a bash `while IFS= read -r` loop (bash 3.2
           has no mapfile); an object prints as JSON.
    json   the value as JSON.
    shell  a scalar or each array item shell-quoted, space-separated, for
           `eval "arr=($(...))"`; an object as one quoted JSON word.

Exit codes: 0 ok, 1 unknown key or usage error, 2 invalid config.
"""

import argparse
import copy
import json
import os
import shlex
import subprocess
import sys

CONFIG_RELPATH = os.path.join(".claude", "studio.json")

# Keep identical to the "default" values in config/studio.schema.json;
# tests/studio_config_test.py checks it.
DEFAULTS = {
    "roles": {},
    "core": {
        "main_branch": "main",
        "remote": "origin",
        "worktree_root": "",
        "ci_commands": [],
        "plan": {"big_also": []},
        "review": {
            "passes": 2,
            "reviewed_paths": ["src", "lib", "app", "apps", "packages", "scripts",
                               ".github", ".claude", "CLAUDE.md"],
            "docs_only": True,
            "land": "merge-no-ff",
            "push_hook": False,
            "branch_prefix": "review/",
        },
    },
    "context": {
        "budgets": [
            {"path_glob": "CLAUDE.md", "max_bytes": 32000},
            {"path_glob": "STATE.md", "max_bytes": 8000},
            {"path_glob": "TASKS.md", "max_bytes": 16000},
            {"path_glob": ".claude/skills/*/SKILL.md", "max_bytes": 8000},
            {"path_glob": ".claude/agents/*.md", "max_bytes": 6000},
        ],
        "orientation_total_bytes": 40000,
        "timezone": "UTC",
        "transcripts_dir": "",
        "expected_effort": {},
    },
    "unattended": {
        "lock_file": ".wake-lock",
        "stale_hours": 4,
        "max_tasks_per_run": 4,
        "run_minutes": 90,
        "usage_guard_pct": 85,
        "scheduled_prompt_prefix": "<scheduled-task",
        "notify": {
            "channels": ["ops", "needs-human"],
            "env_file": "~/.config/subagent-studio/notify.env",
        },
        "permission_gate": {
            "enabled": True,
            "protected_paths": [],
            "deny_message_ask": (
                "Denied: this is an unattended run and nobody can answer a "
                "permission prompt. Do the work another way, or record the "
                "blocker and move on."),
            "deny_message_schedule": (
                "Denied: an unattended run may not create or change scheduled "
                "tasks. Record the change as a task for a human."),
        },
        "files": {
            "state": "STATE.md",
            "tasks": "TASKS.md",
            "tasks_done": "TASKS-DONE.md",
            "task_dir": "tasks",
            "journal_dir": "journal",
            "decisions": "DECISIONS.md",
            "plans_dir": "plans",
        },
    },
    "research": {
        "out_dir": "research",
        "rubric": "research/rubric.md",
        "max_gatherers": 6,
        "browser": False,
    },
}

EFFORTS = ("low", "medium", "high", "xhigh", "max")
# Value constraints beyond the type, keyed by dotted path.
ENUMS = {
    "core.review.passes": (1, 2),
    "core.review.land": ("merge-no-ff", "pr"),
}
MINIMUMS = {
    "context.orientation_total_bytes": 1,
    "unattended.stale_hours": 1,
    "unattended.max_tasks_per_run": 1,
    "unattended.run_minutes": 1,
    "unattended.usage_guard_pct": 1,
    "research.max_gatherers": 1,
}
MAXIMUMS = {"unattended.usage_guard_pct": 100}


class ConfigError(ValueError):
    """The config file is unreadable or does not match the schema."""


def find_root(root=None):
    """Project root: the argument, $CLAUDE_PROJECT_DIR, git top level, cwd."""
    if root:
        return os.path.abspath(root)
    env = os.environ.get("CLAUDE_PROJECT_DIR")
    if env:
        return os.path.abspath(env)
    try:
        out = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, check=False)
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except OSError:
        pass
    return os.getcwd()


def deep_merge(base, override):
    """Return base with override merged in: objects merge, all else replaces."""
    result = copy.deepcopy(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = copy.deepcopy(value)
    return result


def _type_name(value):
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int):
        return "integer"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    if value is None:
        return "null"
    return type(value).__name__


def _check_role(path, value, errors):
    if not isinstance(value, dict):
        errors.append("%s: expected object, got %s" % (path, _type_name(value)))
        return
    for key, item in value.items():
        sub = "%s.%s" % (path, key)
        if key not in ("model", "effort"):
            errors.append("%s: unknown key (allowed: model, effort)" % sub)
        elif not isinstance(item, str):
            errors.append("%s: expected string, got %s" % (sub, _type_name(item)))
        elif key == "effort" and item not in EFFORTS:
            errors.append("%s: %r is not one of %s" % (sub, item, ", ".join(EFFORTS)))


def _check(path, value, default, errors):
    want = _type_name(default)
    got = _type_name(value)
    if want != got:
        errors.append("%s: expected %s, got %s" % (path, want, got))
        return
    if want == "object" and path == "context.expected_effort":
        for key, item in value.items():
            sub = "%s.%s" % (path, key)
            if not isinstance(item, str):
                errors.append("%s: expected string, got %s" % (sub, _type_name(item)))
            elif item not in EFFORTS:
                errors.append("%s: %r is not one of %s" % (sub, item, ", ".join(EFFORTS)))
    elif want == "object":
        for key, item in value.items():
            sub = "%s.%s" % (path, key)
            if key not in default:
                errors.append("%s: unknown key" % sub)
            else:
                _check(sub, item, default[key], errors)
    elif want == "array":
        if path == "context.budgets":
            for n, item in enumerate(value):
                sub = "%s[%d]" % (path, n)
                if not isinstance(item, dict):
                    errors.append("%s: expected object, got %s" % (sub, _type_name(item)))
                    continue
                for key in item:
                    if key not in ("path_glob", "max_bytes"):
                        errors.append("%s.%s: unknown key" % (sub, key))
                if not isinstance(item.get("path_glob"), str):
                    errors.append("%s.path_glob: required string" % sub)
                mb = item.get("max_bytes")
                if isinstance(mb, bool) or not isinstance(mb, int) or mb < 1:
                    errors.append("%s.max_bytes: required integer >= 1" % sub)
        else:
            for n, item in enumerate(value):
                if not isinstance(item, str):
                    errors.append("%s[%d]: expected string, got %s"
                                  % (path, n, _type_name(item)))
    if path in ENUMS and value not in ENUMS[path]:
        errors.append("%s: %r is not one of %s"
                      % (path, value, ", ".join(str(v) for v in ENUMS[path])))
    if path in MINIMUMS and value < MINIMUMS[path]:
        errors.append("%s: must be >= %d" % (path, MINIMUMS[path]))
    if path in MAXIMUMS and value > MAXIMUMS[path]:
        errors.append("%s: must be <= %d" % (path, MAXIMUMS[path]))


def validate(data):
    """Return a list of error strings; empty when data is a valid config."""
    errors = []
    if not isinstance(data, dict):
        return ["top level: expected object, got %s" % _type_name(data)]
    for key, value in data.items():
        if key == "$schema":
            if not isinstance(value, str):
                errors.append("$schema: expected string, got %s" % _type_name(value))
        elif key == "roles":
            if not isinstance(value, dict):
                errors.append("roles: expected object, got %s" % _type_name(value))
            else:
                for role, spec in value.items():
                    _check_role("roles.%s" % role, spec, errors)
        elif key not in DEFAULTS:
            errors.append("%s: unknown section" % key)
        else:
            _check(key, value, DEFAULTS[key], errors)
    return errors


def load(root=None, path=None):
    """Return the merged config for the project at root (see find_root).

    path, when given, is the config file to read instead ("-" is stdin); it
    must exist.
    """
    if path is None:
        path = os.path.join(find_root(root), CONFIG_RELPATH)
        if not os.path.exists(path):
            return copy.deepcopy(DEFAULTS)
    try:
        if path == "-":
            data = json.load(sys.stdin)
        else:
            with open(path, encoding="utf-8") as handle:
                data = json.load(handle)
    except (OSError, ValueError) as exc:
        raise ConfigError("%s: cannot read: %s" % (path, exc))
    errors = validate(data)
    if errors:
        raise ConfigError("%s is invalid:\n  %s" % (path, "\n  ".join(errors)))
    data.pop("$schema", None)
    return deep_merge(DEFAULTS, data)


def get(cfg, dotted):
    """Return the value at a dotted path such as "core.review.passes"."""
    value = cfg
    for part in dotted.split("."):
        if not isinstance(value, dict) or part not in value:
            raise KeyError(dotted)
        value = value[part]
    return value


def _scalar(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (dict, list)) or value is None:
        return json.dumps(value)
    return str(value)


def render(value, fmt):
    """Format a value for the command line."""
    if fmt == "json":
        return json.dumps(value)
    if fmt == "shell":
        if isinstance(value, list):
            return " ".join(shlex.quote(_scalar(v)) for v in value)
        return shlex.quote(_scalar(value))
    if isinstance(value, list):
        return "\n".join(_scalar(v) for v in value)
    return _scalar(value)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Read .claude/studio.json with defaults.")
    sub = parser.add_subparsers(dest="cmd")
    p_get = sub.add_parser("get", help="print one value")
    p_get.add_argument("key", help="dotted path, e.g. core.review.passes")
    p_get.add_argument("--root", help="project root (default: auto)")
    p_get.add_argument("--file", help="read this config file instead (- for stdin)")
    p_get.add_argument("--format", choices=("lines", "json", "shell"), default="lines")
    p_val = sub.add_parser("validate", help="check the config and exit")
    p_val.add_argument("--root", help="project root (default: auto)")
    p_val.add_argument("--file", help="read this config file instead (- for stdin)")
    args = parser.parse_args(argv)
    if not args.cmd:
        parser.print_usage(sys.stderr)
        return 1
    try:
        cfg = load(args.root, args.file)
    except ConfigError as exc:
        print("studio_config: %s" % exc, file=sys.stderr)
        return 2
    if args.cmd == "validate":
        return 0
    try:
        value = get(cfg, args.key)
    except KeyError:
        print("studio_config: unknown key %r" % args.key, file=sys.stderr)
        return 1
    text = render(value, args.format)
    if text:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
