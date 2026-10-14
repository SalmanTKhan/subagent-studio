#!/usr/bin/env python3
"""Isolated negative tests for studio installer, review guard and permission gate.

Run: python3 -m unittest discover -s audit/tests -v
No production checkout, remote, or user configuration is modified.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
INSTALL = ROOT / "install.sh"
CORE = ROOT / "plugins/studio-core/scripts"
GATE = ROOT / "plugins/studio-unattended/scripts/permission_gate.py"


def run(*args, cwd=None, env=None, input=None):
    return subprocess.run(
        [str(a) for a in args], cwd=cwd, env=env, input=input,
        text=True, capture_output=True, timeout=35, check=False,
    )


class InstallerNegativeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name) / "project"
        self.target.mkdir()

    def install(self, *args):
        return run("bash", INSTALL, "--target", self.target, *args)

    def test_dry_run_does_not_write(self):
        result = self.install("--modules", "core", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(self.target.iterdir()), [])

    def test_conflicting_file_is_not_overwritten(self):
        path = self.target / ".claude/agents/builder.md"
        path.parent.mkdir(parents=True)
        path.write_text("user-owned sentinel\n")
        result = self.install("--modules", "core")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(path.read_text(), "user-owned sentinel\n")
        self.assertFalse((self.target / "scripts/studio/.studio-install").exists())

    def test_uninstall_preserves_modified_files(self):
        result = self.install("--modules", "core")
        self.assertEqual(result.returncode, 0, result.stderr)
        path = self.target / ".claude/agents/builder.md"
        self.assertTrue(path.exists())
        path.write_text("user-modified\n")
        result = self.install("--uninstall")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(path.read_text(), "user-modified\n")


class GuardNegativeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name)
        self.remote = base / "remote.git"
        self.repo = base / "repo"
        for args in [
            ("git", "init", "--bare", self.remote),
            ("git", "init", "-b", "main", self.repo),
        ]:
            r = run(*args)
            if r.returncode:
                self.skipTest(r.stderr)
        for args in [
            ("git", "config", "user.name", "Fixture"),
            ("git", "config", "user.email", "fixture@example.invalid"),
            ("git", "remote", "add", "origin", self.remote),
        ]:
            self.assertEqual(run(*args, cwd=self.repo).returncode, 0)
        (self.repo / "src").mkdir()
        (self.repo / "src/code.txt").write_text("baseline\n")
        self.git("add", ".")
        self.git("commit", "-m", "baseline")
        self.git("push", "-u", "origin", "main")
        self.base = self.git("rev-parse", "HEAD").stdout.strip()
        self.env = dict(os.environ, STUDIO_REVIEWED_PATHS="src",
                        STUDIO_MAIN_BRANCH="main", STUDIO_REMOTE="origin")

    def git(self, *args):
        r = run("git", *args, cwd=self.repo)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r

    def guard(self, *args):
        return run("bash", CORE / "review_guard.sh", *args,
                   cwd=self.repo, env=self.env)

    def test_direct_unreviewed_code_commit_is_rejected(self):
        (self.repo / "src/code.txt").write_text("unreviewed\n")
        self.git("add", ".")
        self.git("commit", "-m", "unreviewed code")
        result = self.guard("push")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_docs_only_commit_is_not_rejected(self):
        (self.repo / "notes.txt").write_text("notes\n")
        self.git("add", ".")
        self.git("commit", "-m", "notes")
        result = self.guard("push")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_fake_review_trailer_on_plain_commit_is_rejected(self):
        (self.repo / "src/code.txt").write_text("unreviewed\n")
        self.git("add", ".")
        self.git("commit", "-m", "spoofed", "-m",
                 "Reviewed-by: fresh reviewer agent, " +
                 self.base[:12] + ".." + self.base[:12])
        result = self.guard("push")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_remote_is_fail_closed(self):
        self.git("remote", "remove", "origin")
        result = self.guard("push")
        self.assertNotEqual(result.returncode, 0)


class PermissionGateNegativeTests(unittest.TestCase):
    def test_attended_prompt_is_not_automatically_approved(self):
        with tempfile.TemporaryDirectory() as tmp:
            payload = {
                "hook_event_name": "PermissionRequest",
                "permission_mode": "default",
                "tool_name": "Bash",
                "tool_input": {"command": "echo harmless"},
                "cwd": tmp,
                "transcript_path": str(Path(tmp) / "missing.jsonl"),
            }
            env = dict(os.environ, CLAUDE_PLUGIN_DATA=tmp)
            result = run("python3", GATE, env=env, input=json.dumps(payload))
            self.assertEqual(result.returncode, 0, result.stderr)
            # No explicit allow: attended users retain control of the prompt.
            if result.stdout.strip():
                self.assertNotEqual(
                    json.loads(result.stdout).get("hookSpecificOutput", {})
                    .get("decision", {}).get("behavior"), "allow")


if __name__ == "__main__":
    unittest.main()
