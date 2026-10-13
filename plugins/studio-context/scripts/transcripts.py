#!/usr/bin/env python3
"""Shared helpers for the transcript readers (token_usage.py, effort_check.py,
my_context.py). Run directly, it prints the transcript dir it would read.
Stdlib only, Python 3.9+.

Claude Code writes every session to ~/.claude/projects/<slug>/<session>.jsonl,
where <slug> is the absolute project root with "/" and "." replaced by "-"
(so /home/me/my.repo becomes -home-me-my-repo). A subagent writes its own
<session>/subagents/agent-<id>.jsonl beside a .meta.json naming its type.
"""
import os
import re
import sys
from datetime import timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import studio_config  # noqa: E402

DEFAULT_SCHEDULED_PREFIX = "<scheduled-task"


def scheduled_pattern(prefix=DEFAULT_SCHEDULED_PREFIX):
    """The regex that finds a scheduled task's tag, `<prefix> ... name="x"`,
    and captures x. An empty prefix falls back to the default."""
    prefix = prefix if isinstance(prefix, str) and prefix else DEFAULT_SCHEDULED_PREFIX
    return re.compile(re.escape(prefix) + r'[^>\n]*?\bname="([^"]+)"')


SCHEDULED = scheduled_pattern()


def scheduled_pattern_for(cfg):
    """The pattern for config unattended.scheduled_prompt_prefix. The whole
    config is read through studio_config, whose defaults carry the unattended
    section, so this works when only the context plugin is installed."""
    section = cfg.get("unattended") if isinstance(cfg, dict) else None
    prefix = section.get("scheduled_prompt_prefix") if isinstance(section, dict) else None
    return scheduled_pattern(prefix)


def load_config(root):
    """The merged config, or exit 2 with the loader's message."""
    try:
        return studio_config.load(root)
    except studio_config.ConfigError as exc:
        print("studio_config: %s" % exc, file=sys.stderr)
        sys.exit(2)


def slug(root):
    return re.sub(r"[/.]", "-", os.path.abspath(root))


def transcript_dir(project, cfg, root):
    """--project, else context.transcripts_dir, else ~/.claude/projects/<slug>."""
    if project:
        return os.path.expanduser(project)
    configured = cfg["context"].get("transcripts_dir") or ""
    if configured:
        path = os.path.expanduser(configured)
        return path if os.path.isabs(path) else os.path.join(root, path)
    base = os.path.expanduser(os.path.join("~", ".claude", "projects"))
    path = os.path.join(base, slug(root))
    if not os.path.isdir(path):
        # Some builds replace every character that is not a letter or digit.
        alt = os.path.join(base, re.sub(r"[^A-Za-z0-9]", "-", os.path.abspath(root)))
        if os.path.isdir(alt):
            return alt
    return path


def tz(cfg):
    """The configured IANA time zone, UTC when it is unknown."""
    name = cfg["context"].get("timezone") or "UTC"
    try:
        from zoneinfo import ZoneInfo
        return ZoneInfo(name)
    except Exception:  # unknown zone or no tz database
        print("warning: unknown time zone %r, using UTC" % name, file=sys.stderr)
        return timezone.utc


def text_of(content):
    """The plain text of a message's content, a string or a list of blocks."""
    if isinstance(content, str):
        return content
    return " ".join(b.get("text", "") for b in (content or [])
                    if isinstance(b, dict) and b.get("type") == "text")


def prompt_text(record):
    """The text of a user or queue-operation record, or None for other records
    and for a user record that holds only tool results."""
    t = record.get("type")
    if t == "queue-operation":
        c = record.get("content")
    elif t == "user":
        c = (record.get("message") or {}).get("content")
    else:
        return None
    text = text_of(c)
    return text if text.strip() else None


def run_name(first_prompt, strip_prefix="", pattern=None):
    """The scheduled task named in the first prompt, else "interactive".
    pattern comes from scheduled_pattern_for(cfg); the default prefix when None."""
    m = (pattern or SCHEDULED).search(first_prompt or "")
    if not m:
        return "interactive"
    name = m.group(1)
    if strip_prefix and name.startswith(strip_prefix):
        name = name[len(strip_prefix):]
    return name


def context_tokens(usage):
    """Every input token of one request: fresh, cache writes and cache reads."""
    return (usage.get("input_tokens", 0) + usage.get("cache_creation_input_tokens", 0)
            + usage.get("cache_read_input_tokens", 0))


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", help="print the transcript dir for this project root")
    a = ap.parse_args()
    r = studio_config.find_root(a.root)
    print(transcript_dir(None, load_config(r), r))
