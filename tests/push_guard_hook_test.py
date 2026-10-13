#!/usr/bin/env python3
"""Tests for studio-core's push_guard_hook.py on throwaway git repos with a
bare origin: off means pass-through, only a push that could update main runs
the review guard, the guard's refusal is a deny, and the hook's own errors
fail open.
  python3 tests/push_guard_hook_test.py
Standard library only (unittest)."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# PUSH_GUARD_HOOK_UNDER_TEST runs these cases against another copy of the hook.
HOOK = os.environ.get("PUSH_GUARD_HOOK_UNDER_TEST") or os.path.join(
    KIT, "plugins", "studio-core", "scripts", "push_guard_hook.py")
HOOKS_JSON = os.path.join(KIT, "plugins", "studio-core", "hooks", "hooks.json")

ENV = dict(os.environ)
for k in ("CLAUDE_PROJECT_DIR", "STUDIO_REVIEWED_PATHS", "STUDIO_MAIN_BRANCH", "STUDIO_REMOTE"):
    ENV.pop(k, None)
ENV.update({
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid",
    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
    "PYTHONDONTWRITEBYTECODE": "1",
})


class PushGuardHookTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="push_guard_hook_test_")
        self.origin = os.path.join(self.tmp, "origin.git")
        self.repo = os.path.join(self.tmp, "repo")
        self.run_git(self.tmp, "init", "-q", "--bare", "-b", "main", self.origin)
        self.run_git(self.tmp, "clone", "-q", self.origin, self.repo)
        self.commit("src/app.py", "x = 1\n", "base")
        self.commit("notes/day.md", "one\n", "docs")
        self.git("push", "-q", "origin", "main")
        self.config({"core": {"review": {"push_hook": True}}})

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_git(self, cwd, *args):
        return subprocess.run(["git", *args], cwd=cwd, env=ENV, check=True,
                              capture_output=True, text=True).stdout.strip()

    def git(self, *args):
        return self.run_git(self.repo, *args)

    def commit(self, path, text, msg, repo=None):
        repo = repo or self.repo
        full = os.path.join(repo, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "a", encoding="utf-8") as f:
            f.write(text)
        self.run_git(repo, "add", "--", path)
        self.run_git(repo, "commit", "-q", "-m", msg)

    def config(self, data, raw=None):
        d = os.path.join(self.repo, ".claude")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "studio.json"), "w", encoding="utf-8") as f:
            f.write(raw if raw is not None else json.dumps(data))

    def hook(self, command, cwd=None, stdin=None):
        """(exit code, parsed stdout or None, stderr)."""
        env = dict(ENV, CLAUDE_PROJECT_DIR=self.repo)
        payload = stdin if stdin is not None else json.dumps({
            "hook_event_name": "PreToolUse", "tool_name": "Bash",
            "cwd": cwd or self.repo, "tool_input": {"command": command},
        })
        proc = subprocess.run([sys.executable, HOOK], input=payload, env=env,
                              cwd=cwd or self.repo, capture_output=True, text=True)
        out = json.loads(proc.stdout) if proc.stdout.strip() else None
        return proc.returncode, out, proc.stderr

    def assertPass(self, result):
        code, out, _ = result
        self.assertEqual((code, out), (0, None), result)

    def assertDeny(self, result, text):
        code, out, _ = result
        self.assertEqual(code, 0, result)
        self.assertIsNotNone(out, result)
        spec = out["hookSpecificOutput"]
        self.assertEqual(spec["hookEventName"], "PreToolUse")
        self.assertEqual(spec["permissionDecision"], "deny")
        self.assertIn(text, spec["permissionDecisionReason"])

    # The cases the step names.

    def test_hook_off_passes_through(self):
        self.config({"core": {"review": {"push_hook": False}}})
        self.commit("src/app.py", "x = 2\n", "unreviewed code")
        self.assertPass(self.hook("git push origin main"))

    def test_hook_off_by_default(self):
        self.config({})
        self.commit("src/app.py", "x = 2\n", "unreviewed code")
        self.assertPass(self.hook("git push origin main"))

    def test_non_push_command_passes(self):
        self.commit("src/app.py", "x = 2\n", "unreviewed code")
        self.assertPass(self.hook("ls -la && git status"))
        self.assertPass(self.hook("echo 'git push origin main'"))

    def test_reviewed_landing_passes(self):
        base = self.git("rev-parse", "origin/main")
        wt = os.path.join(self.tmp, "repo-review", "t1")
        self.git("worktree", "add", "-q", "-b", "review/t1", wt, "origin/main")
        self.commit("src/app.py", "x = 3\n", "reviewed change", repo=wt)
        head = self.run_git(wt, "rev-parse", "HEAD")
        self.run_git(wt, "checkout", "-q", "--detach", "origin/main")
        self.run_git(wt, "merge", "-q", "--no-ff", "-m", "merge review/t1",
                     "-m", "Reviewed-by: fresh reviewer agent, %s..%s, 1 round" % (base[:7], head[:7]),
                     "review/t1")
        self.assertPass(self.hook("git push origin HEAD:main", cwd=wt))

    def test_unreviewed_commit_to_main_is_denied(self):
        self.commit("src/app.py", "x = 2\n", "unreviewed code")
        self.assertDeny(self.hook("git push origin main"), "unreviewed local commit pushed to main")

    def test_push_to_review_branch_passes(self):
        self.commit("src/app.py", "x = 2\n", "unreviewed code on main")
        self.git("checkout", "-q", "-b", "review/t2")
        self.assertPass(self.hook("git push -u origin review/t2"))
        self.assertPass(self.hook("git push"))

    def test_broken_config_fails_open(self):
        self.config(None, raw="{not json")
        self.commit("src/app.py", "x = 2\n", "unreviewed code")
        code, out, err = self.hook("git push origin main")
        self.assertEqual((code, out), (0, None))
        self.assertIn("push_guard_hook:", err)

    # More shapes of a push to main.

    def test_bare_push_on_main_is_denied(self):
        self.commit("src/app.py", "x = 2\n", "unreviewed code")
        self.assertDeny(self.hook("git push"), "unreviewed local commit")

    def test_refspec_shapes_are_denied(self):
        self.commit("src/app.py", "x = 2\n", "unreviewed code")
        for cmd in ("git push origin HEAD:main", "git push origin HEAD",
                    "git push -q origin +main", "git push origin x:refs/heads/main",
                    "cd /tmp && git -C %s push origin main" % self.repo,
                    "GIT_TRACE=0 git push --all origin",
                    "git push origin 'refs/heads/*:refs/heads/*'"):
            self.assertDeny(self.hook(cmd), "unreviewed local commit")

    def test_unsure_shapes_are_denied(self):
        # Shapes the hook cannot read for sure: it runs the guard on each.
        # The session's cwd is outside the repo, so none of them reads as a
        # bare push from the main checkout.
        self.commit("src/app.py", "x = 2\n", "unreviewed code")
        r = self.repo
        for cmd in ("cd %s && git push" % r,
                    "cd %s; git push --force-with-lease" % r,
                    "pushd %s && git push origin HEAD" % r,
                    'REPO=%s; MAIN=main; REMOTE=origin; git -C "$REPO" push "$REMOTE" "$MAIN"' % r,
                    'MAIN=main; git push origin "$MAIN"',
                    "git push origin HEAD:$(git rev-parse --abbrev-ref HEAD)",
                    "git push origin HEAD:`git rev-parse --abbrev-ref HEAD`",
                    "git --git-dir=%s/.git push origin HEAD" % r,
                    "git --git-dir %s/.git push origin HEAD" % r,
                    "git --work-tree=%s push origin HEAD" % r,
                    "GIT_DIR=%s/.git git push origin HEAD" % r,
                    "bash -c 'git push origin main'",
                    "sh -c 'git push origin main'",
                    "bash -lc 'cd %s && git push'" % r,
                    "eval 'git push origin main'",
                    "sudo git push origin main",
                    "sudo -u nobody git push origin main",
                    "env -i git push origin main",
                    "command git push origin main",
                    "echo main | xargs git push origin"):
            with self.subTest(cmd=cmd):
                self.assertDeny(self.hook(cmd, cwd=self.tmp), "unreviewed local commit")

    def test_guard_runs_from_the_project_root(self):
        # A cwd in a subdirectory still runs the guard on the project.
        self.commit("src/app.py", "x = 2\n", "unreviewed code")
        sub = os.path.join(self.repo, "src")
        self.assertDeny(self.hook("git push origin main", cwd=sub), "unreviewed local commit")

    def test_plain_review_branch_pushes_still_pass(self):
        # The wider net does not catch a push that is plainly elsewhere.
        self.commit("src/app.py", "x = 2\n", "unreviewed code on main")
        self.assertPass(self.hook("git push -u origin review/t3"))
        self.assertPass(self.hook("echo git push origin main"))
        self.assertPass(self.hook("git commit -m 'git push later'"))

    def test_docs_only_commit_to_main_passes(self):
        self.commit("notes/day.md", "two\n", "docs")
        self.assertPass(self.hook("git push origin main"))

    def test_configured_main_branch(self):
        self.config({"core": {"main_branch": "trunk", "review": {"push_hook": True}}})
        self.commit("src/app.py", "x = 2\n", "unreviewed code")
        # main is not the main branch now: a push to it is not checked.
        self.assertPass(self.hook("git push origin main"))

    def test_guard_failure_is_a_deny(self):
        # No origin: the guard cannot fetch and exits 2, which is a deny.
        self.git("remote", "rename", "origin", "elsewhere")
        self.assertDeny(self.hook("git push elsewhere main"), "exit 2")

    def test_bad_stdin_fails_open(self):
        code, out, err = self.hook("", stdin="not json")
        self.assertEqual((code, out), (0, None))
        self.assertIn("push_guard_hook:", err)

    def test_unbalanced_quotes_fail_open(self):
        code, out, err = self.hook("git push origin 'main")
        self.assertEqual((code, out), (0, None))
        self.assertIn("push_guard_hook:", err)

    # A push's source side is what is checked, not only the local main.

    def review_worktree(self, name="t9"):
        """A review worktree on review/<name> with one code commit: (path, base, head)."""
        base = self.git("rev-parse", "origin/main")
        wt = os.path.join(self.tmp, "repo-review", name)
        self.git("worktree", "add", "-q", "-b", "review/" + name, wt, "origin/main")
        self.commit("src/app.py", "x = 9\n", "code on the review branch", repo=wt)
        return wt, base, self.run_git(wt, "rev-parse", "HEAD")

    def test_review_branch_pushed_to_main_is_denied(self):
        # The local main is clean; the unreviewed commit is on review/t9.
        wt, _, _ = self.review_worktree()
        for cmd, cwd in (("git push origin review/t9:main", self.repo),
                         ("git push origin review/t9:refs/heads/main", wt),
                         ("git push origin HEAD:main", wt),
                         ("git -C %s push origin HEAD:main" % wt, self.repo),
                         ("cd %s && git push origin HEAD:main" % wt, self.repo)):
            with self.subTest(cmd=cmd):
                self.assertDeny(self.hook(cmd, cwd=cwd), "unreviewed local commit pushed to main")

    def test_documented_landing_push(self):
        # The landing recipe, with its variables set in the same command.
        wt, base, head = self.review_worktree()
        push = ('REPO=%s; MAIN=main; REMOTE=origin; T=review/t9; W=%s; '
                ': "${T:?}" "${W:?}"; git -C "$W" push "$REMOTE" HEAD:"$MAIN"' % (self.repo, wt))
        self.assertDeny(self.hook(push), "unreviewed local commit pushed to main")
        self.run_git(wt, "checkout", "-q", "--detach", "origin/main")
        self.run_git(wt, "merge", "-q", "--no-ff", "-m", "merge review/t9",
                     "-m", "Reviewed-by: fresh reviewer agent, %s..%s, 1 round" % (base[:7], head[:7]),
                     "review/t9")
        self.assertPass(self.hook(push))
        # Set twice, the variable cannot be read for sure: the hook then checks
        # the local main and the session's HEAD, both clean here.
        twice = 'W=/nowhere; W=%s; git -C "$W" push origin HEAD:main' % wt
        self.assertPass(self.hook(twice))

    def test_review_branch_pushed_to_itself_passes(self):
        wt, _, _ = self.review_worktree()
        self.assertPass(self.hook("git push -u origin review/t9", cwd=wt))
        self.assertPass(self.hook("git push origin review/t9:review/t9"))
        self.assertPass(self.hook('W=%s; T=review/t9; git -C "$W" push -u origin "$T"' % wt))

    def test_master_repo_lands_its_first_config(self):
        # A repo whose main branch is master, no config on the remote yet, the
        # hook on: the landing of the config is allowed, and the guard passes.
        origin = os.path.join(self.tmp, "m.git")
        repo = os.path.join(self.tmp, "m")
        self.run_git(self.tmp, "init", "-q", "--bare", "-b", "master", origin)
        self.run_git(self.tmp, "clone", "-q", origin, repo)
        self.commit("src/app.py", "x = 1\n", "base", repo=repo)
        self.run_git(repo, "push", "-q", "origin", "master")
        cfg = json.dumps({"core": {"main_branch": "master", "review": {"push_hook": True}}})
        base = self.run_git(repo, "rev-parse", "HEAD")
        wt = os.path.join(self.tmp, "m-review", "cfg")
        self.run_git(repo, "worktree", "add", "-q", "-b", "review/cfg", wt, "origin/master")
        for d in (repo, wt):
            os.makedirs(os.path.join(d, ".claude"), exist_ok=True)
            with open(os.path.join(d, ".claude", "studio.json"), "w", encoding="utf-8") as f:
                f.write(cfg)
        self.run_git(wt, "add", ".claude/studio.json")
        self.run_git(wt, "commit", "-q", "-m", "the studio config")
        head = self.run_git(wt, "rev-parse", "HEAD")
        self.run_git(wt, "checkout", "-q", "--detach", "origin/master")
        self.run_git(wt, "merge", "-q", "--no-ff", "-m", "merge review/cfg",
                     "-m", "Reviewed-by: fresh reviewer agent, %s..%s, 1 round" % (base[:7], head[:7]),
                     "review/cfg")
        env = dict(ENV, CLAUDE_PROJECT_DIR=repo)
        payload = json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash", "cwd": repo,
                              "tool_input": {"command": "git -C %s push origin HEAD:master" % wt}})
        proc = subprocess.run([sys.executable, HOOK], input=payload, env=env, cwd=repo,
                              capture_output=True, text=True)
        self.assertEqual((proc.returncode, proc.stdout.strip()), (0, ""), proc)
        guard = os.path.join(os.path.dirname(HOOK), "review_guard.sh")
        proc = subprocess.run(["bash", guard, "push"], cwd=repo, env=ENV,
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc)

    def test_grep_for_git_push_runs_no_guard(self):
        # With an unreviewed commit on main, a guard run would deny: these pass
        # because no guard runs. A remote that cannot be reached would deny too.
        self.commit("src/app.py", "x = 2\n", "unreviewed code")
        self.git("remote", "set-url", "origin", os.path.join(self.tmp, "gone.git"))
        for cmd in ('grep -rn "git push" .', "rg 'git push origin main' docs/",
                    'grep -n "git push" README.md | head -5'):
            with self.subTest(cmd=cmd):
                self.assertPass(self.hook(cmd))
        # A command substitution still runs, wherever it stands.
        self.git("remote", "set-url", "origin", self.origin)
        for cmd in ('echo "$(git push origin main)"', 'x="$(git push origin main)"',
                    "bash -o pipefail -c 'git push origin main'"):
            with self.subTest(cmd=cmd):
                self.assertDeny(self.hook(cmd, cwd=self.tmp), "unreviewed local commit")

    def test_hooks_json_wires_the_hook(self):
        with open(HOOKS_JSON, encoding="utf-8") as f:
            data = json.load(f)
        groups = data["hooks"]["PreToolUse"]
        self.assertEqual(groups[0]["matcher"], "Bash")
        h = groups[0]["hooks"][0]
        self.assertEqual(h["type"], "command")
        self.assertEqual(h["command"], 'python3 "${CLAUDE_PLUGIN_ROOT}/scripts/push_guard_hook.py"')


if __name__ == "__main__":
    unittest.main()
