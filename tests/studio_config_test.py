#!/usr/bin/env python3
"""Tests for shared/studio_config.py, tools/sync_shared.py and tools/build_agents.py."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOADER = os.path.join(KIT, "shared", "studio_config.py")
sys.path.insert(0, os.path.join(KIT, "shared"))
import studio_config  # noqa: E402


def schema_defaults(node):
    """Rebuild the defaults object from the schema's "default" fields."""
    if "default" in node:
        return node["default"]
    if node.get("type") == "object" and "properties" in node:
        out = {}
        for key, sub in node["properties"].items():
            if key == "$schema":
                continue
            out[key] = schema_defaults(sub)
        return out
    raise AssertionError("schema node has no default: %r" % node)


class Project:
    """A temp project root with an optional .claude/studio.json."""

    def __init__(self, data=None, raw=None):
        self.root = tempfile.mkdtemp(prefix="studio-config-test-")
        if data is not None or raw is not None:
            os.makedirs(os.path.join(self.root, ".claude"))
            with open(os.path.join(self.root, ".claude", "studio.json"), "w") as fh:
                fh.write(raw if raw is not None else json.dumps(data))

    def cli(self, *args):
        env = dict(os.environ)
        env.pop("CLAUDE_PROJECT_DIR", None)
        return subprocess.run([sys.executable, LOADER] + list(args) + ["--root", self.root],
                              capture_output=True, text=True, env=env)

    def close(self):
        shutil.rmtree(self.root)


class LoaderTest(unittest.TestCase):
    def setUp(self):
        self.projects = []

    def tearDown(self):
        for p in self.projects:
            p.close()

    def project(self, data=None, raw=None):
        p = Project(data, raw)
        self.projects.append(p)
        return p

    def test_defaults_without_file(self):
        p = self.project()
        cfg = studio_config.load(p.root)
        self.assertEqual(cfg, studio_config.DEFAULTS)
        self.assertEqual(studio_config.get(cfg, "core.review.passes"), 2)
        self.assertEqual(studio_config.get(cfg, "unattended.files.journal_dir"), "journal")

    def test_root_from_env(self):
        p = self.project({"core": {"main_branch": "trunk"}})
        old = os.environ.get("CLAUDE_PROJECT_DIR")
        os.environ["CLAUDE_PROJECT_DIR"] = p.root
        try:
            self.assertEqual(studio_config.get(studio_config.load(), "core.main_branch"), "trunk")
        finally:
            if old is None:
                del os.environ["CLAUDE_PROJECT_DIR"]
            else:
                os.environ["CLAUDE_PROJECT_DIR"] = old

    def test_deep_merge(self):
        p = self.project({
            "$schema": "./studio.schema.json",
            "roles": {"builder": {"effort": "low"}},
            "core": {"review": {"passes": 1, "reviewed_paths": ["src"]}},
            "unattended": {"notify": {"channels": ["ops"]}},
        })
        cfg = studio_config.load(p.root)
        self.assertNotIn("$schema", cfg)
        self.assertEqual(cfg["roles"], {"builder": {"effort": "low"}})
        self.assertEqual(cfg["core"]["review"]["passes"], 1)
        self.assertEqual(cfg["core"]["review"]["reviewed_paths"], ["src"])  # arrays replace
        self.assertEqual(cfg["core"]["review"]["land"], "merge-no-ff")      # siblings kept
        self.assertEqual(cfg["core"]["main_branch"], "main")
        self.assertEqual(cfg["unattended"]["notify"]["env_file"],
                         "~/.config/subagent-studio/notify.env")
        self.assertEqual(cfg["research"], studio_config.DEFAULTS["research"])
        self.assertEqual(studio_config.DEFAULTS["core"]["review"]["passes"], 2)  # not mutated

    def test_example_file_is_valid(self):
        with open(os.path.join(KIT, "config", "studio.example.json")) as fh:
            self.assertEqual(studio_config.validate(json.load(fh)), [])

    def test_invalid_configs_exit_2(self):
        cases = [
            ({"core": {"review": {"passes": "two"}}}, "core.review.passes"),
            ({"core": {"review": {"passes": 3}}}, "core.review.passes"),
            ({"core": {"review": {"docs_only": "yes"}}}, "core.review.docs_only"),
            ({"core": {"ci_commands": "make test"}}, "core.ci_commands"),
            ({"core": {"mainbranch": "x"}}, "core.mainbranch"),
            ({"roles": {"builder": {"effort": "extreme"}}}, "roles.builder.effort"),
            ({"context": {"budgets": [{"path_glob": "x"}]}}, "max_bytes"),
            ({"unattended": {"stale_hours": True}}, "unattended.stale_hours"),
            ({"nonsense": {}}, "nonsense"),
            ([], "top level"),
        ]
        for data, needle in cases:
            with self.subTest(data=data):
                res = self.project(data).cli("get", "core.main_branch")
                self.assertEqual(res.returncode, 2, res.stderr)
                self.assertIn(needle, res.stderr)
                self.assertEqual(res.stdout, "")
        res = self.project(raw="{not json").cli("get", "core.main_branch")
        self.assertEqual(res.returncode, 2)
        self.assertIn("cannot read", res.stderr)

    def test_cli_lines_format(self):
        p = self.project()
        res = p.cli("get", "core.review.reviewed_paths")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(res.stdout.splitlines(),
                         studio_config.DEFAULTS["core"]["review"]["reviewed_paths"])
        self.assertEqual(p.cli("get", "core.review.docs_only").stdout, "true\n")
        self.assertEqual(p.cli("get", "core.review.passes").stdout, "2\n")
        self.assertEqual(p.cli("get", "core.ci_commands").stdout, "")  # empty array
        budgets = p.cli("get", "context.budgets").stdout.splitlines()
        self.assertEqual(json.loads(budgets[0]), {"path_glob": "CLAUDE.md", "max_bytes": 32000})

    def test_cli_lines_feed_a_read_loop(self):
        # A while-read loop, not mapfile: macOS ships bash 3.2, which has no mapfile.
        p = self.project({"core": {"ci_commands": ["ruff check .", "python -m pytest -q"]}})
        script = ('cmds=(); while IFS= read -r c; do cmds+=("$c"); done '
                  '< <("$PY" "$LOADER" get core.ci_commands --root "$ROOT"); '
                  'printf "%s|" "${#cmds[@]}" "${cmds[@]}"')
        env = dict(os.environ, PY=sys.executable, LOADER=LOADER, ROOT=p.root)
        res = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=env)
        self.assertEqual(res.stdout, "2|ruff check .|python -m pytest -q|")

    def test_cli_json_and_shell_formats(self):
        p = self.project({"core": {"ci_commands": ["make lint", "it's"]}})
        res = p.cli("get", "core.ci_commands", "--format", "json")
        self.assertEqual(json.loads(res.stdout), ["make lint", "it's"])
        res = p.cli("get", "core.ci_commands", "--format", "shell")
        out = subprocess.run(["bash", "-c", 'eval "a=($1)"; printf "%s|" "${a[@]}"', "_",
                              res.stdout.strip()], capture_output=True, text=True).stdout
        self.assertEqual(out, "make lint|it's|")

    def test_cli_unknown_key_exit_1(self):
        res = self.project().cli("get", "core.nope")
        self.assertEqual(res.returncode, 1)
        self.assertIn("unknown key", res.stderr)

    def test_embedded_defaults_match_schema(self):
        with open(os.path.join(KIT, "config", "studio.schema.json")) as fh:
            schema = json.load(fh)
        self.assertEqual(schema["$schema"], "https://json-schema.org/draft/2020-12/schema")
        self.assertEqual(schema_defaults(schema), studio_config.DEFAULTS)


