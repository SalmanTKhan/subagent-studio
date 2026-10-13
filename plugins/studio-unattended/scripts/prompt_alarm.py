#!/usr/bin/env python3
"""Prompt alarm: a Claude Code Notification hook for the permission_prompt
type.

Claude Code fires it when an approval prompt has waited a few seconds, so
the permission gate did not decide. In a scheduled run nobody is there to
click, so it sends an alarm to the `needs-human` channel through notify.sh
(beside this file) at once, at most once per session per 30 minutes (state
in prompt-alarm-state.json in $CLAUDE_PLUGIN_DATA, else
~/.config/subagent-studio; {session id: posted epoch}). It posts only when
the transcript shows a scheduled run (its first real prompt starts with
unattended.scheduled_prompt_prefix); an attended or unknown session is left
alone (the gate, by contrast, treats unknown as unattended). When notify is
not configured (no webhook, or no `needs-human` channel) it skips quietly
and logs the skip.
Input (stdin): session_id, transcript_path, cwd, hook_event_name
"Notification", message, optional title, notification_type.
Logs to permission-gate.log in the same data folder. STUDIO_NOTIFY
overrides the notify script (tests). Always exits 0.
Python 3.9, standard library only.
"""
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate_common  # noqa: E402

LOG = "permission-gate.log"
STATE = "prompt-alarm-state.json"
DEDUPE_SECONDS = 30 * 60
NOTIFY_TIMEOUT = 20

# notify.sh exit codes that mean "not configured", not "failed"
NOT_CONFIGURED = {2: "no needs-human channel configured", 3: "no webhook configured"}

CHECKLIST = (
    "1. Open Claude Code and find the session asking for approval.\n"
    "2. Click Allow once (Deny also works; the run carries on either way).\n"
    "3. Reply here when done, so the next run can check."
)


def alarm_text(plain_name):
    return ("URGENT: NEEDS HUMAN — {} is waiting for an approval click "
            "— deadline now — why: it cannot go on until someone answers\n"
            .format(plain_name) + CHECKLIST)


def load_state(path):
    try:
        with open(path) as f:
            state = json.load(f)
        return state if isinstance(state, dict) else {}
    except Exception:
        return {}


def main():
    data = {}
    try:
        data = json.loads(sys.stdin.read() or "{}")
        if not isinstance(data, dict):
            data = {}
        ntype = data.get("notification_type") or "permission_prompt"
        sid = data.get("session_id") or "unknown"
        rec = {"event": "notification", "session_id": sid, "notification_type": ntype}
        if ntype != "permission_prompt":
            gate_common.log_line(LOG, dict(rec, decision="alarm-skip", rule="not a permission prompt"))
            return
        transcript = data.get("transcript_path")
        mark = gate_common.scheduled_mark(gate_common.load_config(data.get("cwd")))
        scheduled = gate_common.is_scheduled(transcript, mark)
        rec["unattended"] = scheduled
        if not scheduled:
            gate_common.log_line(LOG, dict(rec, decision="alarm-skip", rule="not a scheduled run"))
            return
        state_path = os.path.join(gate_common.data_dir(), STATE)
        state = load_state(state_path)
        now = time.time()
        state = {k: v for k, v in state.items() if isinstance(v, (int, float)) and now - v < 86400}
        if now - state.get(sid, 0) < DEDUPE_SECONDS:
            gate_common.log_line(LOG, dict(rec, decision="alarm-skip", rule="posted in the last 30 min"))
            return
        notify = os.environ.get("STUDIO_NOTIFY") or os.path.join(gate_common.HERE, "notify.sh")
        if not os.path.isfile(notify):
            gate_common.log_line(LOG, dict(rec, decision="alarm-skip", rule="notify.sh not found"))
            return
        text = alarm_text(gate_common.plain_run_name(gate_common.task_name(transcript, mark)))
        cmd = [notify, "needs-human", text]
        if not os.access(notify, os.X_OK):
            cmd = ["bash"] + cmd
        try:
            env = dict(os.environ)
            root = gate_common.project_root(data.get("cwd"))
            if root:
                env["CLAUDE_PROJECT_DIR"] = root   # notify.sh reads this project's config
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=NOTIFY_TIMEOUT, env=env)
            if p.returncode in NOT_CONFIGURED:
                gate_common.log_line(LOG, dict(rec, decision="alarm-skip",
                                               rule="notify not configured: " + NOT_CONFIGURED[p.returncode]))
                return
            ok, detail = p.returncode == 0, "exit {}: {}".format(p.returncode, (p.stderr or "").strip()[:200])
        except Exception as e:
            ok, detail = False, "{}: {}".format(type(e).__name__, str(e)[:200])
        if ok:
            state[sid] = now
            with open(state_path, "w") as f:
                json.dump(state, f)
            gate_common.log_line(LOG, dict(rec, decision="alarm-posted", rule="unattended prompt"))
        else:
            gate_common.log_line(LOG, dict(rec, decision="alarm-failed", rule=detail))
    except Exception as e:
        gate_common.log_line(LOG, {"event": "notification", "decision": "alarm-error",
                                   "rule": "{}: {}".format(type(e).__name__, str(e)[:200])})


if __name__ == "__main__":
    try:
        main()
    finally:
        sys.exit(0)
