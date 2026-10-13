# Examples

## The toy repo

`make_toy_repo.sh` builds a tiny Python project that has had one change
made the kit's way. It is a script rather than a checked-in repository, so
the example stays small and nobody has to clone a repo inside a repo.

```bash
./examples/make_toy_repo.sh /tmp/studio-toy
```

It creates:

- `/tmp/studio-toy/origin.git`: a bare repository standing in for the remote;
- `/tmp/studio-toy/toy`: the working clone, on `main`;
- `/tmp/studio-toy/toy-review`: the default worktree root
  (`../<repo>-review`), empty again after the cleanup.

Inside `toy/`:

| Path | What it is |
|---|---|
| `src/toy/__init__.py` | the package, with `greet(name)` |
| `tests/test_toy.py` | unittest tests, run by `python3 -m unittest discover -s tests` |
| `.claude/studio.json` | the config: that one CI command, reviewed paths `src`, `tests`, `.claude`, `CLAUDE.md`, two passes, `merge-no-ff` landing |
| `CLAUDE.md` | the short block `studio-init` writes, between its markers |
| `plans/add-greeting.md` | the saved plan, in the shape `plan-then-build` asks planners for |

## The history it leaves

```
git -C /tmp/studio-toy/toy log --graph --format='%h %s'
```

1. **The base commit:** the package, the tests and the config.
2. **The plan commit** (`plan: T-1 add greeting`). `plans/` is not a
   reviewed path, so it goes straight to `main`, before any builder starts.
3. **The review branch** `review/2026-10-13-t-1-greeting`, cut in its own
   worktree from `origin/main`. Its first commit is what the builder wrote:
   `greet()` and a test. That commit is the reviewed `HEAD`.
4. **A fix after review.** The story is that the fresh reviewer found a
   major (an empty name gave `Hello, !`). The author fixed it on the branch
   with a test that fails without the fix. That commit is `FIX`.
5. **The landing:** a `--no-ff` merge onto `origin/main`, pushed from the
   worktree, with both trailers:
   ```
   Reviewed-by: fresh reviewer agent, <BASE7>..<HEAD7>, 1 round (0 blocker, 1 major, 0 minor; 1 fixed, 0 queued)
   Fixed-after-review: author, <HEAD7>..<FIX7>, 1 fix (major: empty name gave 'Hello, !')
   ```
6. **Cleanup:** the worktree is removed and the branch is deleted on both
   sides once it is an ancestor of `origin/main`.

The script does not run Claude Code. The agent steps are written as the
commits and messages a session would leave, so you can inspect and audit
the result offline.

## Try the guard on it

```bash
cd /tmp/studio-toy/toy
ROOT=$(git rev-list --max-parents=0 HEAD)
<kit>/plugins/studio-core/scripts/review_guard.sh audit "$ROOT"   # exit 0
echo 'x = 1' >> src/toy/__init__.py && git commit -qam "direct edit"
<kit>/plugins/studio-core/scripts/review_guard.sh push            # exit 1
```

`<kit>` is where you cloned this repository. In a copy-in install the
script is at `scripts/studio/review_guard.sh`. `tests/example_test.sh`
runs these checks, and the unit tests, on every CI run.
