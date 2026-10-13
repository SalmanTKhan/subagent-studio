#!/usr/bin/env python3
"""Tests for studio-core's review_path.py on throwaway git repos: which
changes take the docs-only review path and which the full one.
  python3 tests/review_path_test.py
Standard library only (unittest)."""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(KIT, "plugins", "studio-core", "scripts", "review_path.py")

AGENT = """---
name: helper
description: A test agent.
tools: Read, Grep
model: opus
effort: medium
---
# Helper

The body of the agent.
"""

SKILL = """---
name: fm
description: A test skill.
---
# Fm

One rule.
"""


class ReviewPathTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="review_path_test_")
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "Test")
        self.git("config", "commit.gpgsign", "false")
        # Ignore the machine's global gitignore, which may list .claude/settings.local.json.
        self.git("config", "core.excludesFile", os.devnull)
        self.write(".claude/skills/demo/SKILL.md", "# Demo\n\nOne rule.\n")
        self.write(".claude/agents/helper.md", AGENT)
        self.write("apps/demo/README.md", "# App\n")
        self.write(".claude/skills/fm/SKILL.md", SKILL)
        self.write("notes/old.md", "# Old\n")
        self.commit("base")
        self.base = self.rev()

    def tearDown(self):
        shutil.rmtree(self.dir)

    def git(self, *args):
        subprocess.run(["git", *args], cwd=self.dir, check=True, capture_output=True)

    def rev(self):
        return subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.dir, check=True,
                              capture_output=True, text=True).stdout.strip()

    def write(self, path, text):
        full = os.path.join(self.dir, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as f:
            f.write(text)

    def commit(self, msg):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", msg)

    def run_script(self, base=None, head="HEAD"):
        env = dict(os.environ)
        env.pop("CLAUDE_PROJECT_DIR", None)
        proc = subprocess.run([sys.executable, SCRIPT, base or self.base, head],
                              cwd=self.dir, capture_output=True, text=True, env=env)
        return proc.returncode, proc.stdout.splitlines()

    def test_repo_option_reads_another_tree(self):
        # --repo names the tree, so the script runs from anywhere (never from
        # the review worktree's own copy): the same answers as run inside it.
        self.write(".claude/skills/demo/SKILL.md", "# Demo\n\nOne rule, reworded.\n")
        self.commit("skill")
        env = dict(os.environ)
        env.pop("CLAUDE_PROJECT_DIR", None)
        elsewhere = tempfile.mkdtemp(prefix="review_path_cwd_")
        try:
            def run(*args):
                p = subprocess.run([sys.executable, SCRIPT, *args], cwd=elsewhere,
                                   capture_output=True, text=True, env=env)
                return p.returncode, p.stdout.splitlines()
            self.assertEqual(run("--repo", self.dir, self.base, "HEAD"), (0, ["docs-only"]))
            self.write("tools/check.py", "print('x')\n")
            self.commit("py")
            self.assertEqual(run("--repo", self.dir, self.base, "HEAD"),
                             (0, ["full", "tools/check.py"]))
            self.assertEqual(run("--repo", self.dir, self.base)[0], 2)
            self.assertEqual(run("--repo", "", self.base, "HEAD")[0], 2)
            # Without --repo, a cwd outside any repository is a git error.
            self.assertEqual(run(self.base, "HEAD")[0], 2)
        finally:
            shutil.rmtree(elsewhere)

    def test_skill_md_edit_is_docs_only(self):
        self.write(".claude/skills/demo/SKILL.md", "# Demo\n\nOne rule, reworded.\n")
        self.commit("skill")
        self.assertEqual(self.run_script(), (0, ["docs-only"]))

    def test_python_file_is_full(self):
        self.write("tools/check.py", "print('x')\n")
        self.commit("py")
        self.assertEqual(self.run_script(), (0, ["full", "tools/check.py"]))

    def test_agent_body_change_is_docs_only(self):
        self.write(".claude/agents/helper.md", AGENT.replace("The body", "The new body"))
        self.commit("agent body")
        self.assertEqual(self.run_script(), (0, ["docs-only"]))

    def test_agent_effort_change_is_full(self):
        self.write(".claude/agents/helper.md", AGENT.replace("effort: medium", "effort: high"))
        self.commit("agent effort")
        self.assertEqual(self.run_script(),
                         (0, ["full", ".claude/agents/helper.md: effort: line changed"]))

    def test_new_agent_file_is_full(self):
        self.write(".claude/agents/fresh.md", AGENT.replace("helper", "fresh"))
        self.commit("new agent")
        code, out = self.run_script()
        self.assertEqual(code, 0)
        self.assertEqual(out[0], "full")
        self.assertEqual(sorted(out[1:]), [
            ".claude/agents/fresh.md: effort: line changed",
            ".claude/agents/fresh.md: model: line changed",
            ".claude/agents/fresh.md: tools: line changed",
        ])

    def test_md_under_apps_is_full(self):
        self.write("apps/demo/README.md", "# App\n\nMore.\n")
        self.commit("app md")
        self.assertEqual(self.run_script(), (0, ["full", "apps/demo/README.md"]))

    def test_deleted_md_is_docs_only(self):
        self.git("rm", "-q", "notes/old.md")
        self.git("commit", "-q", "-m", "delete")
        self.assertEqual(self.run_script(), (0, ["docs-only"]))

    def test_mixed_change_is_full(self):
        self.write(".claude/skills/demo/SKILL.md", "# Demo\n\nChanged.\n")
        self.write("scripts/x.sh", "echo x\n")
        self.commit("mixed")
        self.assertEqual(self.run_script(), (0, ["full", "scripts/x.sh"]))

    def test_agent_gaining_permission_mode_and_hooks_is_full(self):
        text = AGENT.replace("effort: medium\n", "effort: medium\n"
                             "permissionMode: bypassPermissions\n"
                             "hooks:\n  PreToolUse:\n    - command: curl x\n")
        self.write(".claude/agents/helper.md", text)
        self.commit("agent permissions")
        self.assertEqual(self.run_script(), (0, [
            "full",
            ".claude/agents/helper.md: hooks: line changed",
            ".claude/agents/helper.md: permissionMode: line changed",
        ]))

    def test_skill_gaining_allowed_tools_is_full(self):
        self.write(".claude/skills/fm/SKILL.md",
                   SKILL.replace("---\n# Fm", "allowed-tools: Bash\n---\n# Fm"))
        self.commit("skill tools")
        self.assertEqual(self.run_script(), (0, [
            "full", ".claude/skills/fm/SKILL.md: allowed-tools: line changed"]))

    def test_skill_description_change_is_docs_only(self):
        self.write(".claude/skills/fm/SKILL.md",
                   SKILL.replace("A test skill.", "A test skill, reworded."))
        self.commit("skill description")
        self.assertEqual(self.run_script(), (0, ["docs-only"]))

    def test_new_skill_with_only_name_and_description_is_docs_only(self):
        self.write(".claude/skills/other/SKILL.md", SKILL.replace("fm", "other"))
        self.commit("new skill")
        self.assertEqual(self.run_script(), (0, ["docs-only"]))

    def test_new_command_with_allowed_tools_is_full(self):
        self.write(".claude/commands/go.md",
                   "---\ndescription: Go.\nallowed-tools: Bash(git:*)\n---\nGo.\n")
        self.commit("new command")
        self.assertEqual(self.run_script(), (0, [
            "full", ".claude/commands/go.md: allowed-tools: line changed"]))

    def test_deleted_agent_file_is_full(self):
        self.git("rm", "-q", ".claude/agents/helper.md")
        self.git("commit", "-q", "-m", "delete agent")
        code, out = self.run_script()
        self.assertEqual((code, out[0]), (0, "full"))

    def test_md_symlink_is_full(self):
        os.symlink("old.md", os.path.join(self.dir, "notes", "link.md"))
        self.commit("symlink")
        self.assertEqual(self.run_script(), (0, [
            "full", "notes/link.md: mode 120000 (symlink)"]))

    def test_md_made_executable_is_full(self):
        os.chmod(os.path.join(self.dir, "notes", "old.md"), 0o755)
        self.commit("chmod")
        self.assertEqual(self.run_script(), (0, [
            "full", "notes/old.md: mode 100755 (executable)"]))

    def test_bom_agent_tools_widened_is_full(self):
        self.write(".claude/agents/bom.md", "\ufeff" + AGENT.replace("helper", "bom"))
        self.commit("bom agent")
        base = self.rev()
        self.write(".claude/agents/bom.md", "\ufeff" + AGENT.replace("helper", "bom")
                   .replace("tools: Read, Grep", "tools: Read, Grep, Bash, Write"))
        self.commit("bom tools")
        self.assertEqual(self.run_script(base=base), (0, [
            "full", ".claude/agents/bom.md: tools: line changed"]))

    def test_case_variant_claude_dir_is_full(self):
        blob = subprocess.run(["git", "hash-object", "-w", "--stdin"], cwd=self.dir, check=True,
                              capture_output=True, text=True, input=AGENT.replace("helper", "evil")).stdout.strip()
        self.git("update-index", "--add", "--cacheinfo", "100644,%s,.Claude/agents/evil.md" % blob)
        self.git("commit", "-q", "-m", "case variant")
        code, out = self.run_script()
        self.assertEqual(out[0], "full", out)

    def test_nested_claude_dir_is_full(self):
        self.write("docs/.claude/agents/evil.md", AGENT.replace("helper", "evil"))
        self.commit("nested")
        code, out = self.run_script()
        self.assertEqual(out[0], "full", out)

    def test_settings_json_is_full(self):
        self.write(".claude/settings.json", '{"permissions": {"allow": ["Bash"]}}\n')
        self.write(".claude/settings.local.json", "{}\n")
        self.commit("settings")
        code, out = self.run_script()
        self.assertEqual(out[0], "full", out)
        self.assertIn(".claude/settings.json", out)
        self.assertIn(".claude/settings.local.json", out)

    def test_studio_json_is_full(self):
        self.write(".claude/studio.json", '{"core": {"review": {"passes": 2}}}\n')
        self.commit("config")
        code, out = self.run_script()
        self.assertEqual(out, ["full", ".claude/studio.json"])

    def test_hooks_are_full(self):
        self.write("plugin/hooks/hooks.json", '{"hooks": {}}\n')
        self.write("plugin/hooks/gate.py", "print(1)\n")
        self.commit("hooks")
        code, out = self.run_script()
        self.assertEqual(out[0], "full", out)
        self.assertIn("plugin/hooks/hooks.json", out)
        self.assertIn("plugin/hooks/gate.py", out)

    def test_plugin_agent_frontmatter_change_is_full(self):
        self.write("plugins/p/agents/helper.md", AGENT)
        self.commit("plugin agent")
        base = self.rev()
        self.write("plugins/p/agents/helper.md", AGENT.replace("tools: Read, Grep", "tools: Read, Grep, Bash"))
        self.commit("widen tools")
        code, out = self.run_script(base=base)
        self.assertEqual(out, ["full", "plugins/p/agents/helper.md: tools: line changed"])

    def test_plugin_agent_body_change_is_docs_only(self):
        self.write("plugins/p/agents/helper.md", AGENT)
        self.commit("plugin agent")
        base = self.rev()
        self.write("plugins/p/agents/helper.md", AGENT.replace("The body", "The new body"))
        self.commit("reword")
        self.assertEqual(self.run_script(base=base), (0, ["docs-only"]))

    def test_new_plugin_skill_with_allowed_tools_is_full(self):
        self.write("plugins/p/skills/x/SKILL.md", "---\nname: x\ndescription: d\nallowed-tools: Bash\n---\n# X\n")
        self.commit("plugin skill")
        code, out = self.run_script()
        self.assertEqual(out, ["full", "plugins/p/skills/x/SKILL.md: allowed-tools: line changed"])

    def test_configured_reviewed_dir_makes_md_full(self):
        self.write(".claude/studio.json", '{"core": {"review": {"reviewed_paths": ["docs/"]}}}\n')
        self.commit("config")
        base = self.rev()
        self.write("docs/guide.md", "# Guide\n")
        self.write("apps/demo/README.md", "# App, reworded\n")
        self.commit("docs")
        # docs/ is reviewed now; apps/ no longer is.
        self.assertEqual(self.run_script(base=base), (0, ["full", "docs/guide.md"]))

    def test_md_file_entry_in_reviewed_paths_stays_docs_only(self):
        self.write("CLAUDE.md", "# Rules\n")
        self.commit("rules")
        self.assertEqual(self.run_script(), (0, ["docs-only"]))

    def test_broken_config_makes_everything_full(self):
        self.write(".claude/studio.json", "{not json\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "broken")
        base = self.rev()
        self.write("notes/new.md", "# New\n")
        self.commit("docs")
        code, out = self.run_script(base=base)
        self.assertEqual(code, 0)
        self.assertEqual(out[0], "full", out)
        self.assertTrue(out[1].startswith("config: "), out)

    def test_bad_ref_exits_2(self):
        code, out = self.run_script(base="no-such-ref")
        self.assertEqual((code, out), (2, []))


if __name__ == "__main__":
    unittest.main()
