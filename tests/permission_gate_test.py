#!/usr/bin/env python3
"""Tests for studio-unattended's permission gate and prompt alarm.
  python3 kit/tests/permission_gate_test.py
Standard library only (unittest). Each hook runs as a subprocess, the way
Claude Code runs it, with CLAUDE_PLUGIN_DATA, CLAUDE_PROJECT_DIR and
STUDIO_NOTIFY pointed at a temp dir: nothing is posted and ~/.config is not
touched."""
import json
import os
import subprocess
import sys
import tempfile
import unittest

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(KIT, "plugins", "studio-unattended", "scripts")
GATE = os.path.join(SCRIPTS, "permission_gate.py")
ALARM = os.path.join(SCRIPTS, "prompt_alarm.py")
NOTIFY = os.path.join(SCRIPTS, "notify.sh")
sys.path.insert(0, SCRIPTS)
import gate_common  # noqa: E402
import prompt_alarm  # noqa: E402

MARK = "<scheduled-task"

# a loop that unlinks symlinks in a worktree: a real prompt that once stalled a run
TRIGGER = (
    'W=/srv/wt/t12; for f in packages/core/node_modules apps/web/node_modules '
    'apps/web/.auth; do p="$W/$f"; '
    'if [ -L "$p" ]; then rm "$p"; echo "unlinked $f"; elif [ -e "$p" ]; then echo "REAL $f"; fi; '
    "done; sed -n 1,40p docs/landing.md | grep -n "
    "'worktree remove\\|branch -d\\|push origin --delete\\|ancestor' ")

SCHEDULED_HEAD = ('{"type":"user","message":{"role":"user","content":"<scheduled-task '
                  'name=\\"nightly-build\\" file=\\"/x/SKILL.md\\">\\nRead CLAUDE.md"}}\n')
MARKER_TEXT = '<scheduled-task name="wake-up" file="/x/SKILL.md">\nRead CLAUDE.md'


def jl(*records):
    return "".join(json.dumps(r) + "\n" for r in records)


