#!/usr/bin/env python3
"""Keep the files every session loads within their size budget.

Budgets come from the project's config, `context.budgets`: a list of
{"path_glob", "max_bytes"} entries, relative to the project root. A file
matched by several entries takes the budget of the last one, so list the
general globs first and the exceptions after them. An entry that matches
nothing is reported as "not present", not as a failure.

The orientation set is every file named by a budget entry without a
wildcard, except CLAUDE.md (it is injected into every request, not read):
by default STATE.md and TASKS.md. Its total must stay within
`context.orientation_total_bytes`. Pass --orientation to name the set.

Prints each budgeted file with its size in bytes and an estimate of tokens
(bytes / 4), and exits 1 when any file, or the orientation set as a whole,
is over budget. Run it at every close-out. Sizes are in bytes because that
is what `wc -c` prints.
"""
import argparse
import glob
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import studio_config  # noqa: E402

WILDCARDS = set("*?[")


def is_glob(pattern):
    return any(ch in WILDCARDS for ch in pattern)


def size(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return None


def budgeted_files(root, budgets):
    """Return ({relpath: limit} in first-seen order, [patterns matching nothing])."""
    limits = {}
    absent = []
    for entry in budgets:
        pattern, limit = entry["path_glob"], entry["max_bytes"]
        matches = sorted(p for p in glob.glob(os.path.join(root, pattern)) if os.path.isfile(p))
        if not matches:
            absent.append(pattern)
            continue
        for path in matches:
            limits[os.path.relpath(path, root)] = limit
    return limits, absent


def default_orientation(budgets):
    return [e["path_glob"] for e in budgets
            if not is_glob(e["path_glob"]) and os.path.basename(e["path_glob"]) != "CLAUDE.md"]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", help="project root (default: $CLAUDE_PROJECT_DIR, git top level, cwd)")
    ap.add_argument("--quiet", action="store_true", help="print only the files over budget")
    ap.add_argument("--orientation", nargs="+", metavar="FILE",
                    help="the files a run reads to orient itself (default: see above)")
    args = ap.parse_args(argv)
    root = studio_config.find_root(args.root)
    try:
        cfg = studio_config.load(root)
    except studio_config.ConfigError as exc:
        print("studio_config: %s" % exc, file=sys.stderr)
        return 2
    budgets = cfg["context"]["budgets"]
    total_budget = cfg["context"]["orientation_total_bytes"]

    limits, absent = budgeted_files(root, budgets)
    rows, over = [], []
    for rel, limit in limits.items():
        n = size(os.path.join(root, rel)) or 0
        rows.append((rel, n, limit))
        if n > limit:
            over.append((rel, n, limit))

    orientation_files = args.orientation or default_orientation(budgets)
    present = [p for p in orientation_files if size(os.path.join(root, p)) is not None]
    orientation = sum(size(os.path.join(root, p)) for p in present)
    if present:
        rows.append(("ORIENTATION (" + " + ".join(present) + ")", orientation, total_budget))
        if orientation > total_budget:
            over.append(("orientation set", orientation, total_budget))

    if not args.quiet:
        print(f"{'file':<52}{'bytes':>8}{'~tokens':>9}{'budget':>8}  ")
        for label, n, limit in rows:
            flag = "OVER" if n > limit else ""
            print(f"{label[:52]:<52}{n:>8}{n // 4:>9}{limit:>8}  {flag}")
        for pattern in absent:
            print(f"{pattern[:52]:<52}{'not present':>25}")
    if over:
        print(f"OVER BUDGET: {len(over)} item(s): " + ", ".join(f"{l} {n}>{lim}" for l, n, lim in over))
        print("Move detail out (a docs/claude/ file, a skill's reference/, a task file), never delete a rule.")
        return 1
    print(f"OK: every budgeted file is within its size; orientation set {orientation} bytes (~{orientation // 4} tokens)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
