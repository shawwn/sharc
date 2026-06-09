---
name: vote arrow triangle.svg
description: Replaces the two vote-arrow gifs (grayarrow.gif/graydown.gif) with Hacker News's single triangle.svg rendered as a CSS-background div (the downvote is the up-triangle rotated 180). Also fixes static-file mime types (css/js/svg were mislabeled or mismatched) and a pre-existing vote() JS crash on items with no shown score.
type: project
---

# Handoff: vote arrow triangle.svg (2026-06-09)

> Continues the HN-matching work from
> [`2026-06-09-002-profile-page-hn-match`](2026-06-09-002-profile-page-hn-match.md).

## Commit

| sha | what |
|---|---|
| `ff461e4` | news.arc: replace vote-arrow gifs with HN's triangle.svg |

## The arrow swap

Modern HN ships **one** `triangle.svg` (an up-pointing gray `#999`
triangle) and renders each vote arrow as a CSS-background `<div>`, not an
`<img>`. The downvote arrow is the *same* div with an extra `rotate180`
class; CSS just rotates the up-triangle 180. So one asset replaces both
`grayarrow.gif` and `graydown.gif`.

- `static/triangle.svg` added (HN's exact svg). `grayarrow.gif` /
  `graydown.gif` deleted.
- `votelink` (news.arc) now emits, inside the vote `<a>`:
  - up:   `<div class="votearrow" title="upvote"></div>`
  - down: `<div class="votearrow rotate180" title="downvote"></div>`

  (kept the `out` constant-fold; the div markup is fully static now.)
- news.css gained `.votearrow` (10x10, `background: url(triangle.svg)`,
  `background-size:10px`) and `.rotate180 { transform: rotate(180deg) }`,
  copied from HN.
- dropped the now-unused `up-url*` / `down-url*` (kept `logo-url*`).

The `<a id="up_ID"/down_ID" onclick="return vote(this)">` wrapper is
unchanged, so the existing vote JS still keys off it.

## Static mime types (srv.arc)

Serving the svg surfaced that `static-filetype` -> `type-header*` was
loose. Cleaned it up:

- `type-header*` now has real types: `css` text/css, `js`
  application/javascript, `svg` image/svg+xml, `txt`/`arc` text/plain.
  Previously css/txt/arc were mislabeled `text/html`.
- **Key-match bug fixed:** `static-filetype` returned the symbol
  `'text/css` for `.css`, but the `type-header*` table is keyed by `'css`.
  The mismatch made the header lookup `nil`, and the serving code did
  `(prn (type-header* filetype))`, so `(prn nil)` wrote a blank line where
  the `HTTP/1.0 200 OK` status line belongs -> a malformed response
  ("invalid response" in Chrome) for `/news-hn.css`. `.js` worked because
  `static-filetype` returned `'js`, matching its key. Now `.css` -> `'css`.
- The serving code guards the lookup: `(prn (or (type-header* filetype)
  (err "Unknown mime type for @filetype")))`, so a future filetype with no
  header mapping fails loudly (visible server error + backtrace) instead of
  silently emitting a blank status line. (All current filetypes map, so it
  only fires on a real misconfig.)

## vote() JS null-guard (news.arc, votejs*)

Pre-existing bug, surfaced once the arrows were clickable: the inline
`vote(node)` did `parseInt(byId('score_'+item).innerHTML)`, but comments
show no `score_<id>` element to non-author/non-admin viewers. So `score`
was `null`, `score.innerHTML` threw, the `onclick="return vote(this)"`
handler errored instead of returning `false`, and the browser followed the
`href` to `/vote?...`. The vote op records the vote but returns an empty
body, hence a blank page. Now the score update and the `up_`/`down_` arrow
lookups are null-guarded, so it pings and returns false as intended.

(The vote op's empty no-JS response is left as-is; with the JS fixed,
normal clicking never navigates there. Making `vote` redirect to `whence`
for the JS-disabled fallback is a possible separate change.)

## Gotchas worth remembering

- **news.css is cached 1 day** (`max-age* 'news.css = 86400`). After any
  css change you must hard-refresh (Cmd+Shift+R) or you'll see stale rules
  (this is what made the arrows look "missing" at first while every other
  style worked). Inline page JS/markup is not cached, so a normal reload
  after a server restart suffices for those.
- Verified: `votelink` renders the HN-identical markup, `triangle.svg`
  serves `200` / `image/svg+xml`, and every `static-filetype` result maps
  to a header.

## Status

`./sharc test.arc` => **415 passed, 0 failed**. `ff461e4` is local,
ahead of `origin/main`, not yet pushed. Two untracked static assets
(`news-hn.css`, `news-hn.js`) are unrelated WIP and intentionally left
alone.
