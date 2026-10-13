#!/usr/bin/env python3
"""Tokens per run type per day, from the Claude Code session transcripts.

Every session writes ~/.claude/projects/<slug>/<session>.jsonl with the token
usage of each request (input, cache writes, cache reads, output); subagents
write their own files under <session>/. This script sums them per session,
names each session's run type from its first prompt (the name in a
`<scheduled-task name="...">` tag, which starts with config
unattended.scheduled_prompt_prefix, else "interactive"), and prints:
  1. a per-day table of total tokens by run type,
  2. this period against the previous one, per run type, with the per-run average,
  3. the largest runs (with --runs).
"Tokens" here is every token the model processed, cache reads included, which
is what a usage meter counts. Cache reads are nearly all of it, so the figure
is roughly (context size) x (requests). Read it once a week.

The transcript dir is --project, else config `context.transcripts_dir`, else
~/.claude/projects/<slug>, where <slug> is the absolute project root with "/"
and "." replaced by "-". Days are bucketed in config `context.timezone`.
"""
import argparse
import collections
import glob
import json
import os
import sys
from datetime import datetime, timedelta

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import studio_config  # noqa: E402
import transcripts  # noqa: E402


def parse(path):
    """Return (requests {id: (ctx, out)}, first prompt text or None, first timestamp)."""
    reqs, first_prompt, ts_first = {}, None, None
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
            if d.get("type") == "assistant":
                msg = d.get("message") or {}
                u = msg.get("usage")
                rid = d.get("requestId") or msg.get("id")
                if u and rid:
                    reqs[rid] = (transcripts.context_tokens(u), u.get("output_tokens", 0))
    return reqs, first_prompt, ts_first


def sessions(project, zone, strip_prefix="", pattern=None):
    out = []
    for path in sorted(glob.glob(os.path.join(project, "*.jsonl"))):
        sid = os.path.basename(path)[:-6]
        main_reqs, prompt, ts = parse(path)
        sub_reqs = {}
        for sp in glob.glob(os.path.join(project, sid, "**", "*.jsonl"), recursive=True):
            r, _, _ = parse(sp)
            sub_reqs.update(r)
        if not main_reqs or not ts:
            continue
        start = datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone(zone)
        main_tok = sum(c + o for c, o in main_reqs.values())
        sub_tok = sum(c + o for c, o in sub_reqs.values())
        out.append(dict(start=start, kind=transcripts.run_name(prompt, strip_prefix, pattern),
                        total=main_tok + sub_tok, main=main_tok, sub=sub_tok,
                        req=len(main_reqs), sub_req=len(sub_reqs),
                        avg_ctx=sum(c for c, _ in main_reqs.values()) // len(main_reqs)))
    return out


def m(x):
    return f"{x / 1e6:6.1f}M"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--days", type=int, default=7, help="the period to report (default 7); the previous period is compared")
    ap.add_argument("--runs", action="store_true", help="also list the ten largest runs of the period")
    ap.add_argument("--project", help="the transcript directory (default: see above)")
    ap.add_argument("--root", help="project root (default: $CLAUDE_PROJECT_DIR, git top level, cwd)")
    ap.add_argument("--strip-prefix", default="", help="drop this prefix from scheduled task names")
    a = ap.parse_args(argv)
    root = studio_config.find_root(a.root)
    cfg = transcripts.load_config(root)
    zone = transcripts.tz(cfg)
    project = transcripts.transcript_dir(a.project, cfg, root)
    if not os.path.isdir(project):
        print("no transcript directory at %s (pass --project)" % project, file=sys.stderr)
        return 1

    now = datetime.now(zone)
    start_this = now - timedelta(days=a.days)
    start_prev = start_this - timedelta(days=a.days)
    S = [s for s in sessions(project, zone, a.strip_prefix,
                                transcripts.scheduled_pattern_for(cfg)) if s["start"] >= start_prev]
    this = [s for s in S if s["start"] >= start_this]
    prev = [s for s in S if s["start"] < start_this]
    kinds = sorted({s["kind"] for s in S}, key=lambda k: -sum(s["total"] for s in S if s["kind"] == k))

    print(f"Tokens per day by run type (period {start_this:%m-%d} to {now:%m-%d}, {zone}, sessions started in it)")
    print(f"{'day':<7}" + "".join(f"{k[:16]:>18}" for k in kinds) + f"{'ALL':>10}")
    by_day = collections.defaultdict(collections.Counter)
    for s in this:
        by_day[s["start"].strftime("%m-%d")][s["kind"]] += s["total"]
    for day in sorted(by_day):
        row = by_day[day]
        print(f"{day:<7}" + "".join(f"{m(row[k]) if row[k] else '-':>18}" for k in kinds) + f"{m(sum(row.values())):>10}")

    print(f"\nThis period against the previous {a.days} days, per run type (total, runs, average per run)")
    print(f"{'run type':<24}{'this total':>12}{'runs':>6}{'per run':>10}   {'prev total':>12}{'runs':>6}{'per run':>10}  change/run")
    for k in kinds:
        t = [s for s in this if s["kind"] == k]
        p = [s for s in prev if s["kind"] == k]
        tt, pt = sum(s["total"] for s in t), sum(s["total"] for s in p)
        ta = tt / len(t) if t else 0
        pa = pt / len(p) if p else 0
        change = f"{ta / pa:5.1f}x" if pa and ta else "  new" if ta else "    -"
        flag = "  DOUBLED" if pa and ta / pa >= 2 else ""
        print(f"{k:<24}{m(tt):>12}{len(t):>6}{m(ta):>10}   {m(pt):>12}{len(p):>6}{m(pa):>10}  {change}{flag}")
    print(f"{'ALL':<24}{m(sum(s['total'] for s in this)):>12}{len(this):>6}{'':>10}   {m(sum(s['total'] for s in prev)):>12}{len(prev):>6}")

    if a.runs:
        print("\nLargest runs this period (total, main-session share, requests main/sub, average main context)")
        for s in sorted(this, key=lambda s: -s["total"])[:10]:
            print(f"  {s['start']:%m-%d %H:%M} {s['kind']:<22}{m(s['total'])}  main {m(s['main'])}  req {s['req']}/{s['sub_req']}  ctx {s['avg_ctx'] // 1000}k")
    return 0


if __name__ == "__main__":
    sys.exit(main())
