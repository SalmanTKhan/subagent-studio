#!/usr/bin/env bash
# Copy-in installer for projects that do not use Claude Code plugins.
#
#   install.sh --modules core[,context,unattended,research] [--target DIR]
#              [--dry-run] [--force]
#   install.sh --uninstall [--target DIR] [--dry-run]
#
# For each chosen plugin under kit/plugins/studio-<module>/ it copies
#   agents/*.md        to <target>/.claude/agents/
#   skills/<name>/     to <target>/.claude/skills/<name>/
#   scripts/*          to <target>/scripts/studio/ (studio_config.py once)
# and merges hooks/hooks.json into <target>/.claude/settings.json under
# "hooks", keeping every existing setting and hook and never adding the
# same command twice.
#
# In every copied .md file it rewrites the plugin forms to copy-in forms:
#   studio-core:builder, /studio-core:effort-medium  ->  builder, /effort-medium
#   ${CLAUDE_PLUGIN_ROOT}/scripts/, <plugin root>/scripts/  ->
#     "${REPO:-$(git rev-parse --path-format=absolute --git-common-dir)/..}"/scripts/studio/
#   (the main checkout's copy, from the main checkout or any review worktree)
#   ${CLAUDE_SKILL_DIR}                              ->  .claude/skills/<name>
# and drops each prose sentence that only fits a plugin install (where the
# plugin root is, how its variable is replaced). A copied .md file that
# still names the plugin root stops the install, exit 2.
# Hook commands get "$CLAUDE_PROJECT_DIR"/scripts/studio/ instead, in the
# form f="$CLAUDE_PROJECT_DIR"/scripts/studio/<script>; [ -f "$f" ] || exit 0;
# python3 "$f", so a missing script never blocks a tool call.
#
# Every file it writes is recorded with its sha256 in
# <target>/scripts/studio/.studio-install, with the kit version and the
# hooks it added. On a later install a target file whose hash matches the
# record is ours and unedited, so an upgrade replaces it. A file identical
# to the new content is skipped. Any other existing file (not ours, or
# edited since) is a conflict: all are listed and nothing is written,
# exit 1, unless --force, which saves each as <file>.studio-bak first.
# --uninstall removes only recorded files that still match their hash and
# lists the edited ones it kept; a record line without a hash counts as
# edited.
#
# Needs bash (3.2 is enough), python3 and git. Exit 0 done, 1 conflict,
# 2 usage or environment error.
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
}

MODULES=""
TARGET=""
DRY=0
FORCE=0
UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --modules) [ $# -ge 2 ] || { usage >&2; exit 2; }; MODULES="$2"; shift 2 ;;
    --modules=*) MODULES="${1#--modules=}"; shift ;;
    --target) [ $# -ge 2 ] || { usage >&2; exit 2; }; TARGET="$2"; shift 2 ;;
    --target=*) TARGET="${1#--target=}"; shift ;;
    --dry-run) DRY=1; shift ;;
    --force) FORCE=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "install.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "install.sh: python3 is required" >&2; exit 2; }

if [ -z "$TARGET" ]; then
  TARGET="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "install.sh: not inside a git repository; pass --target DIR" >&2; exit 2; }
fi
[ -d "$TARGET" ] || { echo "install.sh: target is not a directory: $TARGET" >&2; exit 2; }
TARGET="$(cd "$TARGET" && pwd)"

if [ "$UNINSTALL" -eq 0 ] && [ -z "$MODULES" ]; then
  echo "install.sh: --modules is required (core, context, unattended, research)" >&2
  usage >&2
  exit 2
fi

exec python3 - "$KIT" "$TARGET" "$MODULES" "$DRY" "$FORCE" "$UNINSTALL" <<'PY'
import hashlib
import json
import os
import re
import sys

KIT, TARGET, MODULES, DRY, FORCE, UNINSTALL = sys.argv[1:7]
DRY, FORCE, UNINSTALL = DRY == "1", FORCE == "1", UNINSTALL == "1"

