#!/usr/bin/env python3
"""Show the context size of the Claude Code sessions of this project active now.

A run cannot see its own context from the inside, but its transcript is on
disk and every request records the size of the prompt the model read. This
prints one line per session written to in the last few minutes: when it
started, its run type (the name in a `<scheduled-task name="...">` tag of its
first prompt, the tag starting with config unattended.scheduled_prompt_prefix,
else "interactive"), how many requests it has made, and the
context size of its latest request in tokens. It measures; no rule hangs on
the number. A thin orchestrator that hands each hands-on step to a fresh
agent is what keeps a run's context small, and this is how you see whether
it does.

The transcript dir and time zone are found as token_usage.py finds them.
"""
import argparse
import glob
import json
import os
import sys
import time
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import studio_config  # noqa: E402
import transcripts  # noqa: E402


def describe(path, zone, strip_prefix="", pattern=None):
    first_prompt, first_ts, last_ctx, n = None, None, 0, 0
    with open(path, errors="replace") as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if not isinstance(d, dict):
                continue
            ts = d.get("timestamp")
            if ts and first_ts is None:
                first_ts = ts
            if first_prompt is None:
                first_prompt = transcripts.prompt_text(d)
            if d.get("type") == "assistant":
                u = (d.get("message") or {}).get("usage")
                if u:
                    n += 1
                    last_ctx = transcripts.context_tokens(u)
    start = datetime.fromisoformat(first_ts.replace("Z", "+00:00")).astimezone(zone) if first_ts else None
    return transcripts.run_name(first_prompt, strip_prefix, pattern), start, n, last_ctx


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--minutes", type=int, default=10, help="sessions written to in the last N minutes (default 10)")
    ap.add_argument("--project", help="the transcript directory (default: auto)")
    ap.add_argument("--root", help="project root (default: $CLAUDE_PROJECT_DIR, git top level, cwd)")
    ap.add_argument("--strip-prefix", default="", help="drop this prefix from scheduled task names")
    a = ap.parse_args(argv)
    root = studio_config.find_root(a.root)
    cfg = transcripts.load_config(root)
    zone = transcripts.tz(cfg)
    project = transcripts.transcript_dir(a.project, cfg, root)
    cutoff = time.time() - a.minutes * 60
    rows = []
    for path in glob.glob(os.path.join(project, "*.jsonl")):
        if os.path.getmtime(path) < cutoff:
            continue
        task, start, n, ctx = describe(path, zone, a.strip_prefix,
                                     transcripts.scheduled_pattern_for(cfg))
        rows.append((start, task, n, ctx, os.path.basename(path)[:8]))
    rows.sort(key=lambda r: r[0] or datetime.min.replace(tzinfo=timezone.utc))
    print(f"{'started':<14}{'session':<28}{'requests':>9}{'context':>10}  id   ({zone})")
    for start, task, n, ctx, sid in rows:
        print(f"{start.strftime('%m-%d %H:%M') if start else '?':<14}{task[:27]:<28}{n:>9}{ctx // 1000:>9}k  {sid}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
