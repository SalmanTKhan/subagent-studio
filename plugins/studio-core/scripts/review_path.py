#!/usr/bin/env python3
"""Say which review path a change takes: docs-only or full.

  python3 review_path.py [--repo DIR] <BASE> <HEAD>

Run inside the change's git tree, or name it with --repo (a review worktree),
so that the script that runs is never the branch's own copy. The first line printed is `docs-only` or
`full`. A full change then gets one line per reason: the path,
`<path>: mode <mode> (<kind>)`, `<path>: <key>: line changed` for an agent,
skill or command file whose frontmatter key changed, or `config: <error>`
when the config cannot be read.

Docs-only means every changed path (`git diff --raw BASE..HEAD`, renames
counted as a delete and an add) is a `.md` file, none is under a code
directory, none is a symlink (mode 120000) or a submodule (160000) on either
side or newly executable (100755), and no `.md` file under `.claude/`, or
under an `agents/`, `skills/` or `commands/` directory (a plugin's layout),
changed a frontmatter key other than `name`, `description` and `context`
(the block between a first line `---`, a leading BOM allowed, and the next
`---`). So `tools`, `model`, `effort`, `permissionMode`, `hooks`,
`allowed-tools` and any key added later make it full, and so does an added
or deleted file there with any other key. Anything else is full: settings
files (`.claude/settings*.json`), hook definitions and scripts, the
project's `.claude/studio.json` and every other file that grants a
permission or changes behaviour is not `.md`, so it never counts as docs.

The code directories are the directories in `core.review.reviewed_paths`
(read with studio_config.py beside this script), leaving out `.claude`,
whose `.md` files the frontmatter rule covers, and the `.md` file entries such as
CLAUDE.md. A config that cannot be read makes every change full. Skill
`self-review` says what each path means.

Exit 0 either way; 2 on a git error. Standard library only (Python 3.9+).
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import studio_config  # noqa: E402

CLAUDE_DIR = "/.claude/"  # matched anywhere in the path, any letter case
# Plugin layout: a .md file under one of these directories, anywhere in the
# path, can carry frontmatter that grants tools or changes a model.
FRONTMATTER_DIRS = ("/agents/", "/skills/", "/commands/")
FREE_KEYS = ("name", "description", "context")
MODES = {"120000": "symlink", "160000": "submodule", "100755": "executable"}
OTHER = "(not a key line)"


class GitError(Exception):
    pass


REPO = None  # --repo DIR: the git tree the range is read in; None is the cwd


def git(*args):
    where = ["-C", REPO] if REPO else []
    proc = subprocess.run(
        ["git", *where, "-c", "core.quotepath=off", *args], capture_output=True
    )
    if proc.returncode != 0:
        msg = proc.stderr.decode("utf-8", "replace").strip()
        raise GitError("git %s: %s" % (" ".join(args), msg))
    return proc.stdout


def commit(ref):
    return git("rev-parse", "--verify", "--quiet", ref + "^{commit}").decode().strip()


def changed_paths(base, head):
    """(path, old mode, new mode) for each changed path."""
    out = git("diff", "--raw", "--no-renames", "-z", base, head, "--")
    parts = out.decode("utf-8", "replace").split("\0")
    found = []
    for meta, path in zip(parts[0::2], parts[1::2]):
        modes = meta.lstrip(":").split(" ")
        found.append((path, modes[0], modes[1]))
    return found


def file_at(ref, path):
    """The file's text at ref, or '' when it does not exist there."""
    listed = git("ls-tree", "-z", "--name-only", ref, "--", path)
    if not listed.strip(b"\0"):
        return ""
    return git("show", "%s:%s" % (ref, path)).decode("utf-8", "replace")


def frontmatter_fields(text):
    """Each frontmatter key mapped to its block (the key line and any
    indented or list lines under it). A top-level line that is not a key
    line goes under OTHER. {} when there is no frontmatter."""
    lines = text.splitlines()
    if lines:
        lines[0] = lines[0].lstrip("\ufeff")
    if not lines or lines[0].strip() != "---":
        return {}
    fields = {}
    key = OTHER
    for line in lines[1:]:
        if line.strip() == "---":
            break
        if line.startswith((" ", "\t", "-")) or not line.strip():
            fields[key] = fields.get(key, "") + "\n" + line.rstrip()
            continue
        m = re.match(r"^([^:#]+?)\s*:(.*)$", line)
        key = m.group(1).strip("\"' ") if m else OTHER
        body = m.group(2).strip() if m else line.rstrip()
        fields[key] = fields.get(key, "") + "\n" + body
    return {k: v.strip() for k, v in fields.items()}


def code_dirs(root):
    """Directory prefixes ("src/") from core.review.reviewed_paths."""
    cfg = studio_config.load(root)
    paths = studio_config.get(cfg, "core.review.reviewed_paths")
    dirs = []
    for p in paths:
        p = p.strip().strip("/")
        if not p or p.lower() == ".claude" or p.lower().endswith(".md"):
            continue
        dirs.append(p.lower() + "/")
    return tuple(dirs)


def has_frontmatter_rule(low):
    padded = "/" + low
    return CLAUDE_DIR in padded or any(d in padded for d in FRONTMATTER_DIRS)


def reasons(base, head, dirs):
    out = []
    for path, old_mode, new_mode in changed_paths(base, head):
        low = path.lower()
        if not low.endswith(".md") or low.startswith(dirs):
            out.append(path)
            continue
        for mode in (new_mode, old_mode):
            if mode in MODES and (mode != "100755" or old_mode != mode):
                out.append("%s: mode %s (%s)" % (path, mode, MODES[mode]))
                break
        if has_frontmatter_rule(low):
            if "\ufffd" in path:
                out.append("%s: name not readable" % path)
                continue
            old = frontmatter_fields(file_at(base, path))
            new = frontmatter_fields(file_at(head, path))
            for k in sorted(set(old) | set(new)):
                if k not in FREE_KEYS and old.get(k) != new.get(k):
                    out.append("%s: %s: line changed" % (path, k))
    return out


def main(argv):
    global REPO
    argv = list(argv)
    if len(argv) == 5 and argv[1] == "--repo" and argv[2]:
        REPO = argv[2]
        del argv[1:3]
    if len(argv) != 3 or argv[1].startswith("-"):
        sys.stderr.write("usage: review_path.py [--repo DIR] <BASE> <HEAD>\n")
        return 2
    try:
        base, head = commit(argv[1]), commit(argv[2])
        root = git("rev-parse", "--show-toplevel").decode().strip()
        try:
            dirs = code_dirs(root)
        except Exception as e:  # any config failure: everything is full
            print("full")
            print("config: %s" % e)
            return 0
        found = reasons(base, head, dirs)
    except GitError as e:
        sys.stderr.write("review_path: %s\n" % e)
        return 2
    print("full" if found else "docs-only")
    for line in found:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
