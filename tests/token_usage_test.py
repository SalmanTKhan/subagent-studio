#!/usr/bin/env python3
"""Tests for plugins/studio-context/scripts/token_usage.py and transcripts.py,
on tiny fake JSONL transcripts in a temp dir."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

sys.dont_write_bytecode = True

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(KIT, "plugins", "studio-context", "scripts")
SCRIPT = os.path.join(SCRIPTS, "token_usage.py")
sys.path.insert(0, SCRIPTS)
import token_usage  # noqa: E402
import transcripts  # noqa: E402


def iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def user(ts, text):
    return {"type": "user", "timestamp": iso(ts), "message": {"role": "user", "content": text}}


def asst(ts, rid, ctx, out):
    return {"type": "assistant", "timestamp": iso(ts), "requestId": rid,
            "message": {"role": "assistant", "content": [{"type": "text", "text": "ok"}],
                        "usage": {"input_tokens": 10, "cache_creation_input_tokens": 0,
                                  "cache_read_input_tokens": ctx - 10, "output_tokens": out}}}


def write_jsonl(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        for r in rows:
            fh.write(json.dumps(r) + "\n")
        fh.write("not json\n")


class TokenUsageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="token-usage-test-")
        self.proj = os.path.join(self.tmp, "transcripts")
        self.root = os.path.join(self.tmp, "repo")
        os.makedirs(self.root)
        now = datetime.now(timezone.utc)
        t = now - timedelta(days=1)
        # A scheduled run: 2 requests in the session (one repeated id), 1 in a subagent.
        write_jsonl(os.path.join(self.proj, "s1.jsonl"), [
            {"type": "queue-operation", "operation": "enqueue", "timestamp": iso(t),
             "content": '<scheduled-task name="demo-wake-up">Start the run</scheduled-task>'},
            user(t, '<scheduled-task name="demo-wake-up">Start the run</scheduled-task>'),
            asst(t + timedelta(seconds=5), "r1", 1_000_000, 1000),
            asst(t + timedelta(seconds=6), "r1", 1_000_000, 1000),
            asst(t + timedelta(seconds=9), "r2", 2_000_000, 1000),
        ])
        write_jsonl(os.path.join(self.proj, "s1", "subagents", "agent-a.jsonl"), [
            asst(t + timedelta(seconds=7), "r3", 500_000, 0),
        ])
        # An interactive session whose later message names a task: still interactive.
        write_jsonl(os.path.join(self.proj, "s2.jsonl"), [
            user(t, "Fix the build"),
            user(t + timedelta(seconds=1), '<scheduled-task name="demo-wake-up">x</scheduled-task>'),
            asst(t + timedelta(seconds=2), "q1", 300_000, 0),
        ])
        # A run in the previous period.
        old = now - timedelta(days=10)
        write_jsonl(os.path.join(self.proj, "s3.jsonl"), [
            user(old, '<scheduled-task name="demo-wake-up">Start</scheduled-task>'),
            asst(old + timedelta(seconds=2), "o1", 1_000_000, 0),
        ])

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_script(self, *args, home=None):
        env = dict(os.environ)
        env.pop("CLAUDE_PROJECT_DIR", None)
        if home:
            env["HOME"] = home
        return subprocess.run([sys.executable, SCRIPT, "--root", self.root] + list(args),
                              capture_output=True, text=True, env=env)

    def test_sessions_sum_and_name(self):
        rows = {s["kind"]: s for s in token_usage.sessions(self.proj, timezone.utc, "demo-")
                if s["start"] > datetime.now(timezone.utc) - timedelta(days=3)}
        self.assertEqual(set(rows), {"wake-up", "interactive"})
        run = rows["wake-up"]
        self.assertEqual(run["main"], 3_002_000)
        self.assertEqual(run["sub"], 500_000)
        self.assertEqual(run["total"], 3_502_000)
        self.assertEqual((run["req"], run["sub_req"]), (2, 1))
        self.assertEqual(rows["interactive"]["total"], 300_000)

    def test_cli_report(self):
        p = self.run_script("--project", self.proj, "--days", "7", "--runs", "--strip-prefix", "demo-")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        line = [l for l in p.stdout.splitlines() if l.startswith("wake-up ")]
        self.assertEqual(len(line), 1, p.stdout)
        self.assertIn("3.5M", line[0])
        self.assertIn("3.5x", line[0])
        self.assertIn("DOUBLED", line[0])
        self.assertIn("Largest runs", p.stdout)

    def test_no_strip_by_default(self):
        p = self.run_script("--project", self.proj)
        self.assertIn("demo-wake-up", p.stdout)

    def test_timezone_from_config(self):
        os.makedirs(os.path.join(self.root, ".claude"))
        with open(os.path.join(self.root, ".claude", "studio.json"), "w") as fh:
            json.dump({"context": {"timezone": "Asia/Tokyo"}}, fh)
        p = self.run_script("--project", self.proj)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("Asia/Tokyo", p.stdout)

    def test_auto_transcript_dir(self):
        home = os.path.join(self.tmp, "home")
        auto = os.path.join(home, ".claude", "projects", transcripts.slug(self.root))
        shutil.copytree(self.proj, auto)
        p = self.run_script(home=home)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("demo-wake-up", p.stdout)

    def test_run_name_default_prefix(self):
        self.assertEqual(transcripts.run_name('<scheduled-task name="nightly">go'), "nightly")
        cfg = {"unattended": {"scheduled_prompt_prefix": "<scheduled-task"}}
        pat = transcripts.scheduled_pattern_for(cfg)
        self.assertEqual(transcripts.run_name('<scheduled-task name="nightly" file="x">', "", pat),
                         "nightly")
        self.assertEqual(transcripts.run_name("hello", "", pat), "interactive")
        # no unattended section: the default prefix
        self.assertEqual(transcripts.run_name('<scheduled-task name="n">', "",
                                              transcripts.scheduled_pattern_for({})), "n")

    def test_run_name_configured_prefix(self):
        pat = transcripts.scheduled_pattern_for({"unattended": {"scheduled_prompt_prefix": "[cron-run]"}})
        self.assertEqual(transcripts.run_name('[cron-run] name="nightly"\nRead', "", pat), "nightly")
        self.assertEqual(transcripts.run_name('<scheduled-task name="nightly">', "", pat), "interactive")

    def test_cli_reads_configured_prefix(self):
        write_jsonl(os.path.join(self.proj, "s4.jsonl"), [
            user(datetime.now(timezone.utc) - timedelta(hours=2), '[cron-run] name="cron-job"\nGo'),
            asst(datetime.now(timezone.utc) - timedelta(hours=2), "c1", 100_000, 0),
        ])
        p = self.run_script("--project", self.proj)
        self.assertNotIn("cron-job", p.stdout)
        os.makedirs(os.path.join(self.root, ".claude"))
        with open(os.path.join(self.root, ".claude", "studio.json"), "w") as fh:
            json.dump({"unattended": {"scheduled_prompt_prefix": "[cron-run]"}}, fh)
        p = self.run_script("--project", self.proj)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("cron-job", p.stdout)

    def test_slug(self):
        self.assertEqual(transcripts.slug("/home/me/my.repo"), "-home-me-my-repo")

    def test_missing_dir_exits_1(self):
        p = self.run_script("--project", os.path.join(self.tmp, "nope"))
        self.assertEqual(p.returncode, 1)

    def test_help(self):
        p = subprocess.run([sys.executable, SCRIPT, "--help"], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0)
        self.assertIn("--strip-prefix", p.stdout)


if __name__ == "__main__":
    unittest.main()
