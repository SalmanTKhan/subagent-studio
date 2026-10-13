#!/usr/bin/env python3
"""The effort level each scheduled run and each agent type really used.

The level a run or an agent should work at is a rule in files: a scheduled
run's prompt can call a skill whose `effort` line sets the level for the
rest of the run, and each agent type names its own level in the `effort:`
line of its agent file. This script reads what happened. Every assistant
message in a session transcript carries the effort level it was written at,
and every subagent has a `.meta.json` naming its type.

Runs: for every session in the period whose first prompt names a scheduled
task (a `<scheduled-task name="...">` tag; its start is config
`unattended.scheduled_prompt_prefix`) listed in config
`context.expected_effort` ({run name: level}), it prints the level the run
ended at (the last message's; a run's first messages can come before its
level is set) beside the expected one, and counts a mismatch. A MISMATCH
line names its switch point: the time of the first message after which the
run stayed at a wrong level to its end, and whether the message just before
it was a background task's `<task-notification>` (the way a run once lost
its level), e.g. `MISMATCH (switched to xhigh at 2026-01-21T19:16:16Z, right
after a task notice)`. A configured run with no session in the period is a
plain line, not a mismatch.

Agents: for every agent those runs launched, the level its last message used
beside the `effort:` line of its agent file, read from `.claude/agents/*.md`
under the project root and from the sibling `studio-core` plugin's `agents/`
when it is installed beside this one. A namespaced type such as
`studio-core:builder` is matched on its last part too. A type whose file
names no level inherits its run's level and is not checked.

Exits 1 on any mismatch. The transcript dir is found as token_usage.py finds it.
"""
import argparse
import glob
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import studio_config  # noqa: E402
import transcripts  # noqa: E402
from transcripts import text_of  # noqa: E402,F401  (kept importable from here)


def read(path):
    """Return (first prompt text or None, first timestamp, first effort, last effort, effort changes)."""
    first_prompt, ts_first, first, last, changes = None, None, None, None, 0
    with open(path, errors="replace") as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if not isinstance(d, dict):
                continue
            ts = d.get("timestamp")
            if ts and (ts_first is None or ts < ts_first):
                ts_first = ts
            if first_prompt is None:
                first_prompt = transcripts.prompt_text(d)
            if d.get("type") == "assistant" and d.get("effort"):
                e = d["effort"]
                if first is None:
                    first = e
                elif e != last:
                    changes += 1
                last = e
    return first_prompt, ts_first, first, last, changes


def switch_point(path, want):
    """Return (timestamp, level, after a task notice) for the first assistant
    message after which the run stays at a level other than `want` to its end,
    or None when its last message is at `want`."""
    point, prev_notice, prev_kind = None, False, None
    with open(path, errors="replace") as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if not isinstance(d, dict):
                continue
            t = d.get("type")
            if t == "user":
                prev_kind = "user"
                prev_notice = "<task-notification>" in text_of((d.get("message") or {}).get("content"))
            elif t == "attachment":
                # A notice can also arrive as an attachment: a queued_command
                # whose prompt carries the notification. Other attachments
                # (a prompt_snapshot holds the whole system prompt, which
                # names the tag) leave the flag and the kind as they were.
                att = d.get("attachment") or {}
                prompt = att.get("prompt") if isinstance(att, dict) else None
                if (isinstance(att, dict) and att.get("type") == "queued_command"
                        and isinstance(prompt, str) and "<task-notification>" in prompt):
                    prev_kind, prev_notice = "user", True
            elif t == "assistant":
                e = d.get("effort")
                if not e:
                    # A record without a level says nothing about the switch.
                    continue
                if e != want:
                    if point is None:
                        point = (d.get("timestamp") or "?", e, prev_kind == "user" and prev_notice)
                else:
                    point = None
                prev_kind, prev_notice = "assistant", False
    return point


def agent_dirs(root):
    """The directories that hold agent files: the project's, then studio-core's."""
    dirs = [os.path.join(root, ".claude", "agents")]
    plugin_root = os.path.dirname(HERE)
    parent = os.path.dirname(plugin_root)
    # Side by side in a marketplace checkout: plugins/studio-core/agents.
    dirs.append(os.path.join(parent, "studio-core", "agents"))
    # Installed from a marketplace: <cache>/<marketplace>/studio-core/<version>/agents.
    dirs.extend(sorted(glob.glob(os.path.join(os.path.dirname(parent), "studio-core", "*", "agents"))))
    return [d for d in dirs if os.path.isdir(d)]


