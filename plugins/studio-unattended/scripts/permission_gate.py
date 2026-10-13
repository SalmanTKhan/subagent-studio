#!/usr/bin/env python3
"""Permission gate: a Claude Code PermissionRequest hook.

Scheduled runs use bypassPermissions, yet Claude Code's residual safety
checks still raise an approval prompt now and then, and a scheduled run then
waits for a click nobody gives. This hook answers those prompts itself.

Input (stdin, per the hooks reference): session_id, transcript_path, cwd,
permission_mode, hook_event_name "PermissionRequest", tool_name, tool_input,
optional permission_suggestions.
Output (stdout, exit 0):
  {"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                          "decision": {"behavior": "allow"}}}
  or "behavior": "deny" with a "message" telling Claude how to rewrite.
No output = no decision: the prompt shows as before.

Rules (unattended = the session's first real prompt starts with
unattended.scheduled_prompt_prefix, default "<scheduled-task", or the
transcript cannot be read and permission_mode is bypassPermissions or
dontAsk; gate_common):
  tool                                   unattended          attended
  Bash, a BASH_RULES row matches         deny (rewrite)      no decision
  Bash, otherwise                        allow               no decision
  AskUserQuestion                        deny (decide it)    no decision
  scheduled-tasks create/delete/run      deny (record it)    no decision
  any other tool                         allow               no decision
The two deny texts for AskUserQuestion and scheduled tasks come from
unattended.permission_gate.deny_message_ask and deny_message_schedule.
With unattended.permission_gate.enabled false the gate makes no decision.
An attended session gets no decision at all, before any Bash is inspected:
the person sees the normal prompt and decides.

A recursive delete is checked on its normalised target (~, $HOME, ${HOME}
expanded): refused on /, a folder one or two levels deep, the home folder
and its direct children, the project root and its ancestors, the worktree
root itself (core.worktree_root; empty means ../<repo-name>-review), every
path in unattended.permission_gate.protected_paths and its ancestors, a
glob in any of those, "." or a relative climb out, and any variable or
substitution. One named folder inside the worktree root or a session's
scratchpad may go. Wrappers (env, command, nice, nohup, time, exec) and
their options are skipped to find the real command. A force push of the
main branch, HEAD or @, or with no refspec, is refused.

Every decision, pass-through included, is one JSON line in
permission-gate.log in $CLAUDE_PLUGIN_DATA (else ~/.config/subagent-studio).
Any error denies with a short message and is logged; the hook never exits
non-zero and never calls out. Python 3.9, standard library only.
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate_common  # noqa: E402

LOG = "permission-gate.log"

REWRITE = ("Rewrite it: use a literal absolute path to one named folder inside the "
           "worktree root or the scratchpad, or `git worktree remove --force <literal path>`; "
           "never a recursive delete on a variable path.")

SCHEDULED_TASK_WRITE = re.compile(
    r"^mcp__[\w-]*scheduled[-_]tasks__(create|delete|run)_scheduled_task$")


# ---------------------------------------------------------------- tokenizer
SEPARATORS = set(";&|\n()")


def split_commands(cmd):
    """Split a shell command into simple commands (lists of words, quotes
    removed). Handles quotes, backslashes, $( ) and backticks well enough for
    the rules below; never raises. Bodies of $( ) and backticks are returned
    as extra commands so a delete hidden in one is still seen."""
    commands, words, word, inner = [], [], [], []
    has_word = False
    i, n = 0, len(cmd)

    def end_word():
        nonlocal word, has_word
        if has_word:
            words.append("".join(word))
        word, has_word = [], False

    def end_cmd():
        nonlocal words
        end_word()
        if words:
            commands.append(words)
        words = []

    def read_subst(j):
        """cmd[j:] starts after '$(' ; return index after the matching ')'."""
        depth = 1
        k = j
        while k < n and depth:
            c = cmd[k]
            if c == "\\":
                k += 2
                continue
            if c == "'":
                e = cmd.find("'", k + 1)
                k = n if e < 0 else e + 1
                continue
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            k += 1
        return k

    while i < n:
        c = cmd[i]
        if c == "\\" and i + 1 < n:
            if cmd[i + 1] != "\n":
                word.append(cmd[i + 1])
                has_word = True
            i += 2
        elif c == "'":
            e = cmd.find("'", i + 1)
            e = n if e < 0 else e
            word.append(cmd[i + 1:e])
            has_word = True
            i = e + 1
        elif c == '"':
            j = i + 1
            while j < n and cmd[j] != '"':
                if cmd[j] == "\\" and j + 1 < n:
                    word.append(cmd[j:j + 2])
                    j += 2
                    continue
                if cmd.startswith("$(", j):
                    k = read_subst(j + 2)
                    inner.append(cmd[j + 2:k - 1])
                    word.append(cmd[j:k])
                    j = k
                    continue
                word.append(cmd[j])
                j += 1
            has_word = True
            i = j + 1
        elif cmd.startswith("$(", i):
            k = read_subst(i + 2)
            inner.append(cmd[i + 2:k - 1])
            word.append(cmd[i:k])
            has_word = True
            i = k
        elif c == "`":
            e = cmd.find("`", i + 1)
            e = n if e < 0 else e
            inner.append(cmd[i + 1:e])
            word.append(cmd[i:e + 1])
            has_word = True
            i = e + 1
        elif c in SEPARATORS:
            end_cmd()
            i += 1
        elif c in " \t":
            end_word()
            i += 1
        elif c == "#" and not has_word:
            e = cmd.find("\n", i)
            i = n if e < 0 else e
        else:
            word.append(c)
            has_word = True
            i += 1
    end_cmd()
    for body in inner:
        commands.extend(split_commands(body))
    return commands


# words that may stand before the real command word
PREFIX_WORDS = {"do", "then", "else", "elif", "if", "while", "until", "!", "{", "}",
                "builtin"}
# wrappers that run the next word as the command, after their own options
WRAPPERS = {"time", "command", "exec", "nice", "nohup", "env"}
# a wrapper's options that take the next word as their value
WRAPPER_VALUE_OPTS = {"env": {"-u", "--unset", "-C", "--chdir", "-P"},
                      "nice": {"-n", "--adjustment"}, "exec": {"-a"},
                      "time": {"-o", "--output", "-f", "--format"}}
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


def command_word(words):
    """(name, args) of a simple command, skipping keywords, VAR=x, and the
    wrappers env, command, nice, nohup, time and exec with their options
    (env -S 'string' splits the string into words, as env does)."""
    words = list(words)
    i = 0
    while i < len(words):
        w = words[i]
        if w in PREFIX_WORDS or ASSIGNMENT.match(w):
            i += 1
            continue
        base = os.path.basename(w)
        if base in WRAPPERS:
            i += 1
            while i < len(words) and words[i].startswith("-") and len(words[i]) > 1:
                opt = words[i]
                if opt == "--":
                    i += 1
                    break
                if base == "env" and (opt in ("-S", "--split-string") or opt.startswith("--split-string=")
                                      or (opt.startswith("-S") and len(opt) > 2)):
                    if opt in ("-S", "--split-string"):
                        value = words[i + 1] if i + 1 < len(words) else ""
                        rest = words[i + 2:]
                    else:
                        value = opt.split("=", 1)[1] if opt.startswith("--") else opt[2:]
                        rest = words[i + 1:]
                    words = words[:i] + value.split() + rest
                    break
                if opt in WRAPPER_VALUE_OPTS.get(base, ()):
                    i += 2
                else:
                    i += 1
            continue
        break
    if i >= len(words):
        return "", []
    return os.path.basename(words[i]), words[i + 1:]


# ---------------------------------------------------------------- rm targets
HOME = os.path.normpath(os.path.expanduser("~"))
# the root of every session's scratchpad: a delete needs <project>/<session>/ below it
TMP_ROOT = re.compile(r"^(/private)?/tmp/claude-\d+(?=/|$)")
GLOB_ONLY = re.compile(r"^[*?\[\]./]*$")
GLOB_CHARS = re.compile(r"[*?\[]")
HAS_VARIABLE = re.compile(r"\$|`")
HOME_FORMS = re.compile(r"^(\$HOME|\$\{HOME\})(?=/|$)")

# set per request by decide(): folders protected with their ancestors, and
# the worktree root (protected itself; one named folder inside may go)
_repo_roots = []
_worktree_root = None


def _abs(path, base):
    """An absolute normalised path: ~ expanded, a relative one joined to base."""
    if not isinstance(path, str) or not path.strip():
        return None
    p = os.path.expanduser(path.strip())
    if not os.path.isabs(p):
        if not base:
            return None
        p = os.path.join(base, p)
    return os.path.normpath(p)


def worktree_root_for(cfg, project):
    """core.worktree_root, or ../<repo-name>-review beside the project."""
    core = cfg.get("core") if isinstance(cfg, dict) else None
    wt = core.get("worktree_root") if isinstance(core, dict) else ""
    if isinstance(wt, str) and wt.strip():
        return _abs(wt, project)
    if project:
        return os.path.join(os.path.dirname(project), os.path.basename(project) + "-review")
    return None


def repo_roots_for(cwd, cfg=None, worktree_root=None):
    """$CLAUDE_PROJECT_DIR, the hook's cwd when it is a repo root (holds .git)
    outside the worktree root and the scratch folders, and
    unattended.permission_gate.protected_paths."""
    roots = []
    env = os.environ.get("CLAUDE_PROJECT_DIR")
    if env:
        roots.append(env)
    if cwd and os.path.isabs(cwd):
        c = os.path.normpath(cwd)
        if (os.path.exists(os.path.join(c, ".git"))
                and not (worktree_root and (c + "/").startswith(worktree_root + "/"))
                and not TMP_ROOT.match(c)):
            roots.append(c)
    base = gate_common.project_root(cwd)
    gate = gate_common.unattended_cfg(cfg or {}).get("permission_gate") or {}
    for p in gate.get("protected_paths") or []:
        a = _abs(p, base)
        if a:
            roots.append(a)
    return [os.path.normpath(r) for r in roots if os.path.isabs(r)]


def normalise_target(target):
    """The target with quotes stripped, ~, $HOME and ${HOME} expanded and an
    absolute path normalised."""
    t = target.strip().strip("'\"")
    t = HOME_FORMS.sub(lambda m: HOME, t)
    if t.startswith("~"):
        t = os.path.expanduser(t)
    if t.startswith("/"):
        t = os.path.normpath(t)
        if t.startswith("//"):
            t = "/" + t.lstrip("/")
    return t


def protected_folder(path):
    """Why an absolute normalised folder must never be deleted whole, or None."""
    if path == "/":
        return "the root"
    parts = [c for c in path.split("/") if c]
    if len(parts) <= 2:
        return "a top-level system or user folder"
    if path == HOME:
        return "the home folder"
    if os.path.dirname(path) == HOME:
        return "a folder directly in the home folder"
    for root in _repo_roots:
        if path == root:
            return "a protected folder (the project root or a configured path)"
        if root.startswith(path + "/"):
            return "a folder that holds a protected folder"
    if _worktree_root:
        if path == _worktree_root:
            return "the worktree root, not one named worktree"
        if _worktree_root.startswith(path + "/"):
            return "a folder that holds the worktree root"
    return None


def rm_target_problem(target):
    """Why a recursive delete of this target is refused, or None."""
    t = normalise_target(target)
    if HAS_VARIABLE.search(t):
        return "the target holds an unexpanded variable or command substitution"
    if not t.startswith("/"):
        rel = os.path.normpath(t) if t else "."
        if rel == "." or rel == ".." or rel.startswith("../"):
            return "the target is the current folder or climbs out of it"
        if GLOB_ONLY.match(t):
            return "the target is a bare glob"
        return None
    why = protected_folder(t)
    if why:
        return "the target is " + why
    parts = [c for c in t.split("/") if c]
    for i, comp in enumerate(parts):
        if GLOB_CHARS.search(comp):
            parent = "/" + "/".join(parts[:i])
            if protected_folder(parent):
                return "a glob in a protected folder"
    if _worktree_root and t.startswith(_worktree_root + "/"):
        child = t[len(_worktree_root) + 1:].split("/")[0]
        if GLOB_CHARS.search(child):
            return "the whole worktree root, not one named worktree"
        return None
    m = TMP_ROOT.match(t)
    if m:
        rest = [c for c in t[m.end():].split("/") if c]
        if len(rest) < 2 or any(GLOB_CHARS.search(c) for c in rest[:2]):
            return "the root of every session's scratchpad, not one session's folder"
        return None
    return None


def rm_problem(args):
    recursive, targets, opts = False, [], True
    for a in args:
        if opts and a == "--":
            opts = False
        elif opts and a.startswith("--"):
            if a == "--recursive":
                recursive = True
        elif opts and a.startswith("-") and len(a) > 1:
            if "r" in a or "R" in a:
                recursive = True
        else:
            targets.append(a)
    if not recursive:
        return None
    for t in targets:
        why = rm_target_problem(t)
        if why:
            return "a recursive rm on {!r}: {}".format(t, why)
    return None


# ---------------------------------------------------------------- other rules
MAIN_BRANCH = "main"


def git_push_problem(args):
    i = 0
    while i < len(args) and args[i].startswith("-"):   # git -C dir / -c k=v
        i += 2 if args[i] in ("-C", "-c") else 1
    if i >= len(args) or args[i] != "push":
        return None
    rest = args[i + 1:]
    force = any(a in ("--force", "-f") or a.startswith("--force-with-lease")
                or (re.match(r"^-[a-zA-Z]+$", a) and "f" in a) for a in rest)
    delete = any(a in ("--delete", "-d") or (re.match(r"^-[a-zA-Z]+$", a) and "d" in a)
                 for a in rest)
    positional, j = [], 0
    while j < len(rest):
        a = rest[j]
        if a in ("-o", "--push-option", "--repo", "--receive-pack", "--exec"):
            j += 2          # the option's value is not a refspec
            continue
        if not a.startswith("-"):
            positional.append(a)
        j += 1
    refs = positional[1:]   # after the remote
    # HEAD and @ may be main: a force push or delete of them counts as main
    names_main = any(a in ("--all", "--mirror", "--branches") for a in rest)
    for r in refs:
        dst = r.lstrip("+").split(":")[-1]
        if dst in (MAIN_BRANCH, "refs/heads/" + MAIN_BRANCH, "HEAD", "@"):
            names_main = True
            force = force or r.startswith("+")
            if r.lstrip("+").startswith(":"):
                return "a push that deletes main"
    if delete and names_main:
        return "a push that deletes main"
    if force and names_main:
        return "a force push to main"
    if force and not refs:
        return "a force push with no branch named, which may push main"
    return None


def diskutil_problem(args):
    return "diskutil erase" if any("erase" in a.lower() for a in args) else None


def dd_problem(args):
    return "dd onto a device" if any(a.startswith("of=/dev/") for a in args) else None


# command word -> check(args) returning a reason or None
BASH_RULES = [
    (lambda name: name == "rm", rm_problem),
    (lambda name: name == "sudo", lambda args: "sudo"),
    (lambda name: name == "git", git_push_problem),
    (lambda name: name.startswith("mkfs") or name == "newfs", lambda args: "mkfs"),
    (lambda name: name == "diskutil", diskutil_problem),
    (lambda name: name == "dd", dd_problem),
]


SHELLS = {"sh", "bash", "zsh", "dash", "ksh"}
FIND_EXPR_START = re.compile(r"^(-|\(|\)|!|,)")


def shell_c_string(args):
    """The command string of `sh -c 'string' ...`, or None."""
    has_c, j = False, 0
    while j < len(args):
        a = args[j]
        if a in ("-o", "+o", "-O", "+O"):
            j += 2
            continue
        if a == "--":
            j += 1
            break
        if len(a) > 1 and a[0] in "-+" and not a.startswith("--"):
            has_c = has_c or "c" in a[1:]
            j += 1
            continue
        if a.startswith("--"):
            j += 1
            continue
        break
    if has_c and j < len(args):
        return args[j]
    return None


def find_problem(args):
    """find ... -delete, or -exec/-execdir rm -r ...: a recursive delete of
    find's start paths (default "."), under the same target rules as rm."""
    starts = []
    j = 0
    while j < len(args) and args[j] in ("-H", "-L", "-P", "-E", "-X", "-d", "-s", "-x"):
        j += 1
    while j < len(args) and not FIND_EXPR_START.match(args[j]):
        starts.append(args[j])
        j += 1
    expr = args[j:]
    deletes = "-delete" in expr
    k = 0
    while k < len(expr) and not deletes:
        if expr[k] in ("-exec", "-execdir", "-ok", "-okdir"):
            end = k + 1
            while end < len(expr) and expr[end] not in (";", "+"):
                end += 1
            sub = expr[k + 1:end]
            name, sargs = command_word(sub)
            if name == "rm" and any(a == "--recursive" or (a.startswith("-") and not a.startswith("--")
                                                         and ("r" in a or "R" in a)) for a in sargs):
                deletes = True
            k = end
        k += 1
    if not deletes:
        return None
    for t in starts or ["."]:
        why = rm_target_problem(t)
        if why:
            return "a find that deletes below {!r}: {}".format(t, why)
    return None