KNOWN = ["core", "context", "unattended", "research"]
NEEDS_CORE = {"unattended", "research"}
MANIFEST_REL = "scripts/studio/.studio-install"
SETTINGS_REL = ".claude/settings.json"
CONFIG_REL = ".claude/studio.json"
CONFIG_BODY = b"{}\n"
NS = re.compile(r"studio-(core|context|unattended|research):")


def die(msg, code=2):
    sys.stderr.write("install.sh: %s\n" % msg)
    sys.exit(code)


def tpath(rel):
    return os.path.join(TARGET, rel)


def read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def kit_version():
    try:
        with open(os.path.join(KIT, ".claude-plugin", "marketplace.json")) as f:
            m = json.load(f)
        return str(m.get("metadata", {}).get("version") or m.get("version") or "unknown")
    except (OSError, ValueError):
        return "unknown"


# ---- rewrites --------------------------------------------------------------

# Prose that only makes sense in a plugin install: where the plugin root is,
# how the variable gets replaced, a lone namespace prefix. Any sentence that
# still matches after the path rewrites is dropped whole.
PLUGIN_PROSE = re.compile(
    r"plugin root|plugin's directory|CLAUDE_PLUGIN_ROOT|CLAUDE_SKILL_DIR|two levels above"
    r"|`studio-(core|context|unattended|research):`", re.I)
# What no copied .md file may hold once rewritten.
LEFTOVER = re.compile(r"plugin root|CLAUDE_PLUGIN_ROOT|CLAUDE_SKILL_DIR"
                      r"|studio-(core|context|unattended|research):", re.I)
SENTENCE_END = re.compile(
    r"(?<!e\.g\.)(?<!i\.e\.)(?<=[.!?])\s+|(?<=[.!?]\*\*)\s+|(?<=[.!?]`)\s+"
    r"|(?<=[.!?]\))\s+|(?<=[.!?]\")\s+")
ITEM_START = re.compile(r"^(\s*(?:[-*+]|\d+[.)])\s+)|^#+\s")
HEADING = re.compile(r"^#+\s")
TOKEN = re.compile(r"(?:[^\s`]*`[^`]*`)+[^\s`]*|\S+")


def fill(prefix, text, indent, width=76):
    """Wrap text at spaces, never inside an inline code span."""
    lines, cur = [], prefix
    for tok in TOKEN.findall(text):
        if cur.strip() and len(cur) + 1 + len(tok) > width:
            lines.append(cur)
            cur = indent + tok
        else:
            cur = cur + tok if cur == prefix or not cur.strip() else cur + " " + tok
    lines.append(cur)
    return lines
FENCE = re.compile(r"^\s*(```|~~~)")


def drop_plugin_prose(text):
    """Remove each prose sentence (outside code fences) that PLUGIN_PROSE
    matches; a list item or paragraph left empty, or left as a bare bold
    label, goes with its blank line."""
    lines = text.split("\n")
    out, block = [], []
    state = {"fence": False, "swallow": False}

    def flush_item(item):
        joined = " ".join(l.strip() for l in item)
        if not PLUGIN_PROSE.search(joined):
            return item
        if HEADING.match(item[0]):
            die("a heading names the plugin root; the kit needs a fix")
        m = ITEM_START.match(item[0])
        prefix = (m.group(1) or "") if m else ""
        body = " ".join([item[0][len(prefix):].strip()] + [l.strip() for l in item[1:]])
        kept = [s for s in SENTENCE_END.split(body) if s and not PLUGIN_PROSE.search(s)]
        rest = " ".join(kept).strip()
        if not rest or re.fullmatch(r"\*\*[^*]+\*\*", rest):
            return []
        indent = " " * len(prefix) if prefix else ""
        return fill(prefix, rest, indent)

    def flush_block():
        if not block:
            return
        items, cur = [], []
        for l in block:
            if cur and (ITEM_START.match(l) or HEADING.match(cur[0])):
                items.append(cur)
                cur = []
            cur.append(l)
        items.append(cur)
        new = [l for it in items for l in flush_item(it)]
        out.extend(new)
        # A paragraph removed whole takes one of its blank lines with it.
        state["swallow"] = not new and bool(out) and out[-1].strip() == ""
        del block[:]

    for line in lines:
        if state["fence"]:
            out.append(line)
            if FENCE.match(line):
                state["fence"] = False
        elif FENCE.match(line):
            flush_block()
            state["swallow"] = False
            out.append(line)
            state["fence"] = True
        elif line.strip() == "":
            flush_block()
            if state["swallow"]:
                state["swallow"] = False
                continue
            out.append(line)
        else:
            block.append(line)
    flush_block()
    return "\n".join(out)


