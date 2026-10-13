#!/usr/bin/env bash
# Tests for kit/install.sh, the copy-in installer, on throwaway repositories.
#   bash tests/install_test.sh
# Never touches the real repository. Prints one line per assertion and the
# count at the end. Exit 1 if any assertion fails.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$KIT/install.sh"
unset CLAUDE_PROJECT_DIR STUDIO_REVIEWED_PATHS STUDIO_MAIN_BRANCH STUDIO_REMOTE
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
check() { # name, command...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi
}
check_not() { # name, command...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then bad "$name"; else ok "$name"; fi
}

ORIG_SETTINGS='{
  "model": "sonnet",
  "hooks": {
    "PreToolUse": [
      {"matcher": "Edit", "hooks": [{"type": "command", "command": "echo unrelated"}]}
    ]
  }
}'

new_repo() { # $1 name: a clone of a bare origin with one commit and the original settings
  local d="$TMP/$1"
  git init -q --bare -b main "$d.git"
  git clone -q "$d.git" "$d" 2>/dev/null
  mkdir -p "$d/.claude"
  printf '%s\n' "$ORIG_SETTINGS" > "$d/.claude/settings.json"
  echo base > "$d/README.md"
  git -C "$d" add -A && git -C "$d" commit -q -m base && git -C "$d" push -q origin main 2>/dev/null
  echo "$d"
}

json_eq() { # file, json text: equal as parsed JSON
  python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])) == json.loads(sys.argv[2]) else 1)' "$1" "$2"
}
count_cmd() { # settings file, substring: how many hook commands contain it
  python3 - "$1" "$2" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
n = 0
for groups in (s.get("hooks") or {}).values():
    for g in groups:
        for h in g.get("hooks", []):
            if sys.argv[2] in h.get("command", ""):
                n += 1
print(n)
PY
}
no_plugin_forms() { # dir: no .md file holds a plugin-only form
  ! grep -rliE 'plugin root|CLAUDE_PLUGIN_ROOT|CLAUDE_SKILL_DIR|studio-(core|context|unattended|research):' \
    --include='*.md' "$1"
}
script_refs_exist() { # target: every scripts/studio/<name> named in a copied .md file exists
  local t="$1" n missing=0 found=0
  for n in $(grep -rhoE 'scripts/studio/[A-Za-z0-9_.-]*[A-Za-z0-9_]' --include='*.md' "$t/.claude" | sort -u); do
    found=$((found + 1))
    [ -f "$t/$n" ] || { echo "missing: $n"; missing=1; }
  done
  [ "$found" -gt 0 ] && [ "$missing" -eq 0 ]
}
snapshot() { # dir: a listing of every file with its checksum, .git excluded
  (cd "$1" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while read -r f; do
    printf '%s %s\n' "$(cksum < "$f")" "$f"; done)
}