MAX_DEPTH = 6


def bash_problem(command, depth=0):
    if depth > MAX_DEPTH:
        return "shell commands nested too deep to check"
    for words in split_commands(command or ""):
        name, args = command_word(words)
        if name == "xargs" and "rm" in args:   # xargs rm -r: targets come from input
            if rm_problem(args[args.index("rm") + 1:] + ["$input"]):
                return "a recursive rm on targets read from input"
        if name in SHELLS:
            inner = shell_c_string(args)
            if inner is not None:
                why = bash_problem(inner, depth + 1)
                if why:
                    return why
        if name == "eval" and args:
            why = bash_problem(" ".join(args), depth + 1)
            if why:
                return why
        if name == "find":
            why = find_problem(args)
            if why:
                return why
        for match, check in BASH_RULES:
            if match(name):
                why = check(args)
                if why:
                    return why
    return None


# ---------------------------------------------------------------- decision
def decide(data, cfg=None):
    """(behavior or None, rule, message) for one PermissionRequest input."""
    tool = data.get("tool_name") or ""
    global _repo_roots, _worktree_root, MAIN_BRANCH
    if cfg is None:
        cfg = gate_common.load_config(data.get("cwd"))
    ucfg = gate_common.unattended_cfg(cfg)
    gate = ucfg.get("permission_gate") or {}
    defaults = gate_common.studio_config.DEFAULTS["unattended"]["permission_gate"]
    if gate.get("enabled") is False:
        return None, "gate-disabled", None
    ask_deny = gate.get("deny_message_ask") or defaults["deny_message_ask"]
    tasks_deny = gate.get("deny_message_schedule") or defaults["deny_message_schedule"]
    core = cfg.get("core") if isinstance(cfg, dict) else None
    main = core.get("main_branch") if isinstance(core, dict) else None
    MAIN_BRANCH = main if isinstance(main, str) and main else "main"
    _worktree_root = worktree_root_for(cfg, gate_common.project_root(data.get("cwd")))
    _repo_roots = repo_roots_for(data.get("cwd"), cfg, _worktree_root)
    unattended = data.get("_unattended")
    if unattended is None:
        unattended = gate_common.is_unattended(data.get("transcript_path"),
                                               gate_common.scheduled_mark(cfg),
                                               data.get("permission_mode"))
    if not unattended:
        # a person can answer the prompt: show it and let them decide
        return None, "attended", None
    if tool == "Bash":
        cmd = (data.get("tool_input") or {}).get("command") or ""
        why = bash_problem(cmd)
        if why:
            return "deny", "bash-deny: " + why, (
                "The permission gate refused this command ({}). {}".format(why, REWRITE))
        return "allow", "bash-allow", None
    if tool == "AskUserQuestion":
        return "deny", "ask-unattended", ask_deny
    if SCHEDULED_TASK_WRITE.match(tool):
        return "deny", "scheduled-task-write", tasks_deny
    return "allow", "unattended-allow", None


