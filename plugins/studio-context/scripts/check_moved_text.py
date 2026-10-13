#!/usr/bin/env python3
"""Prove that text moved out of one file still exists in a set of files.

Every non-blank line of the OLD text must appear, after whitespace is
collapsed, somewhere in the NEW files (their text is joined with spaces, so
re-wrapped paragraphs still match; a trailing period, colon or comma is not
required). Headings are checked with their #'s stripped; lines that are only
markdown decoration (rules, table separators, fences) are skipped. What is missing is
printed, one line each, and the exit status is 1.

A git spec is read with `git show <ref>:<path>` in the current directory, so
run it from the project root.

Usage:
  check_moved_text.py --old <file | git:<ref>:<path>> --new <file>... [--ignore <regex>]...

Examples:
  check_moved_text.py --old git:HEAD:CLAUDE.md --new CLAUDE.md docs/claude/*.md
  check_moved_text.py --old git:HEAD:STATE.md --new STATE.md state/*.md
  check_moved_text.py --old git:HEAD:.claude/skills/my-skill/SKILL.md \
      --new .claude/skills/my-skill/SKILL.md .claude/skills/my-skill/reference/*.md
"""
import argparse
import re
import subprocess
import sys

DECORATION = re.compile(r"^\s*(-{3,}\s*$|\|[\s:|-]*\|\s*$|```|---\s*$)")


def read_old(spec: str) -> str:
    if spec.startswith("git:"):
        _, ref, path = spec.split(":", 2)
        return subprocess.run(
            ["git", "show", f"{ref}:{path}"], check=True, capture_output=True, text=True
        ).stdout
    with open(spec, encoding="utf-8") as f:
        return f.read()


def norm(s: str) -> str:
    return re.sub(r"\s+", " ", s).strip()


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--old", required=True, help="the file before the move, or git:<ref>:<path>")
    ap.add_argument("--new", required=True, nargs="+", help="the files after the move")
    ap.add_argument("--ignore", action="append", default=[], help="regex; an old line matching it is not required")
    ap.add_argument("--min-chars", type=int, default=8, help="old lines shorter than this are skipped (default 8)")
    args = ap.parse_args(argv)

    old = read_old(args.old)
    new_text = []
    for path in args.new:
        with open(path, encoding="utf-8") as f:
            new_text.append(f.read())
    haystack = norm(" ".join(new_text))
    ignores = [re.compile(r) for r in args.ignore]

    missing = []
    checked = 0
    for raw in old.splitlines():
        if DECORATION.match(raw):
            continue
        line = norm(raw)
        # Strip a heading's #'s, a list marker or a table pipe, so a moved heading or bullet still matches.
        line = re.sub(r"^(#{1,6}|[-*+]|\d+\.)\s+", "", line)
        line = line.strip("| ").strip().rstrip(".:;,")
        if len(line) < args.min_chars:
            continue
        if any(r.search(line) for r in ignores):
            continue
        checked += 1
        if line not in haystack:
            missing.append(line)

    if missing:
        print(f"MISSING {len(missing)} of {checked} lines from {args.old}:")
        for m in missing:
            print("  - " + (m if len(m) <= 160 else m[:157] + "..."))
        return 1
    print(f"OK: all {checked} lines of {args.old} are present in {len(args.new)} file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