# ---- 1. install core -------------------------------------------------------
R="$(new_repo core)"
out="$(cd "$R" && bash "$INSTALL" --modules core 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "core: install exits 0" || { bad "core: install exits 0 (got $rc)"; echo "$out" | sed 's/^/     /'; }
check "core: builder agent present" test -f "$R/.claude/agents/builder.md"
check "core: reviewer agent present" test -f "$R/.claude/agents/reviewer.md"
check "core: self-review skill present" test -f "$R/.claude/skills/self-review/SKILL.md"
check "core: skill reference file present" test -f "$R/.claude/skills/plan-then-build/reference/builder-brief.md"
check "core: review_guard.sh present" test -f "$R/scripts/studio/review_guard.sh"
check "core: review_guard.sh executable" test -x "$R/scripts/studio/review_guard.sh"
check "core: studio_config.py beside scripts" test -f "$R/scripts/studio/studio_config.py"
check_not "core: no unattended script" test -e "$R/scripts/studio/wake_lock.sh"
check_not "core: no research agent" test -e "$R/.claude/agents/research-lead.md"
check_not "core: no pycache copied" test -e "$R/scripts/studio/__pycache__"
check "core: no plugin forms in copied .md files" no_plugin_forms "$R/.claude"
check "core: namespaced builder rewritten to bare name" grep -rqE '(^|[^:a-z-])builder' "$R/.claude/skills/plan-then-build/SKILL.md"
check "core: script paths rewritten to scripts/studio/" grep -rq 'scripts/studio/studio_config.py' "$R/.claude/skills"
check "core: studio.json written" json_eq "$R/.claude/studio.json" '{}'
check "core: install record written" test -f "$R/scripts/studio/.studio-install"
check "core: install record carries the kit version" grep -q '^version [0-9]' "$R/scripts/studio/.studio-install"
check "core: original setting kept" python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["model"] == "sonnet" else 1)' "$R/.claude/settings.json"
check "core: original hook kept" test "$(count_cmd "$R/.claude/settings.json" 'echo unrelated')" = 1
check "core: push guard hook merged" test "$(count_cmd "$R/.claude/settings.json" '"$CLAUDE_PROJECT_DIR"/scripts/studio/push_guard_hook.py')" = 1
check_not "core: no plugin root in settings" grep -q CLAUDE_PLUGIN_ROOT "$R/.claude/settings.json"
check "core: next steps printed" grep -q 'studio-init' <<<"$out"
check "core: studio_config.py validate passes" bash -c "cd '$R' && python3 scripts/studio/studio_config.py validate"

# ---- 2. idempotent re-run --------------------------------------------------
before="$(snapshot "$R")"
out="$(cd "$R" && bash "$INSTALL" --modules core 2>&1)"; rc=$?
check "rerun: exits 0" test "$rc" -eq 0
check "rerun: no duplicate push guard hook" test "$(count_cmd "$R/.claude/settings.json" 'push_guard_hook.py')" = 1
check "rerun: original hook still once" test "$(count_cmd "$R/.claude/settings.json" 'echo unrelated')" = 1
check "rerun: no file changed" test "$before" = "$(snapshot "$R")"

# ---- 3. the installed review guard runs in the target -----------------------
# Commit the install so the guard sees a clean tree, push it, then a local
# commit touching a reviewed path must fail the guard and a docs-only one pass.
git -C "$R" add -A && git -C "$R" commit -q -m install && git -C "$R" push -q origin main 2>/dev/null
check "guard: push passes with nothing ahead" bash -c "cd '$R' && bash scripts/studio/review_guard.sh push"
echo "x" >> "$R/scripts/studio/note.txt"; git -C "$R" add -A; git -C "$R" commit -q -m "touch reviewed path"
(cd "$R" && bash scripts/studio/review_guard.sh push >/dev/null 2>&1); rc=$?
check "guard: push exits 1 on an unreviewed reviewed-path commit" test "$rc" -eq 1
git -C "$R" reset -q --hard origin/main

# ---- 4. uninstall restores -------------------------------------------------
R2="$(new_repo uninst)"
pre="$(snapshot "$R2")"
(cd "$R2" && bash "$INSTALL" --modules core,context >/dev/null 2>&1)
check "uninstall: install exits 0 first" test -f "$R2/scripts/studio/context_budget.py"
out="$(bash "$INSTALL" --uninstall --target "$R2" 2>&1)"; rc=$?
check "uninstall: exits 0" test "$rc" -eq 0
check "uninstall: settings equal the original" json_eq "$R2/.claude/settings.json" "$ORIG_SETTINGS"
check_not "uninstall: agents removed" test -e "$R2/.claude/agents"
check_not "uninstall: skills removed" test -e "$R2/.claude/skills"
check_not "uninstall: scripts/studio removed" test -e "$R2/scripts"
check_not "uninstall: studio.json removed" test -e "$R2/.claude/studio.json"
check "uninstall: tree as before install, settings aside" test "$(echo "$pre" | grep -v settings.json)" = "$(snapshot "$R2" | grep -v settings.json)"
echo "keep me" > "$R2/.claude/mine.md"
(cd "$R2" && bash "$INSTALL" --modules core >/dev/null 2>&1)
bash "$INSTALL" --uninstall --target "$R2" >/dev/null 2>&1
check "uninstall: a file it did not install is kept" grep -q 'keep me' "$R2/.claude/mine.md"

