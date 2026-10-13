# Rubric: which job queue library should we adopt?

Copy this file to the path in `research.rubric` (default
`research/rubric.md`) and rewrite it for your question. The research run
copies every threshold word for word and never lowers one. A candidate
must pass every criterion to be the verdict; a criterion with no figure
read is `not read`, never a pass.

Write each criterion so a figure from a public page decides it: a number,
a date or a yes or no that a page states. Name the figures it needs, so
the framer can plan where to read them. Mark a criterion `knock-out` when
a candidate that fails it on the first read should be dropped before the
costlier reads.

## Candidates
Any open-source job queue for our stack that the question or the framer
names. The framer may add candidates, with the reason.

## Criteria

### 1. Maintained (knock-out)
- **Threshold:** at least 1 release in the last 6 months, and at least 2
  people with merged commits in the last 6 months.
- **Figures needed:** the date of the latest release; the number of
  distinct commit authors on the default branch in the last 6 months.
- **Sources:** the project's release page and commit history.

### 2. Adopted
- **Threshold:** at least 50,000 downloads in the last 30 days from the
  package registry, or at least 2,000 repository stars.
- **Figures needed:** 30-day downloads; star count.
- **Sources:** the package registry's public download statistics; the
  repository page.

### 3. Licence fits commercial use (knock-out)
- **Threshold:** an OSI-approved permissive licence (MIT, Apache-2.0,
  BSD-2-Clause or BSD-3-Clause), with no paid tier needed for retries,
  scheduled jobs or a dashboard.
- **Figures needed:** the licence named in the repository; the features
  of any paid tier as its pricing page lists them.
- **Sources:** the licence file; the pricing page, if one exists.

### 4. Responsive to bugs
- **Threshold:** the median time to first maintainer response on the 20
  newest issues labelled bug is 7 days or fewer.
- **Figures needed:** for each of the 20 newest bug issues, the opened
  date and the first maintainer comment date (listed, not judged, by the
  gatherer).
- **Sources:** the public issue tracker.

## Tie-break
When more than one candidate passes every criterion: the most downloads
in the last 30 days.

## Out of scope
- Benchmarks we would have to run ourselves.
- Anything behind a sign-in, a trial or a sales call.

---

An alternative question in the same shape, "is this market worth
entering?", might use: demand (a monthly search volume or a count of
public requests over a threshold), openness (no incumbent above a stated
share of reviews), willingness to pay (at least N paid products at or
above a stated price) and build size (the core feature buildable in a
stated number of weeks, judged from named public specs).
