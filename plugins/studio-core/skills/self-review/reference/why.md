# Why the rule is this shape

## A stranger finds what the author cannot
Builders and the orchestrator check their own work against their own
understanding. A fresh agent with the same repo and none of that context
finds what they cannot. The first fresh reviews of one project found six
major issues in one session's pushed code, and two blockers in each of the
first two drafts of this very rule, all in recipes that failed when run. The
recipes that matter now live in `review_guard.sh` and its tests, not in
prose.

## Two passes, then stop
Pass one is the author's own review, run by a fresh `reviewer-pass-one` so
the orchestrator's context stays small. Pass two is one fresh reviewer. Rounds
after the first fresh review found smaller and smaller things for the time
they took, so there is no third: the author fixes, checks each fix with a
test, and the landing names the fixes on a `Fixed-after-review:` line the
audit can check.

## One reviewer per change, at the landing
A change is the branch's `BASE..HEAD`. One fresh reviewer reads it once, when
the branch is whole. Never one reviewer per plan step: a step's check is the
orchestrator's re-proof through a fresh agent (skill `plan-then-build` §7).
Per-step reviews once doubled the reviewer count (about two reviewers per
landing) for no extra findings that mattered.

## Fixed SHAs
A reviewer that reads a moving branch name reviews whatever the branch is
when it looks, which may not be what lands. `BASE` and `HEAD` are written
down before the review, the audit checks the landing against them, and the
fixes after the review are named by their own range.

## The ride-along stat
A commit made with `git add -A`, or a stray staged file, carries unreviewed
work into a reviewed range. The reviewer's first command is the diff stat
over the whole range, and any reviewed-path file not in the change's own
paths is a blocker. Commits are made by path for the same reason.

## `--remerge-diff`, not `--cc`
A merge that took a file whole from one side shows nothing under
`git show --cc`, so a bad resolution hides. `--remerge-diff` shows what the
resolution changed against a clean re-merge.

## Guards fail closed
A shell variable holding several paths, passed as one word, once let an
unreviewed draft reach the main branch: the guard compared one long string
to the reviewed paths and matched nothing. The guard now fails closed on
anything it cannot parse, and the recipes write paths out.

## The shared tree stays clean
Only reviewed landings and plain docs enter the shared tree's main branch,
so any session's push from it, a close-out included, cannot carry a change
still under review. The guard runs before every such push, and the optional
hook makes that automatic.

## Installs through links
A review copy that linked another tree's dependency directory, then ran an
install, emptied the other tree's dependencies. Reviewers install inside
their own scratch copy and never through a link.
