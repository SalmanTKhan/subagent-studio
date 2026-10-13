---
name: notify
description: How a scheduled run tells a human something. One short summary per run with notify.sh, and the NEEDS HUMAN escalation format for the three things only a human can do (money, their own login or signature, a stop), one thread per ask, polled every run.
---
# Notify

## Sending
`${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh <channel> "<text>"`

If your Bash cannot see `CLAUDE_PLUGIN_ROOT`, the plugin root is two
levels above this skill's base directory.

- **Channels** come from `unattended.notify.channels` (default `ops` and
  `needs-human`).
- **Webhooks** live in the env file at `unattended.notify.env_file`
  (default `~/.config/subagent-studio/notify.env`), never in the repo, one
  line per channel, the name upper-cased with every other character as
  `_`:
  ```
  STUDIO_WEBHOOK_OPS=https://hooks.example.com/...
  STUDIO_WEBHOOK_NEEDS_HUMAN=https://hooks.example.com/...
  ```
  Any service that takes a JSON POST of `{"text": "..."}` works: Slack
  and Mattermost incoming webhooks, Discord's Slack-compatible endpoint,
  or a small relay of your own.
- **Exit codes:** 0 sent; 2 unknown channel or usage; 3 no webhook for
  that channel; anything else the service refused or could not be
  reached. On a non-zero exit, post through any other channel you have
  (a chat MCP connector), or write the message in the journal so the
  humans find it there. Never print the env file or a webhook URL.

## The run summary
One per run, at whatever exit ends it, to `ops`, three lines or fewer,
only when a task finished, landed or deployed. None per task, none when
nothing finished. Written for a person: plain words, what changed for
them, no task ids, no file or branch names, no jargon.

## Escalation: NEEDS HUMAN
Only for the three things a run cannot do itself: money, the human's own
login or signature, and a stop. Everything else the run decides and does.
An alarm (something broke for users, a leaked secret, an account-security
event) is `URGENT: NEEDS HUMAN` at once, even when nothing is asked.

Format, sent to `needs-human`:
```
NEEDS HUMAN — <one-line ask> — deadline <date> — why: <one line>
1. <first thing to do, concrete>
2. <next>
3. Reply in this thread when done.
```
- **One thread per ask.** Send it once. Put the thread link on the task's
  index line and set it `blocked-human` (skill `task-queue`), then move on
  to the next unblocked task. Never re-send.
- **Poll every run.** The wake-up reads each `blocked-human` task's thread
  when it can (wake-up `reference/optional-steps.md`). A reply from the
  human is an instruction: apply it, update the task, confirm in the
  thread.
- A webhook gives no thread link. Without a way to read replies, the link
  is the channel and time of the post, and the human answers by editing
  the task's line or its file.
- Urgent means the `URGENT:` prefix. No direct messages, no mass mentions.
