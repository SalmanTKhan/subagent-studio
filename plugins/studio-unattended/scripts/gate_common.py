"""Helpers shared by the permission gate and the prompt alarm. Python 3.9,
standard library only, no network: a hook must answer fast and never hang.

State and logs go in $CLAUDE_PLUGIN_DATA, falling back to
~/.config/subagent-studio. The project root is $CLAUDE_PROJECT_DIR (then
the hook's cwd). Settings come from the project's .claude/studio.json,
section `unattended`, through studio_config.py beside this file; an
unreadable or invalid config falls back to the defaults, so a broken config
never breaks a hook.
"""
import copy
import datetime
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import studio_config  # noqa: E402

HEAD_LINES = 200           # the first real prompt sits in the first lines
HEAD_MAX_BYTES = 4 << 20   # read at most this much of a transcript
DEFAULT_DATA_DIR = "~/.config/subagent-studio"


def data_dir():
    d = os.environ.get("CLAUDE_PLUGIN_DATA") or os.path.expanduser(DEFAULT_DATA_DIR)
    os.makedirs(d, exist_ok=True)
    return d


def project_root(cwd=None):
    """$CLAUDE_PROJECT_DIR, then the hook's cwd, or None."""
    env = os.environ.get("CLAUDE_PROJECT_DIR")
    if env and os.path.isabs(env):
        return os.path.normpath(env)
    if cwd and os.path.isabs(cwd):
        return os.path.normpath(cwd)
    return None


def load_config(cwd=None):
    """The merged config; the defaults when it cannot be read."""
    root = project_root(cwd)
    try:
        if root:
            return studio_config.load(root)
    except Exception:
        pass
    return copy.deepcopy(studio_config.DEFAULTS)


def unattended_cfg(cfg):
    u = copy.deepcopy(studio_config.DEFAULTS["unattended"])
    got = cfg.get("unattended") if isinstance(cfg, dict) else None
    if isinstance(got, dict):
        u = studio_config.deep_merge(u, got)
    return u


def scheduled_mark(cfg):
    mark = unattended_cfg(cfg).get("scheduled_prompt_prefix")
    return mark if isinstance(mark, str) and mark else "<scheduled-task"


def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def log_line(filename, record):
    """Append one JSON line; a logging failure never breaks the hook."""
    try:
        rec = {"ts": now_iso()}
        rec.update(record)
        with open(os.path.join(data_dir(), filename), "a") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception:
        pass


def _record_prompt(rec):
    """The prompt text of a transcript record that is a real prompt, or None.
    A real prompt is a queue-operation enqueue or a user record that is not
    meta and not a tool result (attachments and the rest are skipped)."""
    if not isinstance(rec, dict):
        return None
    if rec.get("type") == "queue-operation":
        c = rec.get("content") if rec.get("operation") == "enqueue" else None
        return c if isinstance(c, str) else None
    if rec.get("type") != "user" or rec.get("isMeta"):
        return None
    msg = rec.get("message")
    c = msg.get("content") if isinstance(msg, dict) else None
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
            return None
        texts = [b.get("text") or "" for b in c if isinstance(b, dict) and b.get("type") == "text"]
        return "".join(texts) if texts else None
    return None


def first_prompt(path):
    """The first real prompt of a transcript ("" when none in its head).
    Raises OSError when the file cannot be read."""
    size = 0
    with open(path, "r", errors="replace") as f:
        for _ in range(HEAD_LINES):
            line = f.readline(HEAD_MAX_BYTES - size)
            if not line:
                break
            size += len(line)
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            text = _record_prompt(rec)
            if text is not None:
                return text
            if size >= HEAD_MAX_BYTES:
                break
    return ""


def _is_scheduled_prompt(text, mark):
    return text.lstrip().startswith(mark)


def _session_transcript(path):
    """A subagent's transcript (<sid>/subagents/agent-x.jsonl) carries its own
    brief, not the task prompt: read the parent session's <sid>.jsonl too."""
    parts = os.path.normpath(path).split(os.sep)
    if "subagents" in parts:
        i = parts.index("subagents")
        if i >= 1:
            return os.sep.join(parts[: i - 1] + [parts[i - 1] + ".jsonl"])
    return None


def session_prompt(transcript_path, mark):
    """The session's first real prompt: the parent session's for a subagent
    whose own prompt is not a scheduled task's. None when unreadable, or
    when the transcript holds no prompt yet."""
    if not transcript_path:
        return None
    try:
        text = first_prompt(transcript_path)
    except Exception:
        text = None
    if text and _is_scheduled_prompt(text, mark):
        return text
    parent = _session_transcript(transcript_path)
    if parent:
        try:
            ptext = first_prompt(parent)
        except Exception:
            return None
        return ptext or None
    return text or None


# Permission modes (the hook input's `permission_mode`) in which no person
# answers prompts. Only these let a session without a readable prompt count
# as unattended.
NO_PROMPT_MODES = ("bypassPermissions", "dontAsk")


def is_unattended(transcript_path, mark, permission_mode=None):
    """True when the session is a scheduled task's: its first real prompt
    (a subagent: its parent session's) starts with the scheduled prompt
    prefix. Text quoting the prefix later on, in a tool result say, does not
    count. A missing or unreadable transcript, or one with no prompt in its
    head, counts as unattended only when the permission mode is one in which
    no person answers prompts; in any other mode a person may be at the
    keyboard, so it counts as attended and the gate decides nothing."""
    text = session_prompt(transcript_path, mark)
    if text is None:
        return permission_mode in NO_PROMPT_MODES
    return _is_scheduled_prompt(text, mark)


def is_scheduled(transcript_path, mark):
    """True only on positive evidence: the transcript (a subagent: its parent
    session's) is readable and its first real prompt is a scheduled task's.
    The prompt alarm posts on this; the gate keeps is_unattended."""
    text = session_prompt(transcript_path, mark)
    return bool(text) and _is_scheduled_prompt(text, mark)


def task_name(transcript_path, mark):
    """The scheduled task's name from its tag (`<prefix> name="x" ...`), or ""."""
    text = (session_prompt(transcript_path, mark) or "").lstrip()
    if not _is_scheduled_prompt(text, mark):
        return ""
    m = re.match(re.escape(mark) + r'[^>\n]*?\bname=\\?"([^"\\]+)', text)
    return m.group(1) if m else ""


def plain_run_name(name):
    """How a person knows the run: its scheduled task's own name."""
    return 'the scheduled run "{}"'.format(name) if name else "a scheduled run"