# Where an installed skill finds the scripts: the main checkout, never the
# directory a command runs in, which may be a review worktree whose branch
# carries its own (unreviewed, or not yet landed) copy. $REPO is the main
# checkout's path in the self-review recipes; elsewhere git's common
# directory names it from the main checkout or any of its worktrees.
SCRIPTS_HOME = "${REPO:-$(git rev-parse --path-format=absolute --git-common-dir)/..}"
PLUGIN_SCRIPT_FORMS = ("${CLAUDE_PLUGIN_ROOT}/scripts/", "$CLAUDE_PLUGIN_ROOT/scripts/",
                       "<plugin root>/scripts/")
# A script under scripts/studio/ an installed .md file may name only after
# SCRIPTS_HOME, quoted or not: any other path to one would run relative to
# the working directory. The bare directory may be named in prose.
BARE_SCRIPTS = re.compile(r'(?<!\.\.\}/)(?<!\.\.\}"/)scripts/studio/[\w.-]')


def rewrite_md(text, skill=None, name="?"):
    """Plugin forms to copy-in forms, for one .md file (skill: its name)."""
    # "the agent name without `studio-core:`": copy-in names carry no prefix.
    text = re.sub(r" without `studio-(core|context|unattended|research):`", "", text)
    for form in PLUGIN_SCRIPT_FORMS:
        text = text.replace('"' + form, '"' + SCRIPTS_HOME + "/scripts/studio/")
        text = text.replace(form, '"' + SCRIPTS_HOME + '"/scripts/studio/')
    skill_dir = ".claude/skills/%s" % skill if skill else ".claude/skills"
    for form in ("${CLAUDE_SKILL_DIR}", "$CLAUDE_SKILL_DIR"):
        text = text.replace(form, skill_dir)
    text = drop_plugin_prose(text)
    text = NS.sub("", text)
    bare = BARE_SCRIPTS.search(text)
    if bare:
        die("%s names scripts/studio/ relative to the working directory after the "
            "copy-in rewrite (%r); the kit needs a fix"
            % (name, text[max(0, bare.start() - 30):bare.end() + 20]))
    left = LEFTOVER.search(text)
    if left:
        die("%s still holds %r after the copy-in rewrite; the kit needs a fix"
            % (name, left.group(0)))
    return text


HOOK_SCRIPT = re.compile(r'"\$\{?CLAUDE_PLUGIN_ROOT\}?/scripts/([\w.-]+)"'
                         r'|\$\{?CLAUDE_PLUGIN_ROOT\}?/scripts/([\w.-]+)')


def rewrite_hook_command(cmd):
    """A hook command for the copy-in layout that exits 0 when its script is
    missing (deleted, or a checkout of a branch without it): Claude Code runs
    the command with sh -c, and a python3 that cannot open its file exits 2,
    which in PreToolUse blocks every tool call."""
    found = HOOK_SCRIPT.findall(cmd)
    if len(found) != 1:
        die("a hook command names %d plugin scripts, not one (%s); the kit needs a fix"
            % (len(found), cmd))
    name = found[0][0] or found[0][1]
    run = HOOK_SCRIPT.sub('"$f"', cmd)
    return 'f="$CLAUDE_PROJECT_DIR"/scripts/studio/%s; [ -f "$f" ] || exit 0; %s' % (name, run)


# ---- manifest --------------------------------------------------------------

