# Gathering: the gatherer's brief, the fact file, the rules and the browser reader

Open when launching a gatherer or checking its file (SKILL.md sections 3
and 4). A gatherer is one fresh `studio-research:gatherer` per block of
`research-plan.md`. It reads live public pages and writes one fact file,
every figure with its URL and read date. It never decides a criterion.

## The launch
```
Agent { subagent_type: "studio-research:gatherer",
        description: "Research <slug>: B<N> <block slug>",
        prompt: <the brief below>,
        model/effort: from roles.gatherer when set }
```
Blocks run in parallel, up to `research.max_gatherers` at once, except
that blocks marked `bulk fetch from <site>: yes` for the same site run one
after another.

## The gatherer's brief (paste, with the block verbatim)
```
You are gatherer B<N> of the research run <slug> (skill research-run). Read <this skill's base directory>/reference/gathering.md first and follow it.

Tree: <repo root>. You write one file: <out_dir>/<slug>/facts/<block slug>.md. You never commit, stage, push or post; the host commits your file. This prompt names the tree you write in, and it wins over your agent file.

Your block, verbatim from research-plan.md:
<the block>

Report in under 300 words: the file's path; each question of the block with its answer in one line, or "not read" and why; the pages that refused; the pages listed under "Needs a browser", each with the figure it would answer; anything the writer must know.
```

## The fact file
```
# B<N> <block title>: facts read <YYYY-MM-DD>
Block: <title> · Read between <HH:MM> and <HH:MM> (from `date`)

## <candidate id and name>
| Fact | Value | URL | Read date | Note |
|---|---|---|---|---|
| <what was counted or read> | <the figure as read> | <the page> | <YYYY-MM-DD> | <the command; "sample of N"; "from the cache, fetched <date>"> |

## Answers to the block's questions
1. <question>: <answer, pointing at the rows above> | not read: <why>

## Not read
- <page>: not readable on <date> (<status or what refused>)

## Needs a browser
- <URL>: <the figure it would answer> (question <n>)
```
- **Every figure has a URL and a read date.** A figure from a command
  carries the URL the command fetched and the command in the note.
- **A sample says so** in the note, with its size.
- **An unknown is written as unknown,** never estimated and never zero.
- **Complaints and opinions** found on a page are summed up in a few
  words, or quoted briefly with no name in the quote.

## Public pages only
- Only pages anyone can open with no account. No sign-in, form, trial,
  spend or download.
- **Never write down** a private person's name, username or handle.
  Company names, product names and prices are facts and are written down.
- A page that refuses: retry once, then `not readable on <date>`.
- A community place (a forum, a board) is read only as titles, dates,
  reply counts and links, through a command that selects those fields.
  A thread's body and its posters are never fetched or printed.

## Reading lessons (each one cost a wrong figure once)
- **One scraper at a time against a single site.** Two at once drew HTTP
  429 and half-empty results. Respect a site's rate limit and cache what
  you fetch.
- **A list or search card is not the figure.** A summary card printed a
  year as a review count, and another printed 0 for an item with
  thousands. A figure a criterion rests on is read from the item's own
  page, and the note says `card showed <n>` when they differ.
- **A field's name is not its meaning.** A parsed `free` flag meant
  "installs without a charge", not "has a free plan". Quote the source
  text beside any flag a criterion uses.
- **A truncated field misses the end.** A text field cut at a fixed length
  lost the top price tiers. Read the page itself for a figure in long text.
- **Pagination starts at the first page.** A read that started at
  `?page=1` missed page 0, the newest items.
- **A list sorted by last activity stops on last activity,** never on
  creation date: an old thread with a new reply sits on the first page.
  Read two more pages past the window as a coverage check, because the
  order is not strict, and count unique ids, since a bumped item repeats
  on two pages.
- **A bound is not a fail.** When not every item can be read, record the
  bound (`sum >= <floor> over <n> items, <u> unread`) and write
  `not read` for that criterion, never `fail`.
- **Matching is judgement.** Where a count needs judging which items match
  a criterion, list the items verbatim with dates and links and leave the
  count to the writer.

## Pages drawn only in a browser
Some public pages answer HTTP 200 with a JavaScript shell, so curl and
WebFetch read nothing. A gatherer that meets one:
1. Tries once a public data call the page makes itself, with no sign-in,
   key or cookie.
2. Still no figure: lists the page under `## Needs a browser`, one line
   each, and names it in the report. It never takes the figure from the
   shell, a snippet or another page, and never drives a browser from the
   shell.

## What the host checks when a report lands
- The file exists at the block's path, and each question has an answer or
  `not read`.
- A spot check of three rows: each has a URL and a read date.
- Then the host commits the file by path and logs
  `<ISO time> phase=gather file=<slug>/facts/<block>.md`. The host never
  reads the `Needs a browser` pages itself.

## The browser reader
Only when `research.browser` is true. **The trigger is any unmarked line
under `## Needs a browser` in a committed fact file.** A line is marked
once it ends in `read in the Browser <YYYY-MM-DD>` or
`not readable on <YYYY-MM-DD> (...)`. After a gather phase's files are
committed, and again before the writer when resuming, the host greps the
fact files for unmarked lines and launches one fresh agent for all of
them, none when every line is marked.
```
Agent { subagent_type: "studio-research:gatherer-browser",
        description: "Research <slug>: browser read",
        prompt: <the brief below>,
        model/effort: from roles.gatherer-browser, else roles.gatherer }
```
The brief:
```
You are the browser reader of the research run <slug> (skill research-run). Read the sections "The fact file" and "Public pages only" of <this skill's base directory>/reference/gathering.md first and follow them.

Tree: <repo root>. You edit only the fact files named below: in each, its "## Needs a browser" lines and a "## Read in the Browser" section you add at the end. You never commit, stage, push or post.

The pages, each with its file and the figure wanted:
- <slug>/facts/<block>.md: <URL>: <the figure wanted>

Use your browser tools. Sign in nowhere, decline non-essential cookies on every banner, accept no terms, fill no form. A page that shows its figure only after a sign-in, a form or accepted terms is not read.

For each page, read the figure wanted and nothing else. Add a row under "## Read in the Browser" in the fact table's shape, with the page's URL and the read date from `date`. A figure the page does not show is unknown. Then mark the page's line by appending "read in the Browser <YYYY-MM-DD>" or "not readable on <YYYY-MM-DD> (<what the page showed>)".

Report in under 200 words: each page with its figure or why it was not read, and the files you changed.
```
When the report lands, the host spot checks one row per file, commits the
changed files by path and logs `phase=browser <n> pages file=<path>`. A
browser reader that finds it has no browser tool reports so; its pages
stay unread and the writer names them.
