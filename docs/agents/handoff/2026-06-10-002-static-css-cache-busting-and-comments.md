---
name: static css cache-busting and comment polish
description: Moves news.css to a static file served with content-hash cache-busting (news.css?<sha1>, memoized on modtime), adopts HN's full stylesheet, switches comment fade to the cXX css classes, and adds in-tree parent links with same-page anchor navigation. Adds a modtime primitive and an opbool html attribute handler.
type: project
---

# Handoff: static css cache-busting + comment polish (2026-06-10)

> Continues [`2026-06-10-001-hn-html-alignment`](2026-06-10-001-hn-html-alignment.md).
> Several follow-ups it listed (cXX comment fade, the news.css cache
> gotcha) are resolved here.

## Commits this session

| sha | what |
|---|---|
| `4e75f89` | arc0.lisp: add modtime, a file's mtime in Unix seconds |
| `1f60485` | serve news.css as a content-hashed static file |
| `f3885b7` | news.arc: show the parent link on nested comments in the tree |
| `f1ac4d9` | news.arc: anchor the parent link and post-reply redirect to the comment |
| `eaf0530` | news.arc: style the in-page parent link like HN's nav controls |

All unpushed at time of writing.

## news.css is now a static file with content-hash cache-busting (`1f60485`)

The big one. The inline `(defop news.css ...)` is gone; the stylesheet
lives in `static/news.css` (HN's full sheet: cXX colors, responsive media
queries) and is linked **cache-busted**:

- `gen-css-url` emits `<link ... href="/news.css?<sha1-of-contents>">`.
- `static-src` (srv.arc) builds `"/file?<hash>"`. `shashfile` SHA1s the
  file's bytes, **memoized on `modtime`** so it only re-reads when the
  file changes. `shash` (sha1 hex) moved from app.arc to srv.arc.
- `static-max-age* = 86400`. The hash makes a long cache safe for css:
  edit the file -> new hash -> new URL -> instant refetch. This kills the
  old "hard-refresh after css edits" problem for good.
- `modtime` (`4e75f89`, arc0.lisp) returns a file's mtime as Unix seconds
  (same base as `seconds`/`i!time`), nil if missing. Used by `shashfile`.
- supporting: `allbytes`/`filebytes` (arc.arc) read raw bytes; `link`
  rel/type/href attributes (html.arc).

Why 1-day and not a year: `static-max-age*` is global but only css goes
through `static-src`. Hashed refs (css) bust instantly; un-hashed refs
(triangle.svg, images) get a safe 1-day staleness window. Route more
assets through `static-src` to push it longer.

## Comment fade via cXX classes (`1f60485`)

Replaced inline `<font color>` comment fading with HN's `cXX` css classes.

```arc
(def comment-class (c)
  (if (is arg!id (string c!id))            ; permalinked comment -> full black
       "c00"
      (and (~live c) (~author c))          ; dead -> lightest
       "cdd"
      (withs (g ((comment-color c) 'r)     ; else derive c<hex> from the gray
              x (coerce g 'string 16))
        (string "c" (if (len< x 2) "0") x))))
```

Key trick: `grayrange` is tuned (and **capped at 221**, was 230) so its
rounded gray values land exactly on the cXX hex palette
(90->c5a, 115->c73, ... 221->cdd), so `c<hex>` always names a class that
exists in the css. Verified every score maps to a present class. Dead
poll options switched from `spanclass dead` to `cdd` (no `.dead` rule
needed). The `arg!id` clause is cache-safe: the focused comment renders
`astree=nil` (uncached); only non-focus subtree comments are cached.

## Parent link + anchor navigation (`f3885b7`, `f1ac4d9`, `eaf0530`)

- **Show parent in the tree:** `display-subcomments` passes
  `initialpar=(> indent 0)`, so nested replies get a "parent" link while
  top-level comments (parent = the story above) don't.
- **Same-page anchors:** `item-url` gained an optional anchor arg
  (`item?id=<id>#<anchor>`, or `#<anchor>` when id is nil). Comment rows
  already carry `id="<commentid>"`. The in-tree "parent" link now jumps to
  the parent's row on the current page (`item?id=<page>#<parent>`); only
  on a comment's own permalink (`arg!id == c!id`) does it go to the
  parent's page. Post-reply redirect anchors to the parent comment
  (`whence#<parent>`) so you land on the context you replied under.
- **HN nav styling:** the same-page parent link renders as
  `<a class="clicky" aria-hidden="true">`. Needed a new `opbool` html
  attribute handler + registering `aria-hidden` (html.arc).

## Open follow-ups

- **HN's vote()/collapse JS** is still the deferred half (the `togg`
  collapse control, `unv_<id>` unvote span, always-emit the vote `id`,
  prev/next/root navs). `static/news-hn.js` is HN's current JS, sitting
  untracked as reference.
- `static/news-hn.css` / `news-hn.js` remain intentionally untracked.
- The `.subline`/`.sitebit`/etc. structural hooks from the alignment pass
  exist in our HTML but aren't styled by news.css (HN doesn't style them
  either) -- fine.

## Status

`./sharc test.arc` => **415 passed, 0 failed**. 5 commits ahead of
`origin/main`, unpushed. Rendered comment markup (cXX fade, clicky parent
link) verified against a fresh load.
