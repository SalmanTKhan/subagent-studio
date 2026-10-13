#!/usr/bin/env bash
# Tests for studio-unattended's notify.sh: a webhook the service refuses
# (404) exits non-zero, so the caller falls back; a webhook the service
# accepts exits 0 and delivers the JSON body; no webhook exits 3; an unknown
# channel exits 2; channels and the env file come from the config.
#   bash kit/tests/notify_test.sh
# HOME is a throwaway directory holding a fake notify.env, so no real
# webhook is ever read or called. The webhook is a stub on 127.0.0.1 at a
# free port. One line per case; exit 1 if any fails.
set -euo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
NOTIFY="$KIT/plugins/studio-unattended/scripts/notify.sh"
unset NOTIFY_ENV_FILE
TMP="$(mktemp -d)"
STUB_PID=""
cleanup() {
  if [[ -n "$STUB_PID" ]]; then kill "$STUB_PID" 2>/dev/null || true; wait "$STUB_PID" 2>/dev/null || true; fi
  [[ "$TMP" == */tmp.* ]] && rm -rf "$TMP"
}
trap cleanup EXIT
FAILS=0
check() { # name, command...
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; FAILS=1; fi
}

# The stub answers every POST with the status and body in $TMP/reply
# ("<code> <body>") and saves the request body to $TMP/received.
cat > "$TMP/stub.py" <<'PY'
import http.server, os, socketserver, sys
d = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(os.path.join(d, "received"), "wb") as f: f.write(body)
        code, text = open(os.path.join(d, "reply")).read().split(" ", 1)
        out = text.encode()
        self.send_response(int(code)); self.send_header("Content-Length", str(len(out)))
        self.end_headers(); self.wfile.write(out)
    def log_message(self, *a): pass
class S(http.server.HTTPServer):
    def server_bind(self):  # skip HTTPServer's getfqdn, a reverse DNS lookup that can hang
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "127.0.0.1", self.server_address[1]
s = S(("127.0.0.1", 0), H)
open(os.path.join(d, "port.tmp"), "w").write(str(s.server_address[1]))
os.rename(os.path.join(d, "port.tmp"), os.path.join(d, "port"))
s.serve_forever()
PY
python3 "$TMP/stub.py" "$TMP" & STUB_PID=$!
for _ in $(seq 50); do [[ -f "$TMP/port" ]] && break; sleep 0.1; done
PORT="$(cat "$TMP/port")"

# A project with no config (defaults: ops, needs-human) and one that adds a
# "build log" channel and moves the env file.
mkdir -p "$TMP/proj" "$TMP/proj2/.claude"
printf '{"unattended": {"notify": {"channels": ["ops", "build log"], "env_file": "~/hooks.env"}}}\n' \
  > "$TMP/proj2/.claude/studio.json"

mkdir -p "$TMP/home/.config/subagent-studio" "$TMP/empty/.config/subagent-studio"
printf 'STUDIO_WEBHOOK_OPS=http://127.0.0.1:%s/services/a\n' "$PORT" \
  > "$TMP/home/.config/subagent-studio/notify.env"
: > "$TMP/empty/.config/subagent-studio/notify.env"
printf '# comment\nexport STUDIO_WEBHOOK_BUILD_LOG="http://127.0.0.1:%s/b"\n' "$PORT" \
  > "$TMP/home/hooks.env"

run() { # home, project, args... ; sets RC
  set +e; HOME="$1" CLAUDE_PROJECT_DIR="$2" bash "$NOTIFY" "${@:3}" >"$TMP/out" 2>&1; RC=$?; set -e
}

printf '404 no_service' > "$TMP/reply"; rm -f "$TMP/received"
run "$TMP/home" "$TMP/proj" ops "hello"
check "404 exits non-zero (rc=$RC)" test "$RC" -ne 0
check "404 exit is not 2 or 3 (rc=$RC)" test "$RC" -ne 2 -a "$RC" -ne 3

printf '200 ok' > "$TMP/reply"; rm -f "$TMP/received"
run "$TMP/home" "$TMP/proj" ops 'installs "3"'
check "200 ok exits 0 (rc=$RC)" test "$RC" -eq 0
check "200 ok delivers the JSON body" \
  python3 -c 'import json,sys; assert json.load(open(sys.argv[1])) == {"text": "installs \"3\""}' "$TMP/received"

run "$TMP/empty" "$TMP/proj" ops "hello"
check "no webhook exits 3 (rc=$RC)" test "$RC" -eq 3
run "$TMP/home" "$TMP/proj" needs-human "hello"
check "a known channel with no line in the env file exits 3 (rc=$RC)" test "$RC" -eq 3
run "$TMP/nohome" "$TMP/proj" ops "hello"
check "a missing env file exits 3 (rc=$RC)" test "$RC" -eq 3

run "$TMP/home" "$TMP/proj" nowhere "hello"
check "unknown channel exits 2 (rc=$RC)" test "$RC" -eq 2
run "$TMP/home" "$TMP/proj"
check "no arguments exits 2 (rc=$RC)" test "$RC" -eq 2
run "$TMP/home" "$TMP/proj" ops
check "no text exits 2 (rc=$RC)" test "$RC" -eq 2

# config: channels and env file from .claude/studio.json, "~" expanded
rm -f "$TMP/received"
run "$TMP/home" "$TMP/proj2" "build log" "built"
check "a configured channel posts through its own webhook (rc=$RC)" test "$RC" -eq 0
check "it delivered the text" \
  python3 -c 'import json,sys; assert json.load(open(sys.argv[1])) == {"text": "built"}' "$TMP/received"
run "$TMP/home" "$TMP/proj2" needs-human "hello"
check "a channel the config drops is unknown (rc=$RC)" test "$RC" -eq 2

# NOTIFY_ENV_FILE overrides the configured file
set +e; NOTIFY_ENV_FILE="$TMP/empty/.config/subagent-studio/notify.env" HOME="$TMP/home" \
  CLAUDE_PROJECT_DIR="$TMP/proj" bash "$NOTIFY" ops "x" >/dev/null 2>&1; RC=$?; set -e
check "NOTIFY_ENV_FILE overrides the env file (rc=$RC)" test "$RC" -eq 3

exit "$FAILS"