# ---- 5. unattended pulls in core -------------------------------------------
R3="$(new_repo unatt)"
out="$(bash "$INSTALL" --modules unattended --target "$R3" 2>&1)"; rc=$?
check "unattended: exits 0" test "$rc" -eq 0
check "unattended: notice about core printed" grep -qi 'adding core' <<<"$out"
check "unattended: core agent present" test -f "$R3/.claude/agents/builder.md"
check "unattended: its own script present" test -f "$R3/scripts/studio/wake_lock.sh"
check "unattended: no plugin forms in copied .md files" no_plugin_forms "$R3/.claude"
check "unattended: core modules recorded" grep -q '^modules core,unattended$' "$R3/scripts/studio/.studio-install"
check "unattended: original hook kept" test "$(count_cmd "$R3/.claude/settings.json" 'echo unrelated')" = 1

# ---- 6. every module: rewrites hold ----------------------------------------
R4="$(new_repo all)"
bash "$INSTALL" --modules core,context,unattended,research --target "$R4" >/dev/null 2>&1; rc=$?
check "all: exits 0" test "$rc" -eq 0
check "all: research agent present" test -f "$R4/.claude/agents/research-lead.md"
check "all: no plugin forms in copied .md files" no_plugin_forms "$R4/.claude"
check "all: every scripts/studio/<name> in the copied .md files exists" script_refs_exist "$R4"
check_not "all: no sentence about where the plugin root is" grep -rqi 'two levels above' "$R4/.claude"
check "all: guard path in the self-review reference rewritten to the main checkout's copy" grep -qxF '"${REPO:-$(git rev-parse --path-format=absolute --git-common-dir)/..}"/scripts/studio/review_guard.sh push' "$R4/.claude/skills/self-review/reference/guard-and-audit.md"

# ---- 7. conflict -----------------------------------------------------------
R5="$(new_repo conflict)"
mkdir -p "$R5/.claude/agents"
echo "my own builder" > "$R5/.claude/agents/builder.md"
pre="$(snapshot "$R5")"
out="$(bash "$INSTALL" --modules core --target "$R5" 2>&1)"; rc=$?
check "conflict: exits 1" test "$rc" -eq 1
check "conflict: names the file" grep -q '.claude/agents/builder.md' <<<"$out"
check "conflict: nothing written" test "$pre" = "$(snapshot "$R5")"
out="$(bash "$INSTALL" --modules core --target "$R5" --dry-run 2>&1)"; rc=$?
check "conflict: dry run also exits 1" test "$rc" -eq 1

# ---- 8. --force overwrites -------------------------------------------------
out="$(bash "$INSTALL" --modules core --target "$R5" --force 2>&1)"; rc=$?
check "force: exits 0" test "$rc" -eq 0
check "force: builder overwritten" cmp -s "$R5/.claude/agents/builder.md" "$R/.claude/agents/builder.md"
check "force: hook merged" test "$(count_cmd "$R5/.claude/settings.json" 'push_guard_hook.py')" = 1
check "force: the user's file saved as .studio-bak" grep -qx 'my own builder' "$R5/.claude/agents/builder.md.studio-bak"

# ---- 9. dry run writes nothing ---------------------------------------------
R6="$(new_repo dry)"
pre="$(snapshot "$R6")"
bash "$INSTALL" --modules core --target "$R6" --dry-run >/dev/null 2>&1; rc=$?
check "dry run: exits 0" test "$rc" -eq 0
check "dry run: nothing written" test "$pre" = "$(snapshot "$R6")"