def agent_levels(dirs):
    """Return {agent type: effort} for the types whose file names a level.
    The first directory that names a type wins."""
    out = {}
    for directory in dirs:
        for path in sorted(glob.glob(os.path.join(directory, "*.md"))):
            with open(path, errors="replace") as f:
                text = f.read()
            m = re.match(r"---\r?\n(.*?)\r?\n---\r?\n", text, re.S)
            if not m:
                continue
            name = re.search(r"^name:\s*['\"]?([^'\"\s]+)", m.group(1), re.M)
            effort = re.search(r"^effort:\s*['\"]?([^'\"\s]+)", m.group(1), re.M)
            if name and effort:
                out.setdefault(name.group(1), effort.group(1))
    return out


def expected_for(kind, levels):
    if kind in levels:
        return levels[kind]
    return levels.get(kind.rsplit(":", 1)[-1])


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--days", type=int, default=2, help="how far back to look for each run (default 2)")
    ap.add_argument("--project", help="the transcript directory (default: auto)")
    ap.add_argument("--root", help="project root (default: $CLAUDE_PROJECT_DIR, git top level, cwd)")
    ap.add_argument("--strip-prefix", default="",
                    help="drop this prefix from scheduled task names before looking them up")
    a = ap.parse_args(argv)
    root = studio_config.find_root(a.root)
    cfg = transcripts.load_config(root)
    expected = cfg["context"].get("expected_effort") or {}
    project = transcripts.transcript_dir(a.project, cfg, root)
    pattern = transcripts.scheduled_pattern_for(cfg)

    cutoff = (datetime.now(timezone.utc) - timedelta(days=a.days)).timestamp()
    runs = {}  # run name -> [(ts, sid, first, last, path)]
    for path in glob.glob(os.path.join(project, "*.jsonl")):
        try:
            if os.path.getmtime(path) < cutoff:
                continue
            prompt, ts, first, last, _ = read(path)
        except OSError:
            continue
        name = transcripts.run_name(prompt, a.strip_prefix, pattern)
        if name in expected and ts and last:
            runs.setdefault(name, []).append((ts, os.path.basename(path)[:-6], first, last, path))

    bad = 0
    if not expected:
        print("Runs: no expected levels configured (context.expected_effort); runs not checked")
    else:
        print("Runs of each configured scheduled task (last %d days): the level each ended at" % a.days)
    for task, want in expected.items():
        if task not in runs:
            print("  %-36s no run in the period (expected %s)" % (task, want))
            continue
        for ts, sid, first, last, path in sorted(runs[task]):
            ok = last == want
            bad += 0 if ok else 1
            verdict = "OK"
            if not ok:
                verdict = "MISMATCH"
                sp = switch_point(path, want)
                if sp:
                    verdict += " (switched to %s at %s, %s)" % (
                        sp[1], sp[0][:19] + "Z" if len(sp[0]) >= 19 else sp[0],
                        "right after a task notice" if sp[2] else "not after a task notice")
            print("  %-36s %s  started at %-6s ended at %-6s expected %-6s %s" % (
                task, ts[:16], first, last, want, verdict))

    want_agent = agent_levels(agent_dirs(root))
    seen = {}  # (type, level) -> count
    sids = [row[1] for rows in runs.values() for row in rows]
    for sid in sids:
        for meta in glob.glob(os.path.join(project, sid, "**", "*.meta.json"), recursive=True):
            try:
                with open(meta) as f:
                    kind = json.load(f).get("agentType")
                _, _, _, last, _ = read(meta[: -len(".meta.json")] + ".jsonl")
            except (OSError, ValueError, AttributeError):
                continue
            if kind and last:
                seen[(kind, last)] = seen.get((kind, last), 0) + 1
    print("Agents those runs launched: type, level used, count")
    if not seen:
        print("  none")
    for (kind, level), n in sorted(seen.items()):
        want = expected_for(kind, want_agent)
        if want is None:
            verdict = "inherits its run's level"
        elif want == level:
            verdict = "OK"
        else:
            verdict = "MISMATCH, its file says %s" % want
            bad += 1
        print("  %-16s %-6s x%-3d %s" % (kind, level, n, verdict))

    print("OK: every level matches" if not bad else "MISMATCH: %d line(s)" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