def sha256(data):
    return hashlib.sha256(data).hexdigest()


def file_hash(path):
    """sha256 of a regular file, None for anything else or nothing."""
    if os.path.isfile(path) and not os.path.islink(path):
        return sha256(read_bytes(path))
    return None


def new_manifest():
    return {"version": None, "modules": [], "files": {}, "dirs": [], "hooks": [],
            "created_settings": False, "created_config": False}


def load_manifest():
    path = tpath(MANIFEST_REL)
    man = new_manifest()
    if not os.path.exists(path):
        return None
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            kind, _, rest = line.partition(" ")
            if kind == "version":
                man["version"] = rest
            elif kind == "modules":
                man["modules"] = [m for m in rest.split(",") if m]
            elif kind == "file":
                # "file <path>\tsha256:<hex>"; an older record has no hash,
                # which counts as unknown and so as modified.
                rel, _, h = rest.partition("\t")
                man["files"][rel] = h[7:] if h.startswith("sha256:") else None
            elif kind == "dir":
                man["dirs"].append(rest)
            elif kind == "hook":
                parts = rest.split("\t", 2)
                if len(parts) == 3:
                    man["hooks"].append(tuple(parts))
            elif kind == "created-settings":
                man["created_settings"] = rest == "yes"
            elif kind == "created-config":
                man["created_config"] = rest == "yes"
    return man


def manifest_text(man):
    out = ["# subagent-studio copy-in install. install.sh --uninstall removes",
           "# the files listed here that still match their hash, and the hook",
           "# entries listed here.",
           "version %s" % man["version"],
           "modules %s" % ",".join(man["modules"])]
    out += ["file %s\t%s" % (f, "sha256:" + h if h else "unknown")
            for f, h in man["files"].items()]
    out += ["dir %s" % d for d in man["dirs"]]
    out += ["hook %s\t%s\t%s" % h for h in man["hooks"]]
    out.append("created-settings %s" % ("yes" if man["created_settings"] else "no"))
    out.append("created-config %s" % ("yes" if man["created_config"] else "no"))
    return "\n".join(out) + "\n"


def dedupe(seq):
    seen, out = set(), []
    for x in seq:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out


# ---- settings --------------------------------------------------------------

def load_settings():
    path = tpath(SETTINGS_REL)
    if not os.path.exists(path):
        return None
    try:
        with open(path) as f:
            data = json.load(f)
    except ValueError as e:
        die("%s is not valid JSON (%s); fix it first" % (SETTINGS_REL, e))
    if not isinstance(data, dict):
        die("%s is not a JSON object" % SETTINGS_REL)
    return data


def settings_bytes(data):
    return (json.dumps(data, indent=2) + "\n").encode()


def existing_commands(settings, event):
    cmds = set()
    for group in (settings.get("hooks") or {}).get(event) or []:
        for h in (group or {}).get("hooks") or []:
            if isinstance(h, dict) and "command" in h:
                cmds.add(h["command"])
    return cmds


def remove_hooks(settings, entries):
    """Remove each (event, matcher, command) hook in entries from settings,
    with any group and event left empty."""
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return
    for event, matcher, cmd in entries:
        groups = hooks.get(event)
        if not isinstance(groups, list):
            continue
        for group in groups:
            if not isinstance(group, dict) or group.get("matcher", "") != matcher:
                continue
            hs = group.get("hooks")
            if isinstance(hs, list):
                group["hooks"] = [h for h in hs if not (isinstance(h, dict) and h.get("command") == cmd)]
        hooks[event] = [g for g in groups if not (isinstance(g, dict) and g.get("hooks") == [])]
        if not hooks[event]:
            del hooks[event]
    if not hooks:
        del settings["hooks"]


SCRIPT_IN_HOOK = re.compile(r"scripts/studio/([\w.-]+)")


# ---- uninstall -------------------------------------------------------------