# ---- 10. upgrade, edits, backups and uninstall by hash ---------------------
# A newer kit: a copy of this one with one skill file and one script changed.
KIT2="$TMP/kit2"
cp -R "$KIT" "$KIT2"
echo "A line only the newer kit has." >> "$KIT2/plugins/studio-core/skills/self-review/SKILL.md"
echo "# newer" >> "$KIT2/plugins/studio-core/scripts/review_path.py"
R7="$(new_repo upgrade)"
bash "$INSTALL" --modules core --target "$R7" >/dev/null 2>&1
check "upgrade: record holds a sha256 per file" grep -qE '^file scripts/studio/review_guard.sh	sha256:[0-9a-f]{64}$' "$R7/scripts/studio/.studio-install"
out="$(bash "$KIT2/install.sh" --modules core --target "$R7" 2>&1)"; rc=$?
check "upgrade: changed kit files over untouched targets need no --force" test "$rc" -eq 0
check "upgrade: skill file updated" grep -q 'only the newer kit has' "$R7/.claude/skills/self-review/SKILL.md"
check "upgrade: script updated" grep -q '^# newer' "$R7/scripts/studio/review_path.py"
check_not "upgrade: no backup made of our own files" test -e "$R7/scripts/studio/review_path.py.studio-bak"
check "upgrade: record holds the new hash" grep -q "$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$R7/scripts/studio/review_path.py")" "$R7/scripts/studio/.studio-install"

# A file the user edited is a conflict, both ways.
echo "my edit" >> "$R7/.claude/skills/plan-then-build/SKILL.md"
pre="$(snapshot "$R7")"
out="$(bash "$INSTALL" --modules core --target "$R7" 2>&1)"; rc=$?
check "edited: a user-edited file is a conflict (exit 1)" test "$rc" -eq 1
check "edited: the conflict names it" grep -q 'plan-then-build/SKILL.md' <<<"$out"
check "edited: nothing written" test "$pre" = "$(snapshot "$R7")"
out="$(bash "$INSTALL" --modules core --target "$R7" --force 2>&1)"; rc=$?
check "edited: --force exits 0" test "$rc" -eq 0
check "edited: --force saved the edited file as .studio-bak" grep -q 'my edit' "$R7/.claude/skills/plan-then-build/SKILL.md.studio-bak"
check_not "edited: --force put the kit's copy in place" grep -q 'my edit' "$R7/.claude/skills/plan-then-build/SKILL.md"

# Uninstall keeps an edited file and a file that was there before install.
R8="$(new_repo keep)"
mkdir -p "$R8/.claude/agents"
cp "$R/.claude/agents/reviewer.md" "$R8/.claude/agents/reviewer.md"
out="$(bash "$INSTALL" --modules core --target "$R8" 2>&1)"; rc=$?
check "keep: install beside an identical file exits 0" test "$rc" -eq 0
check_not "keep: the identical file is not recorded" grep -q '^file .claude/agents/reviewer.md' "$R8/scripts/studio/.studio-install"
echo "my note" >> "$R8/.claude/skills/self-review/SKILL.md"
out="$(bash "$INSTALL" --uninstall --target "$R8" 2>&1)"; rc=$?
check "keep: uninstall exits 0" test "$rc" -eq 0
check "keep: the edited file is kept" grep -q 'my note' "$R8/.claude/skills/self-review/SKILL.md"
check "keep: uninstall lists the kept file" grep -q 'keep .claude/skills/self-review/SKILL.md' <<<"$out"
check "keep: the pre-existing identical file survives" cmp -s "$R8/.claude/agents/reviewer.md" "$R/.claude/agents/reviewer.md"
check_not "keep: an unedited installed file is removed" test -e "$R8/.claude/agents/builder.md"