class GeneratedFilesTest(unittest.TestCase):
    def run_tool(self, name, *args):
        return subprocess.run([sys.executable, os.path.join(KIT, "tools", name)] + list(args),
                              capture_output=True, text=True)

    def test_sync_shared_check(self):
        res = self.run_tool("sync_shared.py", "--check")
        self.assertEqual(res.returncode, 0, res.stderr)

    def test_build_agents_check(self):
        res = self.run_tool("build_agents.py", "--check")
        self.assertEqual(res.returncode, 0, res.stderr)

    def test_build_agents_generates_and_detects_drift(self):
        kit = tempfile.mkdtemp(prefix="build-agents-test-")
        try:
            os.makedirs(os.path.join(kit, "shared", "agents"))
            with open(os.path.join(kit, "shared", "agents", "role.body.md"), "w") as fh:
                fh.write("You are a role.\n")
            with open(os.path.join(kit, "shared", "agents", "variants.json"), "w") as fh:
                json.dump([{"plugin": "p", "name": "role", "body": "role",
                            "description": "Does things: well.", "model": "sonnet",
                            "effort": "high", "tools": ["Read", "Grep"]}], fh)
            self.assertEqual(self.run_tool("build_agents.py", "--kit", kit, "--check").returncode, 1)
            self.assertEqual(self.run_tool("build_agents.py", "--kit", kit).returncode, 0)
            out = os.path.join(kit, "plugins", "p", "agents", "role.md")
            with open(out) as fh:
                text = fh.read()
            self.assertTrue(text.startswith('---\nname: role\ndescription: "Does things: well."\n'
                                            'tools: Read, Grep\nmodel: sonnet\neffort: high\n---\n'))
            self.assertIn("from shared/agents/role.body.md; edit the source -->", text)
            self.assertTrue(text.endswith("You are a role.\n"))
            self.assertEqual(self.run_tool("build_agents.py", "--kit", kit, "--check").returncode, 0)
            with open(out, "a") as fh:
                fh.write("hand edit\n")
            res = self.run_tool("build_agents.py", "--kit", kit, "--check")
            self.assertEqual(res.returncode, 1)
            self.assertIn("plugins/p/agents/role.md", res.stderr)
        finally:
            shutil.rmtree(kit)


if __name__ == "__main__":
    unittest.main()
