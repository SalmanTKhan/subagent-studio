#!/usr/bin/env python3
"""Copy shared/studio_config.py into every plugin's scripts/ directory.

    python3 tools/sync_shared.py          write the copies
    python3 tools/sync_shared.py --check  exit 1 if any copy differs

Repo-maintenance only; users never run it.
"""

import argparse
import os
import sys

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHARED_FILES = ["studio_config.py"]


def targets(kit):
    plugins = os.path.join(kit, "plugins")
    for name in sorted(os.listdir(plugins)):
        if os.path.isfile(os.path.join(plugins, name, ".claude-plugin", "plugin.json")):
            yield os.path.join(plugins, name, "scripts")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="report drift, write nothing")
    parser.add_argument("--kit", default=KIT, help="kit root (default: this kit)")
    args = parser.parse_args(argv)
    drift = []
    for fname in SHARED_FILES:
        with open(os.path.join(args.kit, "shared", fname), "rb") as handle:
            source = handle.read()
        for scripts in targets(args.kit):
            dest = os.path.join(scripts, fname)
            current = None
            if os.path.exists(dest):
                with open(dest, "rb") as handle:
                    current = handle.read()
            if current == source:
                continue
            rel = os.path.relpath(dest, args.kit)
            if args.check:
                drift.append(rel)
            else:
                os.makedirs(scripts, exist_ok=True)
                with open(dest, "wb") as handle:
                    handle.write(source)
                os.chmod(dest, 0o755)
                print("wrote %s" % rel)
    if drift:
        print("out of sync with shared/ (run tools/sync_shared.py):", file=sys.stderr)
        for rel in drift:
            print("  %s" % rel, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
