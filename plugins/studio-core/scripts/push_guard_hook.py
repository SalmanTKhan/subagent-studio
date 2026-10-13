#!/usr/bin/env python3
"""PreToolUse hook on Bash: run the review guard before a push to main.

Wired in hooks/hooks.json as
    python3 "${CLAUDE_PLUGIN_ROOT}/scripts/push_guard_hook.py"

It reads the hook's JSON from stdin. When core.review.push_hook is false (the
default) it exits 0 with no output. Otherwise it parses tool_input.command
and acts on a `git push` that could update the main branch, checking what
the push sends (review_guard.sh beside this script):
  - a refspec whose destination is the main branch with a named source
    (`main`, `HEAD:main`, `x:refs/heads/main`, `+main`), or `HEAD` or no
    refspec while the checkout the push runs in has main checked out: the
    source is resolved to a commit where the push runs (its `-C` directory,
    else the session's cwd) and checked with `review_guard.sh push --source
    SHA` there, so `git push origin review/x:main` is checked as review/x
    and a landing merge pushed from its worktree passes;
  - `--all`, `--mirror`, `--branches` and `:main`: the local main;
  - anything it cannot name for sure: a wildcard destination, a source that
    does not resolve, a push after a `cd` or `pushd` earlier in the command,
    one whose `-C` value, remote or refspec still holds a `$` or a backtick,
    one given `--git-dir`, `--work-tree`, GIT_DIR or GIT_WORK_TREE, and git
    run by another command (`bash -c`, `sh -c`, `eval`, `sudo`, `env`,
    `command`, `xargs` and the like, or inside a command substitution). It
    then checks both the local main (`review_guard.sh push` in the project
    directory) and HEAD in each directory the push may run in.
A variable set once, to a literal, in an earlier assignment-only part of
the same command (the recipes' `W=...; git -C "$W" push ...`) is read as its
value. Only the string a shell runs (`bash -c`, `sh -lc`, `eval`) and a
command substitution are read as commands, so `grep -rn "git push" .` runs
no guard. When unsure it runs the guard: a false alarm only costs a fetch,
while a missed push lands unreviewed code. When a guard run exits non-zero
the tool call is denied with its output as the reason. Every other command
passes untouched.

The hook fails open on its own errors (unreadable input, an unreadable
config, a guard that cannot be started or times out): it prints a warning to
stderr and exits 0, so a broken hook never blocks unrelated work. The guard
itself still fails closed: its exit 2 is a deny.

The project directory is $CLAUDE_PROJECT_DIR, else the input's cwd.
Standard library only (Python 3.9+).
"""
import json
import os
import re
import shlex
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
GUARD = os.path.join(HERE, "review_guard.sh")
GUARD_TIMEOUT = 110  # seconds for all guard runs; hooks.json gives the hook 120
SEPARATORS = {";", "&&", "||", "|", "&", "\n", "(", ")", "|&", ";;"}
# git push options that take a separate value.
VALUE_OPTS = {"--repo", "-o", "--push-option", "--receive-pack", "--exec"}
# git global options that take a separate value.
GLOBAL_VALUE_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace",
                     "--exec-path", "--config-env"}
# Commands whose words are only printed: a `git push` among them is text.
PRINTERS = {"echo", "printf"}
DYNAMIC = ("$", "`")
# Shells whose `-c` string is a command, and their options that take a value.
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
SHELL_VALUE_OPTS = {"-o", "+o", "-O", "+O", "--rcfile", "--init-file"}
NAME = r"[A-Za-z_][A-Za-z0-9_]*"
VAR_RE = re.compile(r"\$\{(%s)\}|\$(%s)" % (NAME, NAME))
PLAIN = None  # a source the hook cannot name: check the local main and HEAD


def warn(msg):
    sys.stderr.write("push_guard_hook: %s (the push is not checked)\n" % msg)


def segments(command):
    """The command split into simple commands, as lists of words."""
    lexer = shlex.shlex(command.replace("\n", " ; "), posix=True,
                        punctuation_chars=";&|()")
    lexer.whitespace_split = True
    lexer.commenters = ""
    words = list(lexer)
    out, cur = [], []
    for w in words:
        if w in SEPARATORS or set(w) <= set(";&|()"):
            if cur:
                out.append(cur)
            cur = []
        else:
            cur.append(w)
    if cur:
        out.append(cur)
    return out


def first_command(words):
    """Index of the first word that is not a VAR=value assignment."""
    i = 0
    while i < len(words) and "=" in words[i] and not words[i].startswith("-"):
        i += 1
    return i


