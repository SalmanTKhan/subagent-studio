#!/usr/bin/env python3
"""Tests for plugins/studio-context/scripts/check_moved_text.py."""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(KIT, "plugins", "studio-context", "scripts", "check_moved_text.py")

OLD = """# Guide

## 5. Choosing what to build
- Every candidate passes the three gates before it is scored.
- A candidate that needs a partner approval fails the first gate.

| Tier | Rule |
|---|---|
| read-only | Ship freely after a smoke test |

---
Short.
"""

# The section moved word for word, re-wrapped, behind a stub.
NEW_MAIN = """# Guide

## 5. Choosing what to build
Moved verbatim to `docs/claude/05-choosing.md`. Read it for a scan.

| Tier | Rule |
|---|---|
| read-only | Ship freely after a smoke test |
"""
NEW_MOVED = """## 5. Choosing what to build
- Every candidate passes the three
  gates before it is scored.
- A candidate that needs a partner approval fails the first gate
"""


class CheckMovedTextTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="check-moved-test-")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def write(self, name, text):
        path = os.path.join(self.tmp, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(text)
        return path

    def run_script(self, *args):
        return subprocess.run([sys.executable, SCRIPT] + list(args),
                              capture_output=True, text=True, cwd=self.tmp)

    def test_verbatim_move_passes(self):
        old = self.write("old.md", OLD)
        new = self.write("GUIDE.md", NEW_MAIN)
        moved = self.write("docs/claude/05-choosing.md", NEW_MOVED)
        p = self.run_script("--old", old, "--new", new, moved)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertRegex(p.stdout, r"^OK: all \d+ lines")

    def test_lost_line_fails(self):
        old = self.write("old.md", OLD)
        new = self.write("GUIDE.md", NEW_MAIN)
        moved = self.write("docs/claude/05-choosing.md",
                           NEW_MOVED.replace("fails the first gate", "may pass"))
        p = self.run_script("--old", old, "--new", new, moved)
        self.assertEqual(p.returncode, 1, p.stdout)
        self.assertIn("MISSING 1 of", p.stdout)
        self.assertIn("A candidate that needs a partner approval fails the first gate", p.stdout)

    def test_ignore_regex(self):
        old = self.write("old.md", OLD)
        new = self.write("GUIDE.md", NEW_MAIN)
        p = self.run_script("--old", old, "--new", new, "--ignore", "candidate")
        self.assertEqual(p.returncode, 0, p.stdout)

    def test_git_spec(self):
        env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
                   GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com")
        for cmd in (["git", "init", "-q"], ["git", "add", "GUIDE.md"],
                    ["git", "commit", "-q", "-m", "old"]):
            if cmd[1] == "add":
                self.write("GUIDE.md", OLD)
            subprocess.run(cmd, cwd=self.tmp, check=True, env=env, capture_output=True)
        self.write("GUIDE.md", NEW_MAIN)
        self.write("docs/claude/05-choosing.md", NEW_MOVED)
        p = self.run_script("--old", "git:HEAD:GUIDE.md", "--new", "GUIDE.md",
                            "docs/claude/05-choosing.md")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

    def test_help(self):
        p = self.run_script("--help")
        self.assertEqual(p.returncode, 0)
        self.assertIn("--old", p.stdout)


if __name__ == "__main__":
    unittest.main()
