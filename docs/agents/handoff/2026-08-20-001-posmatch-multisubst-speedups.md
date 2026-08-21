---
name: posmatch and multisubst native fast paths
description: Diagnosed the `(subseq nil 0 -1)` crash in `split-host` (host "..." from a literal placeholder URL in an HN comment), profiled `(load "script.arc")` and cut HN item parsing from 797ms to 51ms by putting native `search` / `position` fast paths in front of `posmatch` and `multisubst`, plus a verification of the reworked `parse-comments` and the one page shape where its `cdr` is wrong.
type: project
---

# Handoff: posmatch and multisubst speedups (2026-08-20)

Three pieces of work, in order: a crash diagnosis in `sitename.arc`, a profile
of the scraper's item parsing that produced commit `8896c09`, and a correctness
review of `parse-comments` after the user reworked it mid-session.

## 1. The `split-host` crash

A `scrape-remaining-stories` bgthread died with

```
The value -1 is not of type (OR NULL (UNSIGNED-BYTE 45)) when binding SB-IMPL::END
0: (subseq nil 0 -1)
1: (arc::SPLIT-HOST)
```

**Input:** the URL `https://.../invoice.pdf"`. The `...` is literal. It came
from a fenced code block in HN comment 49329575, where the author wrote
`"document_url": {"url": "https://.../invoice.pdf"}` as a placeholder, and the
comment's URL extractor pulled it out including the trailing `"`. `parse-url`
gives `netloc = "..."`, so:

1. `(tokens "..." #\.)` is `nil`, since the host is nothing but separators.
2. `sitename.arc:39` tested `(in (last toks) "www" nil)`. `(last nil)` is `nil`,
   and `nil` is itself a member of that `in` list, so the test was **true**.
3. `(zap almost nil)` is `(cut nil 0 (edge nil))` = `(cut nil 0 -1)` =
   `(subseq nil 0 -1)`.

Any host that tokenizes to nothing triggers it: `https://.../x`, `https://./x`,
`https://...../x`. `http://www./x` was always fine, because there `toks` is
`("www")` and `almost` returns `nil` cleanly. The empty-`toks` guard on the line
below (`(when (and toks (len< toks 2))`) already anticipated degenerate hosts;
the `www` check above it just did not have the same guard.

Fixed in `044deaa` by the user, as `(when (and toks (in (last toks) "www" nil))`.

## 2. The profile, and commit `8896c09`

`(load "script.arc")` (the user's scratch driver, see *Untracked files* below)
took ~800ms to parse one 548kb cached HN item page. Breakdown before the fix:

| step | time |
|---|---|
| `filechars "foo.html"` | 13 ms |
| `parse-fatitem` | 2 ms |
| `parse-split` | 85 ms |
| `parse-comments` (includes `parse-split`) | 701 ms |

`(profiling (repeat 5 (load "script.arc")))` from `profiling.arc` put 57%
cumulative under `posmatch` / `headmatch` and 36% under `multisubst`, with the
flat profile topped by `arc-+`, `headmatch`, `arc-call1` and
`listify_rest_arg`. No parsing logic appears anywhere in the report; it is all
character-at-a-time interpreted string plumbing.

- **`posmatch`** scans every index in Arc and calls `headmatch` there, and
  `headmatch` is a recursive `afn` that recomputes `(len pat)` / `(len seq)`
  and goes through generic ref, `is` and `+` per character. Every `between`
  pays for two such scans and `parse-comment-row` does about ten per comment,
  over 355 comments.
- **`multisubst`** runs `(find [begins seq (car _) i] pairs)` for *every*
  character: a closure allocation, a `reclist` walk of the pairs and a
  `headmatch` per pair. `uneschtml` therefore did eight pattern matches per
  character of every comment body (96kb of text here) and printed one character
  at a time.

The commit keeps both pure versions as **`posmatch1`** and **`multisubst1`**
(the `cut1` / `cut2` convention from `arc.arc:659`) and puts a native fast path
in front:

- `posmatch` uses CL `search` when pat and seq are both strings and `start` is
  in range. `is` on characters is `eql`, so they agree. Fn patterns
  (`app.arc:879` passes one) and conses still take `posmatch1`.
- `multisubst` detects the case where every pattern is a non-empty string
  sharing one leading character, which is exactly `uneschtml`'s entities (all
  `&`) and `shellquote`'s single `'` pair. Only those positions can begin a
  match, so native `position` skips everything between them, and each unmatched
  run is copied with one `cut` instead of per-character `pr`. Mixed leading
  characters, empty patterns and non-string sequences fall back to
  `multisubst1`.

Result: `(load "script.arc")` **797ms to 51ms** (15.6x). Isolated,
`parse-split` went 85ms to 4.9ms and entity-decoding all 354 comment bodies
went 827ms to 16ms across three passes (52x). Both functions are used
throughout `srv.arc` and `news.arc`, so this is not scraper-only.

### How it was verified

The A/B method mattered more than the profile did, because the profile only
named the functions; it did not prove the rewrites were equivalent.

- Differential runs against the retained pure versions: 184 `posmatch` cases
  (pattern x sequence x start, including empty patterns, starts past the end,
  overlapping candidates, fn patterns, cons sequences) and 65 `multisubst`
  cases. Zero mismatches.
- `uneschtml` over all 354 real comment bodies in `foo.html`: identical.
- `shellquote` (`app.arc:325`, the other `multisubst` caller) over quote-heavy
  inputs: identical.
- Full parse dumped field by field, story plus 355 rows, before and after the
  change: 378 lines identical except the `seen` wall-clock timestamp.
- `./sharc test.arc`: **927 passed, 0 failed**, up from 909; 18 assertions were
  added to the existing `posmatch` and `multisubst` tests in `test.arc` locking
  in fast-path/pure-path agreement. The pre-change tree was confirmed at
  909/0 first, so the delta is only the new tests.

## 3. `parse-comments` after the rework

While the profiling was underway the user replaced `parse-comments`'s bespoke
scan with `(each row (cdr (parse-split html)) ...)` (`f0018e0`, originally
committed as `716dca4` and later amended). `parse-split`'s default anchor is
`"<tr class=\"athing "` with a trailing space, which matches the story
submission row as well as comment rows, hence the `cdr`.

Verified correct on `foo.html`: 354 comments parsed, equal to the 354
`<tr class="athing comtr` rows in the page and to HN's own subtext count; ids in
exact document order with no duplicates; every comment has `id`, `by`, `text`
and `time`; every `parent` resolves to the story or an earlier comment; 56
top-level; 3 flagged, 10 dead, 1 collapsed; and the story row no longer appears
as a phantom textless self-parented comment (it did before the rework, which is
how the discrepancy was noticed).

