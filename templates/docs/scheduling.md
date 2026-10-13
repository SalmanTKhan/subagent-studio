# Scheduling the wake-up

The wake-up is one prompt, `prompts/wake-up.md`, run on a timer. Pick one
of the three ways below. Whichever you pick:

- **One run at a time.** The skill takes `.wake-lock` itself (or
  `unattended.lock_file`) and a second run exits on its line, so an
  overlap is safe, but space the runs further apart than
  `unattended.run_minutes`.
- **The permission gate recognises a scheduled run** by the start of its
  first prompt: `unattended.scheduled_prompt_prefix`, default
  `<scheduled-task`. The desktop app adds that tag itself. From cron or CI,
  put a first line like `<scheduled-task name="wake-up">` in front of the
  prompt, as the examples below do, or the gate treats the run as attended
  and leaves its prompts alone.
- **The notify webhooks** live outside the repo, in
  `unattended.notify.env_file` on the machine that runs the job (for CI, a
  secret written to that file in a step).

## 1. Claude Code desktop: a scheduled task
1. Open the project folder in the desktop app's Code tab.
2. Create a scheduled task. Paste the contents of `prompts/wake-up.md` as
   its prompt, name it `wake-up`, set the folder and the schedule (for
   example every six hours) and the permission mode.
3. Keep the machine awake while the app is open; a sleeping machine fires
   the missed tasks late and sometimes together, which the lock handles.

Desktop tasks start their prompt with a `<scheduled-task name="...">` tag,
which the permission gate reads. The run name in an alarm is the task's
name.

## 2. cron with `claude -p`
```cron
0 */6 * * * cd /path/to/project && { printf '<scheduled-task name="wake-up">\n'; cat prompts/wake-up.md; } | claude -p --permission-mode bypassPermissions --permission-prompts none --output-format json >> "$HOME/.local/state/wake-up.log" 2>&1
```
- `-p` (print mode) runs one prompt with no terminal and exits; the
  prompt comes from stdin.
- `--permission-mode` sets the session's baseline. Choices are `manual`,
  `acceptEdits`, `auto`, `dontAsk`, `plan` and `bypassPermissions`.
  - **`bypassPermissions`** (same as `--dangerously-skip-permissions`)
    skips permission prompts and safety checks: every tool call runs at
    once, including writes to protected paths. A few actions still prompt
    in every mode: explicit ask rules, `AskUserQuestion`, and `rm` or
    `rmdir` of a critical path. Deny rules still apply. Claude Code's own
    docs say to use this mode only in an isolated container or VM, as a
    non-root user. On your own machine it means the run can do anything
    your user can, so the permission gate's Bash rules (no recursive delete
    of the repo, home or worktree root, no force push of main, no `sudo`)
    are the only check left between a bad command and your files.
  - `auto` lets a classifier review each action instead; `dontAsk` denies
    everything not pre-approved by `--allowedTools` or settings. Both are
    safer than `bypassPermissions` and may need allow rules for the
    commands your runs use.
- `--permission-prompts none` tells Claude Code nobody will answer a
  prompt: anything that would prompt is denied unless a `PermissionRequest`
  hook (the gate) allows it, and the run carries on.
- `--output-format json` gives one result object per run, with its cost,
  for your log.
- Plugins: a `-p` run loads the plugins installed for your user. Without
  them, pass `--plugin-dir <path>` once per plugin.
- cron's `PATH` is short: use the full path to `claude` if it is not
  found, and make sure `python3`, `git` and `curl` resolve.

## 3. GitHub Actions
```yaml
name: wake-up
on:
  schedule:
    - cron: "0 */6 * * *"
  workflow_dispatch: {}
concurrency:
  group: wake-up
  cancel-in-progress: false
jobs:
  wake-up:
    runs-on: ubuntu-latest
    timeout-minutes: 120
    permissions:
      contents: write
      id-token: write
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
      - name: Notify webhooks
        env:
          OPS: ${{ secrets.STUDIO_WEBHOOK_OPS }}
          NEEDS_HUMAN: ${{ secrets.STUDIO_WEBHOOK_NEEDS_HUMAN }}
        run: |
          mkdir -p ~/.config/subagent-studio
          printf 'STUDIO_WEBHOOK_OPS=%s\nSTUDIO_WEBHOOK_NEEDS_HUMAN=%s\n' "$OPS" "$NEEDS_HUMAN" \
            > ~/.config/subagent-studio/notify.env
      - name: Build the prompt
        id: prompt
        run: |
          {
            echo 'text<<PROMPT_EOF'
            echo '<scheduled-task name="wake-up">'
            cat prompts/wake-up.md
            echo 'PROMPT_EOF'
          } >> "$GITHUB_OUTPUT"
      - uses: anthropics/claude-code-action@v1
        with:
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
          plugin_marketplaces: "https://github.com/<owner>/subagent-studio.git"
          plugins: |
            studio-core@subagent-studio
            studio-unattended@subagent-studio
          prompt: ${{ steps.prompt.outputs.text }}
          claude_args: "--permission-mode bypassPermissions"
```
- With a `prompt` input the action runs in automation mode on any event,
  a `schedule` included. The prompt step puts the scheduled-task tag in
  front of the prompt file, as in the cron example.
- With a subscription instead of an API key, use
  `claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}`
  (made with `claude setup-token`).
- The runner is a fresh VM each time, which is the isolation
  `bypassPermissions` wants. The lock file means nothing across runners:
  the `concurrency` group is what stops two runs overlapping.
- The run pushes to your repo, so the push guard and the review rules apply
  exactly as on your machine. GitHub disables schedules in public repos
  after 60 days without activity.
- Cap the cost with `timeout-minutes`, and with `--max-turns` in
  `claude_args` if your version supports it.