def git_push_args(words):
    """(git -C dirs, push arguments, unsure) when words run `git push`
    directly, else None. unsure is True when --git-dir, --work-tree, GIT_DIR
    or GIT_WORK_TREE points git somewhere the hook cannot follow."""
    i = first_command(words)
    unsure = any(w.split("=", 1)[0] in ("GIT_DIR", "GIT_WORK_TREE") for w in words[:i])
    if i >= len(words) or os.path.basename(words[i]) != "git":
        return None
    i += 1
    dirs = []
    while i < len(words) and words[i].startswith("-"):
        opt = words[i]
        if opt.split("=", 1)[0] in ("--git-dir", "--work-tree"):
            unsure = True
        if opt in GLOBAL_VALUE_OPTS:
            if opt == "-C" and i + 1 < len(words):
                dirs.append(words[i + 1])
            i += 2
            continue
        i += 1
    if i >= len(words) or words[i] != "push":
        return None
    return dirs, words[i + 1:], unsure


def split_string(s):
    """The words of a string a shell runs as a command, recursively."""
    try:
        segs = segments(s.replace("`", " ; "))
    except ValueError:
        return [s]
    return words_deep([w for seg in segs for w in seg])


def words_deep(words):
    """words, with each string a shell runs as a command split into its own
    words: the string after `-c` of a shell (`bash -c`, `sh -lc`, `zsh -c`),
    every argument of `eval`, and any word holding a command substitution
    (`$(...)` or a backtick), which runs wherever it stands. Any other
    argument stays one word, so `grep -rn "git push" .` holds no word
    `git`."""
    out, i, n = [], 0, len(words)
    while i < n:
        w = words[i]
        i += 1
        name = os.path.basename(w)
        if name == "eval":
            out.append(w)
            for a in words[i:]:
                out.extend(split_string(a))
            return out
        if "$(" in w or "`" in w:
            out.extend(split_string(w))
            continue
        out.append(w)
        if name in SHELLS:
            while i < n and words[i][:1] in ("-", "+") and len(words[i]) > 1:
                opt = words[i]
                out.append(opt)
                i += 1
                if opt in SHELL_VALUE_OPTS:
                    i += 1
                elif not opt.startswith("--") and "c" in opt[1:]:
                    if i < n:
                        out.extend(split_string(words[i]))
                        i += 1
                    break
    return out


def wrapped_push(words):
    """True when a command that is not git itself runs `git push` somewhere
    in its words: sudo, env, command, xargs, bash -c, eval and the rest, or
    a command substitution in any command's words."""
    i = first_command(words)
    if i >= len(words) or os.path.basename(words[i]) in PRINTERS | {"git"}:
        # Printed or given to git: only a command substitution runs.
        flat = [x for w in words if "$(" in w or "`" in w for x in split_string(w)]
    else:
        flat = words_deep(words[i:])
    for j, w in enumerate(flat):
        if os.path.basename(w) == "git" and "push" in flat[j + 1:]:
            return True
    return False


def current_branch(cwd):
    proc = subprocess.run(["git", "-C", cwd, "symbolic-ref", "--short", "-q", "HEAD"],
                          capture_output=True, text=True, timeout=20)
    return proc.stdout.strip() if proc.returncode == 0 else ""


def run_dir_of(base, dirs):
    """The directory git runs in: base, then each `-C` value in turn."""
    run_dir = base
    for d in dirs:
        run_dir = os.path.join(run_dir, os.path.expanduser(d))
    return run_dir


def main_sources(args, run_dir, main):
    """What this push, run in run_dir, could put on the main branch, as a
    list of revisions to resolve in run_dir ([] when it cannot reach main).
    PLAIN stands for "not known": check both the local main and HEAD."""
    positional = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            positional.extend(args[i + 1:])
            break
        if a in ("--all", "--mirror", "--branches"):
            return ["refs/heads/" + main]
        if a in VALUE_OPTS:
            i += 2
            continue
        if not a.startswith("-") or a == "-":
            positional.append(a)
        i += 1
    refspecs = positional[1:]
    if not refspecs:
        return ["HEAD"] if current_branch(run_dir) == main else []
    main_refs = {main, "refs/heads/" + main}
    out = []
    for spec in refspecs:
        spec = spec.lstrip("+")
        src, sep, dst = spec.partition(":")
        target = dst if sep else src
        if "*" in target:
            out.append(PLAIN)
        elif target in main_refs:
            # `:main` deletes it: nothing is brought, so the local main is checked.
            out.append(src if src else "refs/heads/" + main)
        elif target in ("HEAD", "@") and current_branch(run_dir) == main:
            out.append("HEAD")
    return out