def uninstall():
    man = load_manifest()
    if man is None:
        die("no install record at %s; nothing to uninstall" % MANIFEST_REL, 1)
    removed, kept = 0, []
    for rel, h in man["files"].items():
        p = tpath(rel)
        if not os.path.lexists(p):
            continue
        if h is not None and file_hash(p) == h:
            print(("would remove " if DRY else "remove ") + rel)
            if not DRY:
                os.remove(p)
            removed += 1
        else:
            kept.append(rel)
    if man["created_config"]:
        p = tpath(CONFIG_REL)
        if os.path.isfile(p) and read_bytes(p) == CONFIG_BODY:
            print(("would remove " if DRY else "remove ") + CONFIG_REL)
            if not DRY:
                os.remove(p)
        elif os.path.exists(p):
            print("keep %s: it was edited after install" % CONFIG_REL)

    settings = load_settings()
    if settings is not None and man["hooks"]:
        remove_hooks(settings, man["hooks"])
        print(("would remove " if DRY else "remove ") + "%d hook entries from %s" % (len(man["hooks"]), SETTINGS_REL))
        if not DRY:
            if not settings and man["created_settings"]:
                os.remove(tpath(SETTINGS_REL))
            else:
                with open(tpath(SETTINGS_REL), "wb") as f:
                    f.write(settings_bytes(settings))

    if not DRY:
        mp = tpath(MANIFEST_REL)
        if os.path.exists(mp):
            os.remove(mp)
        for d in sorted(set(man["dirs"]), key=lambda x: -x.count("/")):
            p = tpath(d)
            if os.path.isdir(p) and not os.listdir(p):
                os.rmdir(p)
    print("%s %d files." % ("Would remove" if DRY else "Removed", removed))
    if kept:
        print("Kept %d file(s) changed since install (or from an install record"
              " without hashes); remove them by hand if you do not want them:" % len(kept))
        for rel in kept:
            print("  keep " + rel)
    sys.exit(0)


if UNINSTALL:
    uninstall()

# ---- plan the install ------------------------------------------------------

wanted = [m.strip() for m in MODULES.split(",") if m.strip()]
for m in wanted:
    if m not in KNOWN:
        die("unknown module %r (known: %s)" % (m, ", ".join(KNOWN)))
if "core" not in wanted and any(m in NEEDS_CORE for m in wanted):
    print("Notice: %s needs core; adding core." % ", ".join(m for m in wanted if m in NEEDS_CORE))
    wanted.insert(0, "core")
modules = [m for m in KNOWN if m in wanted]

plan = {}      # dest rel -> (bytes, mode, source rel)
hook_adds = []  # (event, matcher, hook dict)


def add(dest, data, mode, src):
    prev = plan.get(dest)
    if prev is not None and prev[0] != data:
        die("two plugins ship different %s (%s, %s); the kit is inconsistent" % (dest, prev[2], src))
    plan[dest] = (data, mode, src)


def walk_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d != "__pycache__")
        for name in sorted(filenames):
            if name.endswith(".pyc") or name == ".DS_Store":
                continue
            yield os.path.join(dirpath, name)