# a person's session that read a file quoting the marker
PERSON_QUOTING = jl(
    {"type": "queue-operation", "operation": "dequeue"},
    {"type": "user", "isMeta": True, "message": {"content": MARKER_TEXT}},
    {"type": "attachment", "attachment": {"content": MARKER_TEXT}},
    {"type": "user", "message": {"role": "user", "content": "Why did the last wake-up hang?"}},
    {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Read"}]}},
    {"type": "user", "message": {"content": [{"type": "tool_result", "content": MARKER_TEXT}]}})


class HookCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = os.path.realpath(self.tmp.name)
        self.data = os.path.join(self.dir, "data")
        self.work = os.path.join(self.dir, "work")
        self.proj = os.path.join(self.work, "proj")
        self.wt = os.path.join(self.work, "proj-review")   # the default worktree root
        os.makedirs(os.path.join(self.proj, ".git"))
        os.makedirs(os.path.join(self.proj, ".claude"))
        self.sched = self.write("sched.jsonl", SCHEDULED_HEAD + '{"type":"assistant"}\n')
        self.attended = self.write("att.jsonl", '{"type":"user","message":{"content":"hi"}}\n')
        self.posted = os.path.join(self.dir, "posted.txt")
        self.notify = self.write("notify.sh", '#!/bin/sh\nprintf "%s|%s\\n" "$1" "$2" >> "{}"\n'
                                 .format(self.posted))
        os.chmod(self.notify, 0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, text):
        p = os.path.join(self.dir, name)
        with open(p, "w") as f:
            f.write(text)
        return p

    def config(self, cfg):
        with open(os.path.join(self.proj, ".claude", "studio.json"), "w") as f:
            json.dump(cfg, f)

    def env(self, **extra):
        e = dict(os.environ, CLAUDE_PLUGIN_DATA=self.data, STUDIO_NOTIFY=self.notify,
                 CLAUDE_PROJECT_DIR=self.proj)
        for k, v in extra.items():
            if v is None:
                e.pop(k, None)
            else:
                e[k] = v
        return e

    def run_hook(self, script, stdin, **extra_env):
        p = subprocess.run([sys.executable, script], input=stdin, capture_output=True,
                           text=True, timeout=30, env=self.env(**extra_env))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn("Traceback", p.stderr)
        return p.stdout.strip()

    def gate(self, tool, tool_input=None, transcript=None, cwd=None,
             mode="bypassPermissions", **extra_env):
        data = {"session_id": "s1", "transcript_path": transcript or self.sched,
                "cwd": cwd or self.proj, "hook_event_name": "PermissionRequest",
                "permission_mode": mode, "tool_name": tool,
                "tool_input": tool_input or {}}
        if mode is None:
            del data["permission_mode"]
        out = self.run_hook(GATE, json.dumps(data), **extra_env)
        if not out:
            return None, None
        d = json.loads(out)["hookSpecificOutput"]
        self.assertEqual(d["hookEventName"], "PermissionRequest")
        return d["decision"]["behavior"], d["decision"].get("message")

    def bash(self, cmd, transcript=None, **kw):
        return self.gate("Bash", {"command": cmd}, transcript, **kw)[0]

    def log(self):
        with open(os.path.join(self.data, "permission-gate.log")) as f:
            return [json.loads(l) for l in f]


class Unattended(HookCase):
    def test_person_quoting_marker_is_attended(self):
        t = self.write("person.jsonl", PERSON_QUOTING)
        self.assertFalse(gate_common.is_unattended(t, MARK))
        self.assertEqual(self.gate("AskUserQuestion", {}, t), (None, None))

    def test_scheduled_prompt_shapes(self):
        shapes = {
            "string": jl({"type": "user", "message": {"content": MARKER_TEXT}}),
            "blocks": jl({"type": "user", "message": {"content": [
                {"type": "text", "text": "  \n" + MARKER_TEXT}]}}),
            "queued": jl({"type": "queue-operation", "operation": "enqueue", "content": MARKER_TEXT},
                         {"type": "queue-operation", "operation": "dequeue"},
                         {"type": "user", "message": {"content": MARKER_TEXT}}),
            "after-attachments": jl({"type": "attachment", "attachment": {}},
                                    {"type": "user", "isMeta": True, "message": {"content": "x"}},
                                    {"type": "user", "message": {"content": MARKER_TEXT}}),
        }
        for name, text in shapes.items():
            t = self.write(name + ".jsonl", text)
            self.assertTrue(gate_common.is_unattended(t, MARK), name)
            self.assertEqual(gate_common.task_name(t, MARK), "wake-up", name)

    def test_marker_not_at_start_is_attended(self):
        t = self.write("mid.jsonl", jl({"type": "user", "message": {
            "content": "look at this: " + MARKER_TEXT}}))
        self.assertFalse(gate_common.is_unattended(t, MARK))

    def test_person_subagent_is_attended(self):
        os.makedirs(os.path.join(self.dir, "p", "subagents"))
        self.write("p.jsonl", PERSON_QUOTING)
        sub = self.write(os.path.join("p", "subagents", "agent-1.jsonl"),
                         jl({"type": "user", "message": {"content": "Fix the finding"}}))
        self.assertFalse(gate_common.is_unattended(sub, MARK))

    def test_configured_prefix(self):
        self.config({"unattended": {"scheduled_prompt_prefix": "[cron-run]"}})
        cron = self.write("cron.jsonl", jl({"type": "user", "message": {
            "content": '[cron-run] name="nightly"\nfollow the wake-up skill'}}))
        self.assertEqual(self.gate("AskUserQuestion", {}, cron)[0], "deny")
        # the default prefix no longer counts as unattended
        self.assertEqual(self.gate("AskUserQuestion", {}, self.sched), (None, None))
        self.assertEqual(gate_common.task_name(cron, "[cron-run]"), "nightly")


class GateBash(HookCase):
    def test_trigger(self):
        self.assertEqual(self.bash(TRIGGER), "allow")
        self.assertEqual(self.gate("Bash", {"command": TRIGGER}, self.attended), (None, None))

    def test_attended_makes_no_decision_even_on_dangerous(self):
        # a person can answer: the gate never blocks interactive work
        for cmd in ["git push --force-with-lease", "sudo apt-get install jq",
                    "rm -rf ~/.cache", 'rm -rf "$W"', "zsh -c 'rm -rf ~'", "ls"]:
            self.assertEqual(self.gate("Bash", {"command": cmd}, self.attended,
                                       mode="default"), (None, None), cmd)
            self.assertEqual(self.log()[-1]["decision"], "none")
            self.assertEqual(self.log()[-1]["rule"], "attended")

    def test_unattended_still_denies_dangerous(self):
        for cmd in ["git push --force-with-lease", "sudo apt-get install jq",
                    "rm -rf ~/.cache", 'rm -rf "$W"', "zsh -c 'rm -rf ~'"]:
            b, m = self.gate("Bash", {"command": cmd})
            self.assertEqual(b, "deny", cmd)
            self.assertIn("git worktree remove --force", m)

    def test_wrapped_deletes_denied(self):
        for cmd in ["zsh -c 'rm -rf ~'", 'bash -c \'rm -rf "$W"\'', 'sh -c "rm -rf $W"',
                    'bash -lc "cd x && rm -rf $W"', 'eval "rm -rf $W"', "eval rm -rf '~'",
                    "bash -c \"sh -c 'rm -rf /'\"", 'find "$W" -delete',
                    "find . -exec rm -rf {} +", "find -name x -delete",
                    "find ~ -type d -execdir rm -r {} \\;", "find {} -delete".format(self.wt),
                    "find /private/tmp/claude-501 -delete"]:
            self.assertEqual(self.bash(cmd), "deny", cmd)

    def test_wrapped_safe_commands_allowed(self):
        for cmd in ["bash -c 'echo hi'", "zsh -lc 'rm -rf {}/t12'".format(self.wt),
                    'eval "$(ssh-agent -s)"', "find . -name '*.pyc'",
                    "find . -name x -exec rm -f {} \\;",
                    "find {}/t12 -name node_modules -exec rm -rf {{}} +".format(self.wt),
                    "find /srv/x/proj -name '*.log' -delete"]:
            self.assertEqual(self.bash(cmd), "allow", cmd)

    def test_ordinary_commands_allowed(self):
        for cmd in ['f() { git -C "$(git rev-parse --show-toplevel)" status; }; f',
                    ': "${T:?}" "${W:?}"; echo "$W"',
                    "grep -n foo TASKS.md | head -3",
                    'rm "$p"', "rm -f $HOME/x.txt", "rm -rf node_modules",
                    "git push origin main", "git push -u origin review/2026-09-26-t12",
                    "git push --force origin review/x", "echo sudo is a word",
                    "git push origin --delete review/2026-09-26-t12", "git push origin :review/x",
                    "git push -o ci.skip origin review/x"]:
            self.assertEqual(self.bash(cmd), "allow", cmd)

    def test_recursive_rm_denied(self):
        for cmd in ['rm -rf "$W"', "rm -rf /", "rm -fr ~", "rm -Rf $HOME", "rm -r ${HOME}/",
                    "rm --recursive .", "rm -rf ..", "rm -rf *", "rm -rf /*", 'rm -rf "${W:?}"',
                    "rm -rf $(pwd)/x", "rm -rf `pwd`", "cd x && rm -r -f -- $d",
                    "rm -rf {}/$T".format(self.wt), "rm -rf {}/*".format(self.wt),
                    "ls | xargs rm -rf", "for p in a b; do rm -rf \"$p\"; done",
                    "x=$(rm -rf ~)"]:
            behavior, message = self.gate("Bash", {"command": cmd})
            self.assertEqual(behavior, "deny", cmd)
            self.assertIn("permission gate refused", message)
            self.assertIn("git worktree remove --force", message)

    def test_literal_scratch_paths_allowed(self):
        for cmd in ["rm -rf {}/t12".format(self.wt), "rm -rf {}/t12/node_modules".format(self.wt),
                    "rm -rf /private/tmp/claude-501/abc/scratchpad/out",
                    "rm -rf /private/tmp/claude-501/-home-x/0a1b-sid",
                    "rm -rf /tmp/claude-501/-home-x/0a1b-sid/scratchpad/*"]:
            self.assertEqual(self.bash(cmd), "allow", cmd)

    def test_scratch_roots_denied(self):
        for cmd in ["rm -rf /private/tmp/claude-501", "rm -rf /private/tmp/claude-501/",
                    "rm -rf /private/tmp/claude-501/-home-x", "rm -rf /tmp/claude-501/*/sid",
                    "rm -rf /private/tmp/claude-501/-home-x/*", "rm -rf /private/tmp",
                    "rm -rf /private/tmp/claude-501/a/../b",
                    "rm -rf " + self.wt, "rm -rf {}/".format(self.wt),
                    'rm -rf "{}"'.format(self.wt), "rm -rf {}/t*".format(self.wt)]:
            self.assertEqual(self.bash(cmd), "deny", cmd)

    def test_configured_worktree_root(self):
        wt = os.path.join(self.dir, "trees", "wt")
        self.config({"core": {"worktree_root": wt}})
        self.assertEqual(self.bash("rm -rf " + wt), "deny")
        self.assertEqual(self.bash("rm -rf {}/*".format(wt)), "deny")
        self.assertEqual(self.bash("rm -rf " + os.path.dirname(wt)), "deny")
        self.assertEqual(self.bash("rm -rf {}/t12".format(wt)), "allow")
        # relative to the project root
        self.config({"core": {"worktree_root": "../trees2"}})
        self.assertEqual(self.bash("rm -rf " + os.path.join(self.work, "trees2")), "deny")
        self.assertEqual(self.bash("rm -rf " + os.path.join(self.work, "trees2", "t12")), "allow")

    def test_other_denials(self):
        for cmd in ["sudo rm x", "ls && sudo -n true", "git push --force origin main",
                    "git push -f origin HEAD:main", "git -C /x push --force-with-lease origin main",
                    "git push origin +main", "git push origin --delete main", "git push origin -d main",
                    "git push origin :main", "git push origin :refs/heads/main",
                    "git push --force", "git push -f origin", "git push --force-with-lease",
                    "mkfs.ext4 /dev/disk9", "diskutil eraseDisk APFS X disk9",
                    "dd if=/dev/zero of=/dev/disk9 bs=1m"]:
            self.assertEqual(self.bash(cmd), "deny", cmd)

    def test_configured_main_branch(self):
        self.config({"core": {"main_branch": "trunk"}})
        self.assertEqual(self.bash("git push --force origin trunk"), "deny")
        self.assertEqual(self.bash("git push origin :trunk"), "deny")
        self.assertEqual(self.bash("git push --force origin main"), "allow")

    def test_wide_literal_deletes_denied(self):
        home = os.path.expanduser("~")
        for cmd in ["rm -rf {}/*".format(home), "rm -rf /tmp/*", "rm -rf /private/tmp/*",
                    "rm -rf ~/Documents", "rm -rf ~/.config", "rm -rf $HOME/.config/",
                    'rm -rf "${HOME}/Documents"', "rm -rf '~/Documents'", "rm -rf ~/Documents/*",
                    "rm -rf " + self.proj, "rm -rf {}/".format(self.proj),
                    "rm -rf {}/*".format(self.proj), "rm -rf " + self.work,
                    "rm -rf /home", "rm -rf /home/", "rm -rf /srv/someone", "rm -rf /h*",
                    "rm -rf /private", "rm -rf /var",
                    "rm -rf " + home, "rm -rf {}/Library".format(home), "rm -rf //home",
                    "rm -rf {}/t12/../../proj".format(self.wt), "rm -rf ../..", "rm -rf ../x",
                    "env -i rm -rf ~", "command -p rm -rf ~", "nice -n 10 rm -rf ~",
                    "nohup rm -rf /home", "time -p rm -rf ~", "exec rm -rf ~",
                    "env -u PATH A=1 rm -rf ~", "env -- rm -rf ~", "/usr/bin/env -i rm -rf ~",
                    "env -S 'rm -rf ~'", "find ~/Documents -delete"]:
            self.assertEqual(self.bash(cmd), "deny", cmd)

    def test_project_dir_and_cwd_repo_roots_protected(self):
        proj = os.path.join(self.dir, "a", "b", "proj")
        os.makedirs(os.path.join(proj, ".git"))
        for cmd in ["rm -rf " + proj, "rm -rf " + os.path.dirname(proj), "rm -rf {}/*".format(proj)]:
            self.assertEqual(self.bash(cmd, CLAUDE_PROJECT_DIR=proj), "deny", cmd)
            self.assertEqual(self.bash(cmd, cwd=proj, CLAUDE_PROJECT_DIR=None), "deny", cmd)
        self.assertEqual(self.bash("rm -rf {}/build".format(proj), cwd=proj,
                                   CLAUDE_PROJECT_DIR=None), "allow")

    def test_configured_protected_paths(self):
        keep = os.path.join(self.dir, "data", "keep", "this")
        self.config({"unattended": {"permission_gate": {"protected_paths": [keep, "vendor/lib"]}}})
        for cmd in ["rm -rf " + keep, "rm -rf " + os.path.dirname(keep), "rm -rf {}/*".format(keep),
                    "rm -rf {}/vendor/lib".format(self.proj)]:
            self.assertEqual(self.bash(cmd), "deny", cmd)
        self.assertEqual(self.bash("rm -rf {}/sub".format(keep)), "allow")
        self.assertEqual(self.bash("rm -rf {}/vendor/other".format(self.proj)), "allow")
        # a relative target is checked only for "." and a climb out: the shell
        # may have changed folder first, so it is not resolved against cwd
        self.assertEqual(self.bash("rm -rf vendor"), "allow")

    def test_narrow_literal_deletes_allowed(self):
        for cmd in ["rm -rf {}/t12".format(self.wt),
                    "rm -rf /private/tmp/claude-501/-home-x/0a1b-sid/scratchpad/out/*",
                    "rm -r apps/x/build", "rm -rf ./apps/x/build",
                    "rm -rf {}/apps/x/build".format(self.proj),
                    "env -i rm -rf {}/t12".format(self.wt), "nice -n 5 rm -rf apps/x/build",
                    "env FOO=1 ls", "command -v rm"]:
            self.assertEqual(self.bash(cmd), "allow", cmd)

    def test_force_push_of_head_denied(self):
        for cmd in ["git push --force origin HEAD", "git push -f origin @",
                    "git -C {} push --force-with-lease origin HEAD".format(self.proj),
                    "git push origin +HEAD", "git push origin +main", "git push -f origin HEAD:main",
                    "git push --force --all origin", "git push --force origin"]:
            self.assertEqual(self.bash(cmd), "deny", cmd)
        for cmd in ["git push origin HEAD", "git push --force origin HEAD:review/x",
                    "git push -f origin review/x"]:
            self.assertEqual(self.bash(cmd), "allow", cmd)

    def test_bash_log_line(self):
        self.bash("echo " + "x" * 400)
        rec = self.log()[-1]
        self.assertEqual(rec["tool"], "Bash")
        self.assertEqual(rec["decision"], "allow")
        self.assertTrue(rec["unattended"])
        self.assertEqual(len(rec["command"]), 300)
        for key in ("ts", "session_id", "rule"):
            self.assertIn(key, rec)


class GateOtherTools(HookCase):
    def test_ask_user_question(self):
        b, m = self.gate("AskUserQuestion", {"questions": []})
        self.assertEqual(b, "deny")
        self.assertIn("nobody can answer", m)
        self.assertEqual(self.gate("AskUserQuestion", {}, self.attended), (None, None))
        self.assertEqual(self.log()[-1]["decision"], "none")

    def test_scheduled_tasks(self):
        for verb in ("create", "delete", "run"):
            b, m = self.gate("mcp__scheduled-tasks__{}_scheduled_task".format(verb))
            self.assertEqual(b, "deny", verb)
            self.assertIn("may not create or change scheduled tasks", m)
            self.assertEqual(self.gate("mcp__scheduled-tasks__{}_scheduled_task".format(verb),
                                       transcript=self.attended), (None, None))
        self.assertEqual(self.gate("mcp__scheduled-tasks__update_scheduled_task")[0], "allow")
        self.assertEqual(self.gate("mcp__scheduled-tasks__list_scheduled_tasks")[0], "allow")

    def test_configured_deny_messages(self):
        self.config({"unattended": {"permission_gate": {
            "deny_message_ask": "Decide it yourself.", "deny_message_schedule": "Leave schedules alone."}}})
        self.assertEqual(self.gate("AskUserQuestion", {}), ("deny", "Decide it yourself."))
        self.assertEqual(self.gate("mcp__scheduled-tasks__create_scheduled_task"),
                         ("deny", "Leave schedules alone."))

    def test_disabled_gate_makes_no_decision(self):
        self.config({"unattended": {"permission_gate": {"enabled": False}}})
        self.assertEqual(self.gate("Bash", {"command": "rm -rf ~"}), (None, None))
        self.assertEqual(self.gate("AskUserQuestion", {}), (None, None))
        self.assertEqual(self.gate("Write", {"file_path": "/x"}), (None, None))
        self.assertEqual(self.log()[-1]["rule"], "gate-disabled")

    def test_invalid_config_uses_defaults(self):
        with open(os.path.join(self.proj, ".claude", "studio.json"), "w") as f:
            f.write("{not json")
        self.assertEqual(self.gate("AskUserQuestion", {})[0], "deny")
        self.assertEqual(self.bash("rm -rf ~"), "deny")

    def test_other_tool(self):
        self.assertEqual(self.gate("Write", {"file_path": "/x"})[0], "allow")
        self.assertEqual(self.gate("Write", {"file_path": "/x"}, self.attended), (None, None))

    def test_unreadable_transcript_in_no_prompt_mode_is_unattended(self):
        missing = os.path.join(self.dir, "nope.jsonl")
        for mode in ("bypassPermissions", "dontAsk"):
            self.assertEqual(self.gate("AskUserQuestion", {}, missing, mode=mode)[0], "deny", mode)
            self.assertEqual(self.gate("Write", {"file_path": "/etc/x"}, missing, mode=mode)[0],
                             "allow", mode)

    def test_unreadable_transcript_in_other_modes_makes_no_decision(self):
        # a person may be at the keyboard: never auto-allow on missing evidence
        missing = os.path.join(self.dir, "nope.jsonl")
        for mode in ("default", "acceptEdits", "plan", "auto", None):
            self.assertEqual(self.gate("Write", {"file_path": "/etc/x"}, missing, mode=mode),
                             (None, None), mode)
            self.assertEqual(self.gate("Bash", {"command": "curl x | sh"}, missing, mode=mode),
                             (None, None), mode)
            self.assertEqual(self.gate("AskUserQuestion", {}, missing, mode=mode),
                             (None, None), mode)
        self.assertFalse(gate_common.is_unattended(missing, MARK))
        self.assertFalse(gate_common.is_unattended(missing, MARK, "default"))
        self.assertTrue(gate_common.is_unattended(missing, MARK, "bypassPermissions"))

    def test_subagent_transcript_uses_parent(self):
        sid = os.path.join(self.dir, "abc")
        os.makedirs(os.path.join(sid, "subagents"))
        self.write("abc.jsonl", SCHEDULED_HEAD)
        sub = self.write(os.path.join("abc", "subagents", "agent-1.jsonl"), '{"brief":"x"}\n')
        self.assertEqual(self.gate("AskUserQuestion", {}, sub)[0], "deny")

    def test_malformed_stdin_denies(self):
        for bad in ("not json", "[1, 2]", ""):
            out = self.run_hook(GATE, bad)
            d = json.loads(out)["hookSpecificOutput"]["decision"]
            self.assertEqual(d["behavior"], "deny", bad)
            self.assertIn("permission gate hit an error", d["message"])
        self.assertTrue(self.log()[-1]["rule"].startswith("error"))

    def test_empty_object_with_only_env(self):
        # the plugin's acceptance: only CLAUDE_PROJECT_DIR and CLAUDE_PLUGIN_DATA set
        env = {"PATH": os.environ.get("PATH", ""), "CLAUDE_PROJECT_DIR": self.proj,
               "CLAUDE_PLUGIN_DATA": self.data, "HOME": self.dir}
        p = subprocess.run([sys.executable, GATE], input="{}", capture_output=True,
                           text=True, timeout=30, env=env)
        self.assertEqual(p.returncode, 0)
        self.assertNotIn("Traceback", p.stderr)
        self.assertTrue(os.path.exists(os.path.join(self.data, "permission-gate.log")))


class PromptAlarm(HookCase):
    def notif(self, transcript, sid="s9"):
        return json.dumps({"session_id": sid, "transcript_path": transcript, "cwd": self.proj,
                           "hook_event_name": "Notification", "message": "Claude needs your permission",
                           "notification_type": "permission_prompt"})

    def posts(self):
        if not os.path.exists(self.posted):
            return []
        with open(self.posted) as f:
            return f.read().split("needs-human|")[1:]

    def test_unattended_posts_once_per_session(self):
        self.run_hook(ALARM, self.notif(self.sched))
        self.run_hook(ALARM, self.notif(self.sched))
        posts = self.posts()
        self.assertEqual(len(posts), 1)
        self.assertIn('the scheduled run "nightly-build" is waiting for an approval click', posts[0])
        self.run_hook(ALARM, self.notif(self.sched, sid="other"))
        self.assertEqual(len(self.posts()), 2)
        rules = [r["decision"] for r in self.log()]
        self.assertEqual(rules, ["alarm-posted", "alarm-skip", "alarm-posted"])
        self.assertTrue(os.path.exists(os.path.join(self.data, "prompt-alarm-state.json")))

    def test_attended_silent(self):
        self.run_hook(ALARM, self.notif(self.attended))
        self.assertEqual(self.posts(), [])

    def test_unknown_session_silent(self):
        # the gate treats an unreadable transcript as unattended; the alarm posts
        # only when the transcript shows a scheduled run
        empty = self.write("empty.jsonl", "")
        for t in (os.path.join(self.dir, "missing.jsonl"), empty, None):
            self.run_hook(ALARM, self.notif(t))
        self.assertEqual(self.posts(), [])
        self.assertEqual({r["rule"] for r in self.log()}, {"not a scheduled run"})

    def test_notify_not_configured_skips_quietly(self):
        # the real notify.sh with an empty HOME: no webhook, exit 3
        home = os.path.join(self.dir, "home")
        os.makedirs(home)
        self.run_hook(ALARM, self.notif(self.sched), STUDIO_NOTIFY=NOTIFY, HOME=home)
        rec = self.log()[-1]
        self.assertEqual(rec["decision"], "alarm-skip")
        self.assertIn("notify not configured", rec["rule"])
        # a config without a needs-human channel: exit 2, also a quiet skip
        self.config({"unattended": {"notify": {"channels": ["ops"]}}})
        self.run_hook(ALARM, self.notif(self.sched, sid="s10"), STUDIO_NOTIFY=NOTIFY, HOME=home)
        self.assertIn("notify not configured", self.log()[-1]["rule"])

    def test_notify_failure_is_logged(self):
        bad = self.write("bad.sh", "#!/bin/sh\nexit 22\n")
        os.chmod(bad, 0o755)
        self.run_hook(ALARM, self.notif(self.sched), STUDIO_NOTIFY=bad)
        self.assertEqual(self.log()[-1]["decision"], "alarm-failed")

    def test_bad_input_exits_zero(self):
        self.run_hook(ALARM, "garbage")


class MessageTexts(unittest.TestCase):
    def test_alarm_text_shape(self):
        text = prompt_alarm.alarm_text('the scheduled run "wake-up"')
        first, rest = text.split("\n", 1)
        self.assertTrue(first.startswith("URGENT: NEEDS HUMAN — "), first)
        self.assertIn(" — deadline ", first)
        self.assertIn(" — why: ", first)
        self.assertTrue(rest.startswith("1. "))
        self.assertIn("\n2. ", rest)

    def test_plain_run_name(self):
        self.assertEqual(gate_common.plain_run_name(""), "a scheduled run")
        self.assertEqual(gate_common.plain_run_name("wake-up"), 'the scheduled run "wake-up"')


if __name__ == "__main__":
    unittest.main(verbosity=1)