# A record from before hashes: every file counts as edited.
R9="$(new_repo oldrecord)"
bash "$INSTALL" --modules core --target "$R9" >/dev/null 2>&1
sed -i.orig 's/	sha256:[0-9a-f]*$//' "$R9/scripts/studio/.studio-install" && rm -f "$R9/scripts/studio/.studio-install.orig"
out="$(bash "$INSTALL" --modules core --target "$R9" 2>&1)"; rc=$?
check "old record: a re-install with identical files exits 0" test "$rc" -eq 0
check "old record: the re-install writes hashes" grep -q 'sha256:' "$R9/scripts/studio/.studio-install"
sed -i.orig 's/	sha256:[0-9a-f]*$//' "$R9/scripts/studio/.studio-install" && rm -f "$R9/scripts/studio/.studio-install.orig"
out="$(bash "$INSTALL" --uninstall --target "$R9" 2>&1)"; rc=$?
check "old record: uninstall exits 0" test "$rc" -eq 0
check "old record: a file with no hash is kept" test -f "$R9/.claude/agents/builder.md"

# ---- 12. installed commands never run a review worktree's scripts ----------
# The docs-only command, taken from the installed skill text, run against a
# review worktree. First the kit is installed in the main checkout but not
# yet landed, so the worktree (cut from the remote main) has no scripts.
docs_only_cmd() { # target: the installed docs-only command, one line
  sed -n '/^```bash$/,/^```$/p' "$1/.claude/skills/self-review/reference/docs-only-path.md" | grep 'review_path.py' | head -n 1
}
run_docs_only() { # dir to run in, W, BASE, HEAD, [REPO]: the documented command's output
  local line
  line="$(docs_only_cmd "$R12")"
  line="${line//<BASE>/$3}"; line="${line//<HEAD>/$4}"
  (cd "$1" && W="$2" REPO="${5:-}" bash -c 'if [ -z "$REPO" ]; then unset REPO; fi; '"$line" 2>&1)
}
R12="$(new_repo docsonly)"
bash "$INSTALL" --modules core --target "$R12" >/dev/null 2>&1
check "docs-only: the installed command names the worktree with --repo" grep -q -- '--repo "$W"' <<<"$(docs_only_cmd "$R12")"
check_not "docs-only: and never changes into the worktree" grep -q 'cd "$W"' <<<"$(docs_only_cmd "$R12")"
W12="$TMP/docsonly-review/t-1"
git -C "$R12" worktree add -q -b review/t-1 "$W12" origin/main
B12="$(git -C "$W12" rev-parse HEAD)"
echo "more" >> "$W12/README.md"; git -C "$W12" commit -qam "docs on the branch"
H12="$(git -C "$W12" rev-parse HEAD)"
check_not "docs-only: the worktree has no scripts before the kit lands" test -e "$W12/scripts/studio/review_path.py"
check "docs-only: the documented command works from the main checkout" test "$(run_docs_only "$R12" "$W12" "$B12" "$H12" | head -n 1)" = docs-only
check "docs-only: and from inside the worktree" test "$(run_docs_only "$W12" "$W12" "$B12" "$H12" | head -n 1)" = docs-only
check "docs-only: and from elsewhere with REPO set, as the recipes set it" test "$(run_docs_only "$TMP" "$W12" "$B12" "$H12" "$R12" | head -n 1)" = docs-only
# Then the kit lands, and a branch edits its own copy of the script to call
# everything docs-only while it adds code: the main checkout's copy decides.
git -C "$W12" worktree remove --force "$W12" 2>/dev/null; git -C "$R12" worktree prune
git -C "$R12" add -A && git -C "$R12" commit -qm "kit" && git -C "$R12" push -q origin main 2>/dev/null
git -C "$R12" worktree add -q -b review/t-2 "$W12" origin/main
B12="$(git -C "$W12" rev-parse HEAD)"
printf 'print("docs-only")\n' > "$W12/scripts/studio/review_path.py"
mkdir -p "$W12/tools"; echo 'print(1)' > "$W12/tools/x.py"
git -C "$W12" add -A && git -C "$W12" commit -qm "code, and a script that waves it through"
H12="$(git -C "$W12" rev-parse HEAD)"
check "docs-only: a branch's own copy of the script is never the one run" test "$(run_docs_only "$W12" "$W12" "$B12" "$H12" | head -n 1)" = full
check "docs-only: not from the main checkout either" test "$(run_docs_only "$R12" "$W12" "$B12" "$H12" | head -n 1)" = full
# No installed .md file names a script relative to the working directory.
check_not "rewrite: no installed .md names scripts/studio/<file> without the main checkout's path" \
  bash -c "grep -rnE 'scripts/studio/[A-Za-z0-9_.-]' --include='*.md' '$R12/.claude' | grep -vE '/\.\.\}\"?/scripts/studio/'"