for m in modules:
    proot = os.path.join(KIT, "plugins", "studio-" + m)
    if not os.path.isdir(proot):
        die("plugin directory missing: plugins/studio-%s" % m)

    adir = os.path.join(proot, "agents")
    if os.path.isdir(adir):
        for name in sorted(os.listdir(adir)):
            src = os.path.join(adir, name)
            if name.endswith(".md") and os.path.isfile(src):
                text = read_bytes(src).decode("utf-8")
                add(".claude/agents/" + name,
                    rewrite_md(text, None, os.path.relpath(src, KIT)).encode("utf-8"),
                    os.stat(src).st_mode & 0o777, os.path.relpath(src, KIT))

    sdir = os.path.join(proot, "skills")
    if os.path.isdir(sdir):
        for skill in sorted(os.listdir(sdir)):
            sroot = os.path.join(sdir, skill)
            if not os.path.isdir(sroot) or skill.startswith("."):
                continue
            for src in walk_files(sroot):
                rel = os.path.relpath(src, sroot)
                data = read_bytes(src)
                if src.endswith(".md"):
                    data = rewrite_md(data.decode("utf-8"), skill,
                                      os.path.relpath(src, KIT)).encode("utf-8")
                add(".claude/skills/%s/%s" % (skill, rel.replace(os.sep, "/")), data,
                    os.stat(src).st_mode & 0o777, os.path.relpath(src, KIT))

    cdir = os.path.join(proot, "scripts")
    if os.path.isdir(cdir):
        for name in sorted(os.listdir(cdir)):
            src = os.path.join(cdir, name)
            if not os.path.isfile(src) or name.endswith(".pyc") or name.startswith("."):
                continue
            add("scripts/studio/" + name, read_bytes(src),
                os.stat(src).st_mode & 0o777, os.path.relpath(src, KIT))

    hfile = os.path.join(proot, "hooks", "hooks.json")
    if os.path.isfile(hfile):
        try:
            with open(hfile) as f:
                hj = json.load(f)
        except ValueError as e:
            die("plugins/studio-%s/hooks/hooks.json is not valid JSON (%s)" % (m, e))
        for event, groups in sorted((hj.get("hooks") or {}).items()):
            for group in groups or []:
                matcher = group.get("matcher", "")
                for h in group.get("hooks") or []:
                    h = dict(h)
                    if "command" in h:
                        h["command"] = rewrite_hook_command(h["command"])
                    hook_adds.append((event, matcher, h))

# ---- conflicts -------------------------------------------------------------

# A target file is ours when its hash equals the one our record holds: an
# upgrade overwrites it freely. A file identical to the new content is
# skipped, and recorded only when our record already listed it. Anything
# else that exists (not ours, or edited since) is a conflict.
old = load_manifest()
old_files = old["files"] if old else {}
writes, conflicts, upgrades, keep_identical = [], [], [], []
for dest in sorted(plan):
    data = plan[dest][0]
    p = tpath(dest)
    if os.path.lexists(p):
        cur = file_hash(p)
        if cur == sha256(data):
            if dest in old_files:
                keep_identical.append(dest)
            continue
        if cur is not None and old_files.get(dest) == cur:
            upgrades.append(dest)
        else:
            if os.path.isdir(p) and not os.path.islink(p):
                die("%s is a directory; move it aside first" % dest)
            conflicts.append(dest)
    writes.append(dest)

if conflicts and not FORCE:
    sys.stderr.write("install.sh: %d conflicting file(s) in %s; nothing written:\n" % (len(conflicts), TARGET))
    for c in conflicts:
        sys.stderr.write("  %s\n" % c)
    sys.stderr.write("Move them aside, or re-run with --force to overwrite them"
                     " (each is saved as <file>.studio-bak first).\n")
    sys.exit(1)

# ---- settings merge (computed before any write) ----------------------------

settings = load_settings()
created_settings = settings is None
if settings is None:
    settings = {}
new_hooks = []
# An upgrade replaces our own hook for the same script when its command
# changed (an older install's form), instead of running both.
stale = []
if old and hook_adds:
    scripts_now = {}
    for event, matcher, h in hook_adds:
        m = SCRIPT_IN_HOOK.search(h.get("command") or "")
        if m:
            scripts_now[(event, matcher, m.group(1))] = h.get("command")
    for entry in old["hooks"]:
        event, matcher, cmd = entry
        m = SCRIPT_IN_HOOK.search(cmd or "")
        want = scripts_now.get((event, matcher, m.group(1))) if m else None
        if want is not None and want != cmd:
            stale.append(tuple(entry))
    if stale:
        remove_hooks(settings, stale)
if hook_adds:
    hooks = settings.get("hooks")
    if hooks is None:
        hooks = {}
    if not isinstance(hooks, dict):
        die('"hooks" in %s is not an object' % SETTINGS_REL)
    for event, matcher, h in hook_adds:
        cmd = h.get("command")
        if cmd is not None and cmd in existing_commands({"hooks": hooks}, event):
            continue
        groups = hooks.setdefault(event, [])
        groups.append({"matcher": matcher, "hooks": [h]})
        new_hooks.append((event, matcher, cmd))
    if new_hooks:
        settings["hooks"] = hooks