def output(behavior, message=None):
    decision = {"behavior": behavior}
    if behavior == "deny" and message:
        decision["message"] = message
    return json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                                              "decision": decision}})


def main():
    data = {}
    try:
        data = json.loads(sys.stdin.read() or "")
        if not isinstance(data, dict):
            raise ValueError("input is not an object")
        cfg = gate_common.load_config(data.get("cwd"))
        data["_unattended"] = gate_common.is_unattended(data.get("transcript_path"),
                                                        gate_common.scheduled_mark(cfg),
                                                        data.get("permission_mode"))
        behavior, rule, message = decide(data, cfg)
        rec = {"session_id": data.get("session_id"), "unattended": data["_unattended"],
               "tool": data.get("tool_name"), "decision": behavior or "none", "rule": rule}
        if data.get("tool_name") == "Bash":
            rec["command"] = ((data.get("tool_input") or {}).get("command") or "")[:300]
        gate_common.log_line(LOG, rec)
        if behavior:
            print(output(behavior, message))
    except Exception as e:
        name = type(e).__name__
        gate_common.log_line(LOG, {"session_id": data.get("session_id") if isinstance(data, dict) else None,
                                   "tool": data.get("tool_name") if isinstance(data, dict) else None,
                                   "decision": "deny", "rule": "error: {}: {}".format(name, str(e)[:200])})
        print(output("deny", "The permission gate hit an error ({}); retry with a simpler command.".format(name)))
    return 0


if __name__ == "__main__":
    try:
        main()
    finally:
        sys.exit(0)
