---
name: comment nav links
description: Adds HN's comment nav controls (root/parent/context/prev/next) to each comment's comhead, with targets precomputed once per page (comment-navs -> id->{root prev next}) for O(1) render-time lookup. Also: vote op is now a redirector, pollopt votelinks class, byline split into agelink/unvotelink. Notes a macro-ordering gotcha.
type: project
---

# Handoff: comment nav links (2026-06-13)

> Continues [`2026-06-12-001-hnjs-voting`](2026-06-12-001-hnjs-voting.md).

## Commits

| sha | what |
|---|---|
| `5a561eb` | redirect after voting instead of rendering a blank page (newsopr) |
| `b3eb0f6` | add the votelinks class to the poll-option vote cell |
| `a9e63a4` | factor agelink and unvotelink out of byline |
| `0ce17dd` | add HN comment nav links (root/parent/context/prev/next) |

## Comment nav links (`0ce17dd`)

Each comment's comhead now has a `<span class="navs">` with HN's
`root | parent | context | prev | next`, clicky same-page anchors
(`whence#<id>`).

**Targets are precomputed once per page**, the important part for huge
threads:
- `comment-navs (tops)` does one DFS, sorting each parent's kids once
  (`ranked-kids`, memoized `frontpage-rank`), and fills a table
  `id -> (obj root .. prev .. next ..)`.
  - `prev` = parent (for a first child) or previous visible sibling.
  - `next` = next visible sibling, or the subtree's `next-after`, which
    is the parent's own `next` (so a last child's next is its uncle).
  - `root` carries down; a top-level comment is its own root.
- stashed in the `(the comment-nav)` thread-local for the tree render;
  `cnav`/`root-comment`/`prev-comment`/`next-comment` are O(1) lookups
  (`cnav` returns nil if the table isn't set, so it degrades safely).
- **Both render paths must feed `comment-navs` the same order they
  render**, this bit us: `item-page` uses `(comment-navs:ranked-kids i)`
  (matching `display-subcomments`'s `ranked-kids`), `/threads` uses
  `(comment-navs cs)` (cut order). An earlier version passed raw `kids`
  (unsorted) while rendering ranked -> wrong top-level prev/next.
- redundant-link suppression lives in the link funcs:
  `rootlink` hides root when it equals self or parent; `prevlink` hides
  prev when it equals the parent. The precompute just returns the raw
  targets.

`ranked-siblings`/`ranked-kids` centralize the sort; `user-comments` was
factored out of `threads-page`; `flaglink` now also shows for logged-in
users on `/newcomments` (intentional).

### Gotcha worth remembering
A `(mac assert ...)` defined *after* `cansee` (which used `(assert i)`)
caused a runtime "Function call on non-function: MAC", `cansee` compiled
`assert` as a function call before the macro existed, then hit the macro
object at runtime. **Macros must be defined before any function that
uses them.** The `assert` macro now lives at the top of news.arc (before
`cansee`); it's still unstaged.

## Other (`5a561eb`, `b3eb0f6`, `a9e63a4`)
- vote op is a redirector (`newsopr` = `opexpand defopr`): a non-JS vote
  returns `goto` (bounce back) instead of a blank page; errors return a
  flink to a message page. The hn.js XHR path discards the response.
- pollopt vote cell got `class="votelinks"`.
- `byline` split into `agelink` + `unvotelink` (reused by pollopts).

## Still deferred
- **Collapse** (`togg`): emit `<a class="togg clicky" id n>[-]</a>` in the
  comhead + a `collapse` op. hn.js's `hidekids`/`showkids` walk sibling
  `comtr` rows by `ind` (our tree is already flat siblings).
- **Hide** (`/snip-story`, `/hide`) and the `morelink` paging.

## Status
`./sharc test.arc` => 415/0 last run. Working tree: the `assert` macro
(top of news.arc) and an arc1.lisp debug-toggle revert are unstaged,
commit assert separately and confirm the arc1.lisp `ac-safe-call` line is
re-commented before pushing. `static/news-hn.js` stays untracked.
