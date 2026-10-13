#!/usr/bin/env python3
"""Tests for plugins/studio-context/scripts/effort_check.py on synthetic
transcripts: a run that switched level right after a task notice, one that
switched without one, one that ended at its own level, and the agent check."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(KIT, "plugins", "studio-context", "scripts")
SCRIPT = os.path.join(SCRIPTS, "effort_check.py")
sys.path.insert(0, SCRIPTS)
import effort_check  # noqa: E402


def write_config(root, expected):
    os.makedirs(os.path.join(root, ".claude"), exist_ok=True)
    with open(os.path.join(root, ".claude", "studio.json"), "w") as f:
        json.dump({"context": {"expected_effort": expected}}, f)


def run_check(tmp, *extra):
    env = dict(os.environ)
    env.pop("CLAUDE_PROJECT_DIR", None)
    return subprocess.run([sys.executable, SCRIPT, "--days", "3650", "--project", tmp, "--root", tmp]
                          + list(extra), capture_output=True, text=True, env=env)


START = '<scheduled-task name="demo-wake-up">Start the run</scheduled-task>'
NOTICE = "<task-notification>\n<task-id>abc</task-id>\n<status>completed</status>\n</task-notification>"


def user(ts, text):
    return {"type": "user", "timestamp": ts, "message": {"role": "user", "content": text}}


def tool_result(ts):
    return {"type": "user", "timestamp": ts, "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "t1", "content": "done"}]}}


def asst(ts, effort):
    return {"type": "assistant", "timestamp": ts, "effort": effort,
            "message": {"role": "assistant", "content": [{"type": "text", "text": "ok"}]}}


RUNS = {
    # Ends at xhigh; the level changed right after a background task's notice.
    "after-notice": [
        user("2026-09-30T07:00:00.000Z", START),
        asst("2026-09-30T07:00:05.000Z", "high"),
        asst("2026-09-30T07:00:10.000Z", "medium"),
        tool_result("2026-09-30T07:00:20.000Z"),
        asst("2026-09-30T07:00:30.000Z", "medium"),
        {"type": "queue-operation", "operation": "enqueue", "timestamp": "2026-09-30T07:10:00.000Z",
         "content": NOTICE},
        user("2026-09-30T07:10:01.000Z", NOTICE),
        asst("2026-09-30T07:10:05.123Z", "xhigh"),
        tool_result("2026-09-30T07:10:06.000Z"),
        asst("2026-09-30T07:10:09.000Z", "xhigh"),
    ],
    # Briefly wrong, back to medium, then wrong to the end after a tool result.
    "no-notice": [
        user("2026-09-30T10:00:00.000Z", START),
        asst("2026-09-30T10:00:05.000Z", "high"),
        asst("2026-09-30T10:00:10.000Z", "medium"),
        user("2026-09-30T10:01:00.000Z", NOTICE),
        asst("2026-09-30T10:01:05.000Z", "xhigh"),
        asst("2026-09-30T10:01:10.000Z", "medium"),
        tool_result("2026-09-30T10:02:00.000Z"),
        asst("2026-09-30T10:02:05.000Z", "high"),
        asst("2026-09-30T10:02:09.000Z", "high"),
    ],
    # The notice arrives as a queued_command attachment, then a level-less
    # assistant record, then the switch: still right after a notice.
    "attachment-notice": [
        user("2026-09-30T16:00:00.000Z", START),
        asst("2026-09-30T16:00:05.000Z", "medium"),
        tool_result("2026-09-30T16:00:20.000Z"),
        asst("2026-09-30T16:00:30.000Z", "medium"),
        {"type": "attachment", "timestamp": "2026-09-30T16:10:00.000Z",
         "attachment": {"type": "queued_command", "prompt": NOTICE}},
        asst("2026-09-30T16:10:05.000Z", "xhigh"),
        asst("2026-09-30T16:10:09.000Z", "xhigh"),
    ],
    # A user notice, then an assistant record with no level, then the switch.
    "levelless-after-notice": [
        user("2026-09-30T19:00:00.000Z", START),
        asst("2026-09-30T19:00:05.000Z", "medium"),
        user("2026-09-30T19:10:00.000Z", NOTICE),
        {"type": "assistant", "timestamp": "2026-09-30T19:10:02.000Z",
         "message": {"role": "assistant", "content": [{"type": "text", "text": "ok"}]}},
        asst("2026-09-30T19:10:05.000Z", "xhigh"),
    ],
    # A prompt_snapshot attachment carries the system prompt, which names the
    # notice tag; it is not a notice, so the switch after it is not either.
    "snapshot-not-notice": [
        user("2026-09-30T21:00:00.000Z", START),
        asst("2026-09-30T21:00:05.000Z", "medium"),
        tool_result("2026-09-30T21:00:20.000Z"),
        {"type": "attachment", "timestamp": "2026-09-30T21:00:21.000Z",
         "attachment": {"type": "prompt_snapshot",
                        "text": "System prompt: a background task reports in a <task-notification> tag."}},
        asst("2026-09-30T21:00:25.000Z", "high"),
        asst("2026-09-30T21:00:29.000Z", "high"),
    ],
    # Ends at its own level.
    "ok": [
        user("2026-09-30T13:00:00.000Z", START),
        asst("2026-09-30T13:00:05.000Z", "high"),
        asst("2026-09-30T13:00:10.000Z", "medium"),
        user("2026-09-30T13:05:00.000Z", NOTICE),
        asst("2026-09-30T13:05:05.000Z", "medium"),
    ],
}


class EffortCheckTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.paths = {}
        for name, rows in RUNS.items():
            path = os.path.join(self.tmp, "%s.jsonl" % name)
            with open(path, "w") as f:
                for r in rows:
                    f.write(json.dumps(r) + "\n")
            self.paths[name] = path

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_switch_point_after_notice(self):
        self.assertEqual(effort_check.switch_point(self.paths["after-notice"], "medium"),
                         ("2026-09-30T07:10:05.123Z", "xhigh", True))

    def test_switch_point_not_after_notice(self):
        self.assertEqual(effort_check.switch_point(self.paths["no-notice"], "medium"),
                         ("2026-09-30T10:02:05.000Z", "high", False))

    def test_switch_point_after_attachment_notice(self):
        self.assertEqual(effort_check.switch_point(self.paths["attachment-notice"], "medium"),
                         ("2026-09-30T16:10:05.000Z", "xhigh", True))

    def test_levelless_assistant_keeps_notice(self):
        self.assertEqual(effort_check.switch_point(self.paths["levelless-after-notice"], "medium"),
                         ("2026-09-30T19:10:05.000Z", "xhigh", True))

    def test_snapshot_attachment_is_not_notice(self):
        self.assertEqual(effort_check.switch_point(self.paths["snapshot-not-notice"], "medium"),
                         ("2026-09-30T21:00:25.000Z", "high", False))

    def test_switch_point_ok_run(self):
        self.assertIsNone(effort_check.switch_point(self.paths["ok"], "medium"))

    def test_output_lines(self):
        write_config(self.tmp, {"wake-up": "medium"})
        p = run_check(self.tmp, "--strip-prefix", "demo-")
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        lines = [l for l in p.stdout.splitlines() if l.strip().startswith("wake-up")]
        self.assertEqual(len(lines), 6, p.stdout)
        self.assertTrue(lines[0].endswith(
            "MISMATCH (switched to xhigh at 2026-09-30T07:10:05Z, right after a task notice)"), lines[0])
        self.assertTrue(lines[1].endswith(
            "MISMATCH (switched to high at 2026-09-30T10:02:05Z, not after a task notice)"), lines[1])
        self.assertTrue(lines[2].endswith(" OK"), lines[2])
        self.assertTrue(lines[3].endswith(
            "MISMATCH (switched to xhigh at 2026-09-30T16:10:05Z, right after a task notice)"), lines[3])
        self.assertTrue(lines[4].endswith(
            "MISMATCH (switched to xhigh at 2026-09-30T19:10:05Z, right after a task notice)"), lines[4])
        self.assertIn("MISMATCH: 5 line(s)", p.stdout)

    def test_unprefixed_name_needs_full_key(self):
        # Without --strip-prefix the run is "demo-wake-up", which is not configured.
        write_config(self.tmp, {"wake-up": "medium"})
        p = run_check(self.tmp)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("wake-up", p.stdout)
        self.assertIn("no run in the period (expected medium)", p.stdout)

    def test_no_expected_levels_configured(self):
        p = run_check(self.tmp)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("no expected levels configured", p.stdout)

    def test_help(self):
        p = subprocess.run([sys.executable, SCRIPT, "--help"], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0)
        self.assertIn("--strip-prefix", p.stdout)


class AgentLevelTest(unittest.TestCase):
    """An agent's level is checked against the effort: line of its file,
    also when the transcript names the type with a plugin namespace."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.tmp, ".claude", "agents"))
        with open(os.path.join(self.tmp, ".claude", "agents", "builder-sonnet.md"), "w") as f:
            f.write("---\nname: builder-sonnet\nmodel: sonnet\neffort: high\n---\nbody\n")
        with open(os.path.join(self.tmp, ".claude", "agents", "helper.md"), "w") as f:
            f.write("---\nname: helper\nmodel: haiku\n---\nbody\n")
        write_config(self.tmp, {"wake-up": "medium"})
        run = [user("2026-10-05T07:05:00.000Z", START), asst("2026-10-05T07:05:05.000Z", "medium")]
        with open(os.path.join(self.tmp, "run.jsonl"), "w") as f:
            f.write("\n".join(json.dumps(r) for r in run) + "\n")
        self.sub = os.path.join(self.tmp, "run", "subagents")
        os.makedirs(self.sub)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def agent(self, name, kind, effort):
        with open(os.path.join(self.sub, name + ".meta.json"), "w") as f:
            json.dump({"agentType": kind}, f)
        with open(os.path.join(self.sub, name + ".jsonl"), "w") as f:
            f.write(json.dumps(asst("2026-10-05T07:06:00.000Z", effort)) + "\n")

    def check(self):
        return run_check(self.tmp, "--strip-prefix", "demo-")

    def test_matching_level_ok(self):
        self.agent("agent-a", "builder-sonnet", "high")
        p = self.check()
        self.assertIn("builder-sonnet   high   x1   OK", p.stdout, p.stdout)
        self.assertEqual(p.returncode, 0, p.stdout)

    def test_wrong_level_flagged(self):
        self.agent("agent-a", "builder-sonnet", "xhigh")
        p = self.check()
        self.assertIn("builder-sonnet   xhigh  x1   MISMATCH, its file says high", p.stdout, p.stdout)
        self.assertEqual(p.returncode, 1)

    def test_namespaced_type_matched(self):
        self.agent("agent-a", "studio-core:builder-sonnet", "xhigh")
        p = self.check()
        self.assertIn("studio-core:builder-sonnet xhigh  x1   MISMATCH, its file says high", p.stdout, p.stdout)
        self.assertEqual(p.returncode, 1)

    def test_type_without_level_inherits(self):
        self.agent("agent-a", "helper", "low")
        p = self.check()
        self.assertIn("inherits its run's level", p.stdout, p.stdout)
        self.assertEqual(p.returncode, 0, p.stdout)


if __name__ == "__main__":
    unittest.main()