# ---- 13. a missing hook script never blocks a tool call --------------------
R13="$(new_repo hookmissing)"
bash "$INSTALL" --modules core,unattended --target "$R13" >/dev/null 2>&1
hook_cmd() { # settings file, script name: the installed command for it
  python3 - "$1" "$2" <<'PY'
import json, sys
for groups in json.load(open(sys.argv[1]))["hooks"].values():
    for g in groups:
        for h in g["hooks"]:
            if sys.argv[2] in h.get("command", ""):
                print(h["command"])
PY
}
for sc in push_guard_hook.py permission_gate.py prompt_alarm.py; do
  c="$(hook_cmd "$R13/.claude/settings.json" "$sc")"
  check "missing hook: $sc has an installed command" test -n "$c"
  rm -f "$R13/scripts/studio/$sc"
  (cd "$R13" && echo '{}' | CLAUDE_PROJECT_DIR="$R13" sh -c "$c" >/dev/null 2>&1); rc=$?
  check "missing hook: $sc deleted, its command exits 0 (got $rc)" test "$rc" -eq 0
done
bash "$INSTALL" --uninstall --target "$R13" >/dev/null 2>&1; rc=$?
check "missing hook: uninstall exits 0" test "$rc" -eq 0
check "missing hook: uninstall still finds and removes those commands" json_eq "$R13/.claude/settings.json" "$ORIG_SETTINGS"
# An upgrade from an install that wrote the older command form replaces it.
R14="$(new_repo hookupgrade)"
bash "$INSTALL" --modules core --target "$R14" >/dev/null 2>&1
python3 - "$R14" <<'PY'
import sys
r = sys.argv[1]
new = 'f="$CLAUDE_PROJECT_DIR"/scripts/studio/push_guard_hook.py; [ -f "$f" ] || exit 0; python3 "$f"'
old = 'python3 "$CLAUDE_PROJECT_DIR"/scripts/studio/push_guard_hook.py'
for rel, a, b in ((".claude/settings.json", new.replace('"', '\\"'), old.replace('"', '\\"')),
                  ("scripts/studio/.studio-install", new, old)):
    p = r + "/" + rel
    t = open(p).read()
    assert a in t, rel
    open(p, "w").write(t.replace(a, b))
PY
bash "$INSTALL" --modules core --target "$R14" >/dev/null 2>&1; rc=$?
check "upgrade: exits 0" test "$rc" -eq 0
check "upgrade: one push guard hook, not two" test "$(count_cmd "$R14/.claude/settings.json" 'push_guard_hook.py')" = 1
check "upgrade: and it is the new form" test "$(count_cmd "$R14/.claude/settings.json" '[ -f "$f" ] || exit 0')" = 1
bash "$INSTALL" --uninstall --target "$R14" >/dev/null 2>&1
check "upgrade: uninstall then restores the settings" json_eq "$R14/.claude/settings.json" "$ORIG_SETTINGS"

# ---- 11. bad input ---------------------------------------------------------
bash "$INSTALL" --modules nope --target "$R6" >/dev/null 2>&1; rc=$?
check "bad module: exits 2" test "$rc" -eq 2
bash "$INSTALL" --uninstall --target "$R6" >/dev/null 2>&1; rc=$?
check "uninstall without a record: exits 1" test "$rc" -eq 1

echo
echo "$PASS passed, $FAIL failed ($((PASS + FAIL)) assertions)"
[ "$FAIL" -eq 0 ]
