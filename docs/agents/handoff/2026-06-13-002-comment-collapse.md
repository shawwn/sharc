---
name: comment collapse (togg)
description: Adds HN's comment collapse control (the [-]/togg link), with the subtree size computed in the same comment-navs pass. Also tidies the comhead markup (navs span, deadmark/onstory placement, reply div, always-render byline). The server-side `collapse` op that persists collapsed state is still a TODO.
type: project
---

# Handoff: comment collapse (2026-06-13)

> Continues [`2026-06-13-001-comment-nav-links`](2026-06-13-001-comment-nav-links.md).

## Commits

| sha | what |
|---|---|
| `574787a` | arc.arc: add an assert macro |
| `0536673` | wrap the "on:" marker in span.onstory |
| `eff9d24` | move the comment header links into span.navs |
| `4200357` | move deadmark before the comment nav links |
| `e4b40c8` | always render the byline in itemline |
| `4ce7c8b` | always print the bar before the parent link |
| `2b89dfa` | tidy gen-comment-body markup (reply div, commtext, br) |
| `4ed43ee` | add the collapse (togg) control |
| `7b29100` | give the top logout/login links ids |

## Collapse control (`4ed43ee`, `7b29100`)

`colllink` emits HN's collapse toggle in each comment's `navs` span:
`<a class="togg clicky" id="<id>" n="<subtree-size>" href="javascript:
void(0)">[-]</a>`. hn.js's global `.clicky` handler sees `.togg` and runs
`toggleCollapse(id)`, which walks sibling `comtr` rows by their `ind`
depth (`hidekids`/`showkids`) and rewrites the toggle to `[n more]`.

- `comment-navs` now also computes `n` (subtree size, **including self**,
  the user confirmed this is the intended value) in the same DFS pass:
  the recursion returns the visible-subtree count and each level sums its
  children, `n = 1 + descendants`. Stored alongside root/prev/next.
- `html.arc` registers the `n` attribute for `a` (opnum).
- the top login/logout links are wrapped in `<span id="login">` /
  `<span id="logout">` because hn.js checks `$('logout')` to tell whether
  the viewer is logged in (only then does it persist collapse via a
  `send('collapse?id=...')` ping).

### TODO: the `collapse` server op
hn.js does `send('collapse?id=' + id + (coll ? '' : '&un=true'))` to
persist a logged-in user's collapsed state, but **there is no `collapse`
op yet**. So collapse currently works client-side only and is forgotten
on refresh. Need a `(newsop collapse (id un) ...)` that records/removes
the comment id in a per-user "collapsed" set (e.g. `(uvar user collapsed)`
or an item key) and, on render, emits the comment already collapsed
(add the `coll` class + `nosee`/`noshow` like hn.js's `collstate`).

## comhead markup cleanup (the rest)
- everything in the comment header (root/parent/context/prev/next +
  edit/kill/blast/delete/flag/colllink/onstory) now lives in one
  `<span class="navs">`; `deadmark` sits just before it; the "on:" marker
  is in `<span class="onstory">`. Matches HN's comhead.
- `itemline` no longer gates on `cansee`, so the byline (user + age)
  shows on dead/flagged comments too (score still gated on cansee-score).
- `gen-comment-body`: visible text in `div.commtext`, pseudo-text bare;
  reply link in `<div class="reply">`.

## Still deferred
- the `collapse` op (above).
- **Hide story** (`/snip-story`, `/hide`) and `morelink` AJAX paging.

## Status
Working tree clean after this batch. `static/news-hn.js` stays untracked.
Several commits ahead of origin; run `./sharc test.arc` before pushing.