**Open, deliberately not changed:** `cdr` drops the first chunk *positionally*,
and "first chunk is the story" only holds for story pages. On a comment
permalink (`/item?id=<comment-id>`) HN renders the comment itself as the
fatitem `<tr class="athing comtr">`, so `cdr` eats a real comment. Demonstrated
with a synthetic page (permalinked comment plus two replies): 2 parsed instead
of 3, `alice` dropped. **Not reachable today** because every id reaching
`scrape-item!` comes from `scrape-topstories!` or `parse-listpage`, always
submissions, and `scrape-verify-flags.arc` passes context story ids. The
robust one-liner, measured as identical on all 354 comments field by field and
the same speed (187ms vs 197ms for five passes), is to pass the anchor that
`parse-split` already accepts:

```arc
(each row (parse-split html "<tr class=\"athing comtr")
```

The user was asked and has not taken it up, so it remains open.

## Current state

`main`, **8 commits ahead of `origin/main`, unpushed**. Three of those are from
this session: `044deaa`, `f0018e0`, `8896c09`. Working tree is clean apart from
two untracked files.

`./sharc test.arc` reports **927 passed, 0 failed**.

### Untracked files (the user's, left in place)

- `foo.html`: 548kb cached HN page for item 49378957 ("The August 17 outage,
  and the work ahead", 354 comments, 3 flagged / 10 dead / 1 collapsed). This
  is the fixture every measurement above used. Do not delete it without asking;
  re-fetching costs a live HN request and the flag counts would drift.
- `script.arc`: three-line driver that reads `foo.html` and stuffs
  `(parse-fatitem)` / `(parse-comments)` results into the global `zz`. The
  `fetch-hn-item` call that would refresh `foo.html` is commented out in it.

## Notes for a future agent

- **Profiling recipe.** `(load "profiling.arc")` then
  `(profiling (repeat 5 <expr>))`. It reports `:graph` to stderr. The graph is
  awkward to read (callers above the entry line, callees below); the flat
  section at the bottom is where to start. `profiling.arc` carries a Darwin
  caveat about per-thread sample attribution being unreliable for `:cpu` mode,
  with `:mode :time` suggested as the workaround; it did not bite here because
  everything ran on one thread.
- **Trust the A/B swap over the profile.** Every conclusion above was confirmed
  by redefining one function at a time (`(= uneschtml idfn)`, a native
  `posmatch`) and re-timing, which also gives the achievable speedup before any
  code is written. `posmatch` fixed alone: 701ms to 311ms. `uneschtml` alone:
  701ms to 447ms. Both: 30ms.
- **Run scratch scripts as `./sharc /abs/path/to/scratch.arc`.** The arc loader
  resolves relative paths against `arc-dir`, not the cwd, so a `w/outfile` with
  a bare name lands in the repo root.
- **Nested `aif` shadows `it`.** `(aif (between ...) (aif (posmatch ...) (car it)))`
  silently reads the *inner* `it` (a position) as if it were the outer match.
  This cost a debugging round when a probe collected zero comment bodies
  instead of 354. Use `whenlet` with distinct names in nested matches.
- `(single x)`, `(dedup xs)` and `(empty x)` all exist and are used by the new
  `multisubst` guard; `dedup` is `arc.arc:1745`, `single` is `arc.arc:1753`.
- **Still non-native, if more speed is ever needed:** `headmatch`, `begins`,
  `subst` and `findsubseq` are all still the pure per-character versions.
  `headmatch` is the one that matters, since `begins` and `subst` go through
  it, and it is what the surviving `posmatch1` path costs.
