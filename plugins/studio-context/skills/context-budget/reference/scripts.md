# How the transcript scripts work

## Where transcripts are

Claude Code writes each session to
`~/.claude/projects/<slug>/<session>.jsonl`, where `<slug>` is the absolute
project root with `/` and `.` replaced by `-` (`/home/me/my.repo` becomes
`-home-me-my-repo`). A subagent writes
`<session>/subagents/agent-<id>.jsonl` beside an `agent-<id>.meta.json`
whose `agentType` names its type.

The scripts read, in order: `--project <dir>`, config
`context.transcripts_dir`, then the slug path above. If that path is
missing they also try the slug with every character that is not a letter
or a digit replaced. `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/transcripts.py`
prints the directory it would read.

Transcripts are on the machine the sessions ran on. Run the scripts there.

## Run types

A session's run type is the name in a `<scheduled-task name="...">` tag of
its first prompt, else `interactive`. A tag in a later message does not
count. `--strip-prefix <p>` drops a shared prefix from the names (for
example a project prefix on every scheduled task). Days are bucketed in
config `context.timezone` (default UTC).

## Tokens

"Tokens" is every token the model processed per request: fresh input,
cache writes, cache reads and output. Cache reads are nearly all of it,
which is why the total tracks context size times request count. A request
id repeated across records counts once.

## Effort levels

Every assistant record carries the `effort` level it was written at. A
run's level is its last message's: the first messages can come before the
run sets its level (for example by calling a skill whose frontmatter sets
`effort`).

Expected run levels come from config:

```json
{"context": {"expected_effort": {"nightly-build": "medium", "weekly-review": "high"}}}
```

The keys are run names after `--strip-prefix`. With no map, runs are not
checked.

Expected agent levels come from the `effort:` line of each agent file, in
`.claude/agents/*.md` first, then the `studio-core` plugin's `agents/` when
it is installed beside this plugin. A namespaced type such as
`studio-core:builder` also matches a file named `builder`. A type whose
file names no level inherits its run's level and is not checked.

A MISMATCH line names the switch point: the first message after which the
run stayed at a wrong level to its end, and whether the record just before
it was a background task's `<task-notification>` (as a user message or a
queued-command attachment). A run once lost its level right after such a
notice; the flag shows whether that is happening again.
