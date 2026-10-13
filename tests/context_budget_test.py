#!/usr/bin/env python3
"""Tests for plugins/studio-context/scripts/context_budget.py."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(KIT, "plugins", "studio-context", "scripts", "context_budget.py")


class ContextBudgetTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="context-budget-test-")

    def tearDown(self):
        shutil.rmtree(self.root)

    def write(self, rel, nbytes):
        path = os.path.join(self.root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write("x" * nbytes)

    def config(self, context):
        os.makedirs(os.path.join(self.root, ".claude"), exist_ok=True)
        with open(os.path.join(self.root, ".claude", "studio.json"), "w") as fh:
            json.dump({"context": context}, fh)

    def run_script(self, *args):
        env = dict(os.environ)
        env.pop("CLAUDE_PROJECT_DIR", None)
        return subprocess.run([sys.executable, SCRIPT, "--root", self.root] + list(args),
                              capture_output=True, text=True, env=env)

    def test_defaults_within_budget(self):
        self.write("CLAUDE.md", 1000)
        self.write("STATE.md", 500)
        p = self.run_script()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("OK: every budgeted file", p.stdout)
        self.assertIn("orientation set 500 bytes", p.stdout)

    def test_missing_glob_is_not_present(self):
        self.write("CLAUDE.md", 10)
        p = self.run_script()
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertRegex(p.stdout, r"\.claude/skills/\*/SKILL\.md\s+not present")
        self.assertRegex(p.stdout, r"TASKS\.md\s+not present")

    def test_file_over_budget_exits_1(self):
        self.config({"budgets": [{"path_glob": "docs/*.md", "max_bytes": 100}]})
        self.write("docs/a.md", 50)
        self.write("docs/b.md", 150)
        p = self.run_script()
        self.assertEqual(p.returncode, 1, p.stdout)
        self.assertIn("OVER BUDGET: 1 item(s): docs/b.md 150>100", p.stdout)
        self.assertRegex(p.stdout, r"docs/b\.md\s+150\s+37\s+100\s+OVER")

    def test_last_matching_entry_wins(self):
        self.config({"budgets": [{"path_glob": "skills/*/SKILL.md", "max_bytes": 100},
                                 {"path_glob": "skills/big/SKILL.md", "max_bytes": 500}]})
        self.write("skills/big/SKILL.md", 400)
        self.write("skills/small/SKILL.md", 90)
        p = self.run_script()
        self.assertEqual(p.returncode, 0, p.stdout)

    def test_orientation_total_over(self):
        self.config({"budgets": [{"path_glob": "STATE.md", "max_bytes": 1000},
                                 {"path_glob": "TASKS.md", "max_bytes": 1000}],
                     "orientation_total_bytes": 1500})
        self.write("STATE.md", 900)
        self.write("TASKS.md", 900)
        p = self.run_script()
        self.assertEqual(p.returncode, 1, p.stdout)
        self.assertIn("orientation set 1800>1500", p.stdout)

    def test_orientation_flag(self):
        self.config({"orientation_total_bytes": 100})
        self.write("STATE.md", 900)
        self.write("BOOT.md", 50)
        # The default set (STATE.md, 900 bytes) would be over 100; the named set is not.
        p = self.run_script()
        self.assertEqual(p.returncode, 1, p.stdout)
        p = self.run_script("--orientation", "BOOT.md")
        self.assertEqual(p.returncode, 0, p.stdout)
        self.assertIn("ORIENTATION (BOOT.md)", p.stdout)

    def test_quiet_prints_only_verdict(self):
        self.config({"budgets": [{"path_glob": "A.md", "max_bytes": 10}]})
        self.write("A.md", 20)
        p = self.run_script("--quiet")
        self.assertEqual(p.returncode, 1)
        self.assertNotIn("~tokens", p.stdout)
        self.assertIn("OVER BUDGET", p.stdout)

    def test_invalid_config_exits_2(self):
        self.config({"budgets": [{"path_glob": "A.md"}]})
        p = self.run_script()
        self.assertEqual(p.returncode, 2, p.stdout + p.stderr)

    def test_help(self):
        p = subprocess.run([sys.executable, SCRIPT, "--help"], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0)
        self.assertIn("--quiet", p.stdout)


if __name__ == "__main__":
    unittest.main()
