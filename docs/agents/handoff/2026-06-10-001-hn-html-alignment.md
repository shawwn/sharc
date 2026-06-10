---
name: HN html alignment
description: Reworks news.arc's generated markup (listings, subtext, comments, polls, item page, top bar) to emit the same classes/ids that Hacker News's current news.css and vote/collapse JS expect, so our HTML matches HN's production stylesheet (static/news-hn.css). Markup-only, no behavior change. Lists the styled-vs-structural class taxonomy and the remaining reconciliation gaps.
type: project
---

# Handoff: HN html alignment (2026-06-10)

> Continues the HN-matching work from
> [`2026-06-09-002-profile-page-hn-match`](2026-06-09-002-profile-page-hn-match.md)
> and [`2026-06-09-004-vote-arrow-triangle-svg`](2026-06-09-004-vote-arrow-triangle-svg.md).

## Goal

`static/news-hn.css` and `static/news-hn.js` are HN's **current production**
CSS/JS (untracked, dropped in by the user). We want our generated HTML to
match what that CSS/JS expects, so we can eventually serve HN's stylesheet
directly. This pass did the HTML; the JS is deferred.

## Commits this session

| sha | what |
|---|---|
| `142ba08` | news.arc: lower poll-creation karma threshold to 1 |
| `f113702` | news.arc: record creator's vote when adding a poll option |
| `ae96d47` | srv.arc: serve js as text/javascript; add charset to css |
| `79c273e` | news.arc: align generated HTML with Hacker News's markup |

The alignment is `79c273e` (news.arc + html.arc).

## Class taxonomy (the key reconciliation insight)

Diffing our rendered HTML against live HN (`/news`, `/item?id=...`) and
grepping `news-hn.css` for actual selectors, HN's classes split in two:

- **Styled by news-hn.css (must match):** `.comment`, `.subtext`,
  `.votearrow`/`.rotate180`/`.votelinks`, `.title`, `.pagetop`,
  `.comhead`, `.default`, `.hnname`, `.topsel`, `.admin`, `.yclinks`,
  and the comment-fade colors `.c00 .c5a .c73 .c82 .c88 .c9c .cae .cbe
  .cce .cdd`.
- **Structural / JS hooks (HN emits but doesn't style):** `athing`,
  `submission`, `comtr`, `rank`, `titleline`, `sitebit`, `sitestr`,
  `subline`, `score`, `hnuser`, `ind`, `commtext`. Harmless to add; the
  vote/collapse JS keys off several of them.

We now emit both groups.

## What changed (`79c273e`), by function

- **listing rows** (`display-story`, `display-item-number`, `titleline`):
  `<tr class="athing submission" id>`, `<span class="rank">`,
  `<td valign=top class="votelinks">`, `<span class="titleline">`, site as
  `<span class="sitebit comhead">(<span class="sitestr">...)`.
- **subtext** (`display-story`, `itemscore`, `userlink`): wrap in
  `<span class="subline">`; score span gets `class="score"`; user link
  becomes `<a class="hnuser">`. Also simplified `user-name` to print
  directly instead of round-tripping through `tostring`.
- **comments** (`display-1comment`, `display-comment`,
  `gen-comment-body`): `<tr class="athing comtr" id>` (moved up to
  `display-1comment`), `<td class="ind" indent=N>`, votelinks class, body
  as `<div class="comment"><div class="commtext c00">`.
- **poll options** (`display-pollopt`): `<tr class="athing" id>`.
- **item page** (`display-item-page`): item wrapped in
  `<table class="fatitem">`, comment tree in
  `<table class="comment-tree">`, the content row gets `id="bigbox"`.
- **top bar** (`pagetop`, `gen-logo`): name in `<b class="hnname">`, logo
  img `display:block`.
- **html.arc**: registered an `indent` attribute for `td` (so
  `(tag (td indent N) ...)` emits `indent="N"`).

The `<a id="up_ID">` vote anchor and `onclick="return vote(this)"` are
unchanged, so the existing inline vote JS still works.

## Open follow-ups (when adopting news-hn.css / its JS)

- **Comment fade via cXX classes.** We still fade dead/old comments with
  inline `<font color>` and hardcode `c00`. Under HN's css,
  `.commtext.c00 { color }` would override the inline font and flatten the
  fade, so map `comment-color` to the right `cXX` class instead of `<font>`.
- **`.yclinks` footer**, and the **`unv_<id>` unvote placeholder span** in
  each comment's comhead (HN's JS injects the " | unvote" link there; note
  it's `id=`, not `class=`, since the JS uses getElementById).
- **Always emit the vote anchor `id`** (HN renders `id='up_ID'` even when
  logged out; we only emit it when logged in). Needed for the real JS.
- **sitestr `from?site=` link** (we have no `from` op).
- These pair naturally with wiring up HN's actual `vote()` / collapse
  (`togg`) JS, which is the deferred half of this effort.

## nginx note (advisory, not committed)

Discussed fronting sharc with nginx for static files: reproduce
`srv.arc`'s `static-filetype` + `type-header*` in an nginx `types {}`
block, add `charset utf-8` + `charset_types text/css text/javascript
text/plain text/html` (charset on text types only, matching sharc). Keep
nginx `root` pointed at `static/`, **not** the repo root: rooting higher
with `try_files $uri` would serve source (`*.arc`/`*.lisp`) and `.git/`.
Confining to `static/` is an allowlist by construction.

## Status

`./sharc test.arc` => **415 passed, 0 failed**. Rendered story/comment
markup verified against live HN. Reminder: `news.css` is browser-cached
1 day (`max-age* 'news.css = 86400`), hard-refresh after css edits.
`79c273e` not yet pushed; untracked `static/news-hn.css` / `.js` left
alone intentionally.
