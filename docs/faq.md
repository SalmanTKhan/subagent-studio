# FAQ

**Why not the built-in Plan or general-purpose agents?**
A general-purpose agent carries every tool schema the session has, on every
request; the original project estimated a builder launched that way at
about 80k tokens of starting context against about 20k for a lean type,
46k of it measured as tool schemas the agent never used. The built-in types also fix no model or
effort level, and a planner or reviewer with write tools can drift into
fixing things. The kit's types carry only the tools their role uses. Use
`general-purpose` when a step needs a tool no type has (a browser, a
connector), and record why.

**Why a fresh reviewer and not the builder?**
The builder checks its work against its own understanding, which is where
its mistakes live. A fresh agent with the same repo and none of that context
finds what the author cannot. It is also launched new each time, never
resumed, so an earlier conversation cannot steer it.

**Why `--no-ff` merges?**
So the commits the reviewer read, and the fixes after the review, reach
main with their own SHAs, under one merge commit whose message names both
ranges. `review_guard.sh audit` can then check each landing against its
trailers. A squash or rebase makes new commits nobody read, and the audit
has nothing to compare.

**Can I use one review pass?**
Yes: `core.review.passes: 1` runs only the fresh reviewer. You lose the
author's checklist pass, which catches cheap things (a secret in the diff,
a CI command nobody ran) before the expensive review. The fresh pass is the
one not to drop.

**Does this work without plugins?**
Yes. `install.sh --modules core --target <project>` copies the agents and
skills into `.claude/`, the scripts into `scripts/studio/` and the hooks
into `.claude/settings.json`, and drops the `studio-core:` prefixes. The
skills read the same `.claude/studio.json`.

**Does it work with pull requests?**
Yes: `core.review.land: pr`. The session opens the pull request with the
trailers in its body; merge it with a merge commit that keeps them.

**What does it cost?**
More agent calls per change: a builder, a pass-one reviewer and a fresh
reviewer at least, plus a planner and a check per step for planned work.
Each call starts small, and the orchestrator stays small, so total tokens
can still fall, but the process first raised the original project's cost
per scheduled run about sixfold, which is why the context budgets exist.
Its later fall had several causes besides the kit's setup (see
`evidence.md`). For a throwaway script it is not worth it.

**Which Claude Code version do I need?**
Plugin support for the plugin install, any build for the copy-in install.
Per-call `model` and `effort` from `roles` need v2.1.292 or later; without
them, each agent file's frontmatter decides.
