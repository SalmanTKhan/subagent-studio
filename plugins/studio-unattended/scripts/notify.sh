#!/usr/bin/env bash
# Send a short text to a human through an incoming webhook.
# Usage: notify.sh <channel> "<text>"
#
# Channel names come from unattended.notify.channels (default: ops,
# needs-human). Webhook URLs live in the file at unattended.notify.env_file
# (default ~/.config/subagent-studio/notify.env), never in the repo, one per
# channel, the name upper-cased with every other character turned into "_":
#   STUDIO_WEBHOOK_OPS=https://hooks.example.com/...
#   STUDIO_WEBHOOK_NEEDS_HUMAN=https://hooks.example.com/...
# The file is read as data, never sourced. Any service that takes a JSON
# POST of {"text": "..."} works (Slack, Mattermost, Discord's /slack
# endpoint, Rocket.Chat, a small relay of your own).
#
# Exit 0 = the service accepted the post; 2 = unknown channel or usage;
# 3 = no webhook configured for the channel; any other non-zero = the
# service refused the post (a 4xx/5xx, for example a removed webhook) or
# could not be reached. On a non-zero exit the caller falls back to whatever
# other channel it has, or records the message in the journal.
#
# Env override (tests): NOTIFY_ENV_FILE replaces the configured env file.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ $# -lt 1 || -z "${1:-}" ]]; then
  echo 'usage: notify.sh <channel> "text"' >&2; exit 2
fi
CHANNEL="$1"

# Channels (one per line), then the env file path as the last line.
cfg="$(python3 - "$HERE" <<'PY' 2>/dev/null || true
import os, sys
sys.path.insert(0, sys.argv[1])
import studio_config as sc
try:
    cfg = sc.load()
except sc.ConfigError:
    cfg = sc.DEFAULTS
n = cfg.get("unattended", {}).get("notify", {})
for c in n.get("channels", ["ops", "needs-human"]):
    print("C\t" + c)
print("E\t" + os.path.expanduser(n.get("env_file", "~/.config/subagent-studio/notify.env")))
PY
)"
[[ -n "$cfg" ]] || cfg="$(printf 'C\tops\nC\tneeds-human\nE\t%s' "$HOME/.config/subagent-studio/notify.env")"

known=0
while IFS=$'\t' read -r kind val; do
  [[ "$kind" == C && "$val" == "$CHANNEL" ]] && known=1
done <<< "$cfg"
if [[ "$known" -ne 1 ]]; then
  echo "notify.sh: unknown channel: $CHANNEL (see unattended.notify.channels)" >&2; exit 2
fi
if [[ $# -lt 2 || -z "${2:-}" ]]; then
  echo 'usage: notify.sh <channel> "text"' >&2; exit 2
fi

ENV_FILE="${NOTIFY_ENV_FILE:-$(printf '%s\n' "$cfg" | awk -F '\t' '$1 == "E" { print $2 }')}"
case "$ENV_FILE" in "~/"*) ENV_FILE="$HOME/${ENV_FILE#\~/}" ;; esac

VAR="STUDIO_WEBHOOK_$(printf '%s' "$CHANNEL" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9]/_/g')"
URL=""
if [[ -f "$ENV_FILE" ]]; then
  URL="$(awk -v k="$VAR" '
    { sub(/^[ \t]*export[ \t]+/, "") }
    index($0, k "=") == 1 { v = substr($0, length(k) + 2) }
    END { print v }' "$ENV_FILE")"
  URL="${URL%$'\r'}"
  URL="${URL#\"}"; URL="${URL%\"}"; URL="${URL#\'}"; URL="${URL%\'}"
fi
if [[ -z "$URL" ]]; then
  echo "notify.sh: no webhook configured for $CHANNEL ($VAR in the notify env file)" >&2; exit 3
fi

python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1]}))' "$2" \
  | curl -sS --fail-with-body -X POST -H 'Content-Type: application/json' --data-binary @- "$URL"
echo