# ---- report and write ------------------------------------------------------

created_dirs = []
for dest in writes:
    d = os.path.dirname(dest)
    chain = []
    while d and not os.path.isdir(tpath(d)):
        chain.append(d)
        d = os.path.dirname(d)
    created_dirs += chain
if not os.path.isdir(tpath("scripts/studio")):
    created_dirs += ["scripts/studio"] + ([] if os.path.isdir(tpath("scripts")) else ["scripts"])
created_dirs = dedupe(created_dirs)

verb = "would " if DRY else ""
print("Modules: %s -> %s" % (",".join(modules), TARGET))


def backup_name(dest):
    b = dest + ".studio-bak"
    n = 1
    while os.path.lexists(tpath(b)):
        b = "%s.studio-bak.%d" % (dest, n)
        n += 1
    return b


backups = {}
for dest in writes:
    if dest in conflicts:
        backups[dest] = backup_name(dest)
        print("  %soverwrite %s (old copy saved as %s)" % (verb, dest, backups[dest]))
    elif dest in upgrades:
        print("  %supdate %s" % (verb, dest))
    else:
        print("  %swrite %s" % (verb, dest))
skipped = len(plan) - len(writes)
if skipped:
    print("  %d identical file(s) skipped" % skipped)
for event, matcher, cmd in stale:
    print("  %sremove the older hook %s [%s]: %s" % (verb, event, matcher, cmd))
for event, matcher, cmd in new_hooks:
    print("  %sadd hook %s [%s]: %s" % (verb, event, matcher, cmd))
make_config = not os.path.exists(tpath(CONFIG_REL))
if make_config:
    print("  %swrite %s ({})" % (verb, CONFIG_REL))

if DRY:
    print("Dry run: nothing written.")
    sys.exit(0)

for dest in writes:
    data, mode, _ = plan[dest]
    p = tpath(dest)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    if dest in backups:
        os.rename(p, tpath(backups[dest]))
    elif os.path.islink(p):
        os.remove(p)
    with open(p, "wb") as f:
        f.write(data)
    os.chmod(p, mode)

if new_hooks or stale:
    os.makedirs(os.path.dirname(tpath(SETTINGS_REL)), exist_ok=True)
    with open(tpath(SETTINGS_REL), "wb") as f:
        f.write(settings_bytes(settings))

if make_config:
    os.makedirs(os.path.dirname(tpath(CONFIG_REL)), exist_ok=True)
    with open(tpath(CONFIG_REL), "wb") as f:
        f.write(CONFIG_BODY)

man = old or new_manifest()
man["version"] = kit_version()
man["modules"] = [m for m in KNOWN if m in set(man["modules"]) | set(modules)]
for dest in writes + keep_identical:
    man["files"][dest] = sha256(plan[dest][0])
man["dirs"] = dedupe(man["dirs"] + created_dirs)
man["hooks"] = dedupe([h for h in man["hooks"] if tuple(h) not in stale]
                     + [h for h in new_hooks if h[2] is not None])
if old is None:
    man["created_settings"] = created_settings and bool(new_hooks)
    man["created_config"] = make_config
else:
    man["created_settings"] = man["created_settings"] or (created_settings and bool(new_hooks))
    man["created_config"] = man["created_config"] or make_config
os.makedirs(os.path.dirname(tpath(MANIFEST_REL)), exist_ok=True)
with open(tpath(MANIFEST_REL), "w") as f:
    f.write(manifest_text(man))

print("Installed %d file(s), skipped %d, added %d hook(s). Record: %s" % (
    len(writes), skipped, len(new_hooks), MANIFEST_REL))
print("""
Next steps:
  1. Configure: run the studio-init skill (/studio-init) in Claude Code.
  2. Validate:  python3 scripts/studio/studio_config.py validate
  3. Remove later with: install.sh --uninstall --target <this repo>""")
PY