def resolve(run_dir, rev):
    """rev as a commit SHA in run_dir, or None."""
    try:
        proc = subprocess.run(["git", "-C", run_dir, "rev-parse", "-q", "--verify",
                               "--end-of-options", rev + "^{commit}"],
                              capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None
    return proc.stdout.strip() if proc.returncode == 0 and proc.stdout.strip() else None


def known_values(segs):
    """{name: (segment index, value)} for each shell variable the command
    sets exactly once, in a segment of assignments only, to a value with no
    `$` or backtick. Any other word naming the variable (a second
    assignment, `export W`, `unset W`, `for W in`, `read W`) makes it
    unknown, so the hook reads "$W" only where the shell must agree."""
    counts = {}
    for words in segs:
        for w in words:
            name = w.split("=", 1)[0]
            counts[name] = counts.get(name, 0) + 1
    known = {}
    for k, words in enumerate(segs):
        if not words or first_command(words) != len(words):
            continue
        for w in words:
            name, _, value = w.partition("=")
            if (re.fullmatch(NAME, name) and counts.get(name) == 1
                    and not any(c in value for c in DYNAMIC)):
                known[name] = (k, value)
    return known


def substitute(word, known, k):
    """word with each "$NAME" or "${NAME}" set earlier (known_values)
    replaced by its value; any other `$` stays, so the word stays unsure."""
    def one(m):
        name = m.group(1) or m.group(2)
        hit = known.get(name)
        return hit[1] if hit and hit[0] < k else m.group(0)
    return VAR_RE.sub(one, word)


def deny(reason):
    json.dump({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}, sys.stdout)
    sys.stdout.write("\n")


def main():
    try:
        data = json.load(sys.stdin)
        project = os.environ.get("CLAUDE_PROJECT_DIR") or data.get("cwd") or os.getcwd()
        import studio_config
        cfg = studio_config.load(project)
        if studio_config.get(cfg, "core.review.push_hook") is not True:
            return 0
        command = (data.get("tool_input") or {}).get("command") or ""
        if "push" not in command or "git" not in command:
            return 0
        main_branch = studio_config.get(cfg, "core.main_branch")
        cwd = data.get("cwd") or project
        segs = segments(command)
        known = known_values(segs)
        wanted = []    # (directory, revision or PLAIN) to check
        cd_dirs = []   # the literal targets of earlier cd and pushd
        moved = False  # an earlier segment changed directory
        for k, raw in enumerate(segs):
            words = [substitute(w, known, k) for w in raw]
            i = first_command(words)
            if i < len(words) and words[i] in ("cd", "pushd", "popd"):
                moved = True
                arg = next((w for w in words[i + 1:] if not w.startswith("-")), "")
                if words[i] != "popd" and arg and not any(c in arg for c in DYNAMIC):
                    base = cd_dirs[-1] if cd_dirs else cwd
                    cd_dirs.append(os.path.join(base, os.path.expanduser(arg)))
                continue
            # After a cd the hook cannot tell which directory a push runs in
            # (a subshell may have undone it): every candidate is checked.
            bases = [cwd] + (cd_dirs if moved else [])
            found = git_push_args(words)
            if found is None:
                if wrapped_push(words):
                    wanted += [(b, PLAIN) for b in bases]
                continue
            dirs, args, unsure = found
            run_dirs = [run_dir_of(b, dirs) for b in bases]
            if unsure or any(c in w for w in dirs + args for c in DYNAMIC):
                wanted += [(d, PLAIN) for d in run_dirs]
                continue
            for d in run_dirs:
                wanted += [(d, rev) for rev in main_sources(args, d, main_branch)]
        if not wanted:
            return 0
        # A known source is checked as what the push brings (--source, in the
        # directory the push runs in); an unknown one, or one that does not
        # resolve, as both the local main (from the project) and HEAD.
        plain = False
        checks = []
        for d, rev in wanted:
            if rev is PLAIN:
                plain = True
                rev = "HEAD"
            sha = resolve(d, rev)
            if sha is None:
                plain = True
            elif (d, sha) not in checks:
                checks.append((d, sha))
        runs = ([(["bash", GUARD, "push"], project)] if plain else []) + [
            (["bash", GUARD, "push", "--source", sha], d) for d, sha in checks]
        deadline = time.monotonic() + GUARD_TIMEOUT  # all runs share it
        for argv, where in runs:
            proc = subprocess.run(argv, cwd=where, capture_output=True, text=True,
                                  timeout=max(1, deadline - time.monotonic()))
            if proc.returncode != 0:
                break
        else:
            return 0
    except Exception as e:  # fail open: a broken hook never blocks work
        warn("%s: %s" % (type(e).__name__, e))
        return 0
    output = (proc.stdout + proc.stderr).strip() or "(no output)"
    deny("The review guard refused this push to %s (exit %d). Land the change "
         "through a review branch instead (skill self-review); review_guard.sh "
         "move BRANCH puts local commits on one.\n%s"
         % (main_branch, proc.returncode, output))
    return 0


if __name__ == "__main__":
    sys.exit(main())
