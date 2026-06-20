# snip-story: JS hide-and-refill on listing pages

Date: 2026-06-20

Follow-on to [2026-06-20-001-hide-auth-and-redirect-hardening.md], which
added the per-user hide feature, HMAC auth tokens, and `safe-goto`.

## What was accomplished

Clicking "hide" on `/newest` or `/news` (front page) now removes the row
and pulls in the next story without a full reload, matching HN. All
server-side; **`hn.js` was deliberately not changed** (it already
supported this contract).

### How the client/server contract works (hn.js, unchanged)

- `hidelink` renders the hide link with `class="clicky hider"` on listing
  pages, so `hn.js`'s `onclick` intercepts it.
- `hidestory` (hn.js): removes the hidden story's 3 rows (athing +
  subtext + spacer), then rewrites the link `hide`->`snip-story`,
  `goto`->`onop`, and for `/newest` appends `&next=<morelink cursor>`
  (the front page sends no cursor). Fetches and passes the JSON to
  `newstory`.
- `newstory` (hn.js): inserts `pair[0]` (rendered story HTML) after the
  last `.spacer`, clones that spacer, re-numbers ranks, and for newest
  updates the morelink href to `newest?next=<pair[1]>&n=...`.
- So the server `snip-story` must return a JSON 2-array `[html, next]`:
  `html` = the rendered replacement story, `next` = new newest cursor id
  (or anything/`nil` for the front page, which `newstory` ignores).

### Server pieces (this session's commits)

- **`snip-story` op + `snip-pair`** (`232e5d2`, news.arc): hides the item
  (auth-checked with `good-auth`, like the `hide` op), then returns
  `(to-json (snip-pair onop next))`.
  - newest: matched by **base op** (`(car (tokens onop #\?))`), because
    on a paginated page `onop` is the full whence (`newest?next=12&n=3`).
    Renders the first visible story at/after the `next` id cursor and
    returns the id after that. Cursor logic mirrors `paginate`
    (`keep [<= _!id n] (newstories maxend*)`), works on any page.
  - front page: exact match on `"news"`/`""` (page 1 only). Refills with
    `((topstories maxend*) (- perpage* 1))` (the story that drops to the
    bottom after one is hidden). Deeper pages (`news?p=2`) match nothing
    and safely no-op (returns `null`), since the front page is
    page-based and can't be refilled without page info.
  - `snip-pair` wraps the render in `(w/the op <base>)` so the re-rendered
    story's `hidelink` sees the listing op and stays clicky.
- **`hidelink`** (news.arc): clicky link when `(in (the op) "" "news"
  "newest")`, plain `link` otherwise (so hide still works via full
  navigation on item pages, /best, /ask, etc.).
- **`clickylink`** (news.arc): gained optional `class` and `aria-hidden`
  args (backward-compatible). The hide link passes `aria-hidden nil`
  ("hide" is meaningful text, not decorative).
- **`spacerow`** (`01e686b` then refined, html.arc): now `(def spacerow
  (h (o class)) (tag (tr class class style "height:@{h}px")))`. The class
  is opt-in.
- **`display-items`** (news.arc): per-item gap rows get `class="spacer"`;
  the pre-More gap gets `class="morespace"`. This is the fix for the
  spacer bug (see below).
- **`op` attribute plumbing** (`cfd505b`): `respond` binds `(the op)
  (string op)`; `npage` emits `op="..."` on `<html>`; `html.arc`
  registers `op` as an html attribute. `hn.js`'s `onop()` reads it.
- **More link** (`54e0846`): tagged `class="morelink"` (hn.js finds it
  via `allof('morelink')`), `rel=next` instead of `nofollow`.
- **`json.arc` via `libs.arc`** (`e4fa25c`): `to-json` is now a standard
  lib (was only loaded ad-hoc by scrape.arc/test.arc).
- **vote auth -> HMAC** (`f07764c`): `vote-url`/`vote` now use
  `auth-for`/`good-auth` (per-item HMAC) instead of the raw cookie,
  closing the cookie-in-URL leak. Transparent to hn.js.

## Bugs found and fixed during review

1. **sha1 64-byte key** (`20c6489`, prior handoff): HMAC errored on a
   key exactly the block size; `auth-key` generates `rand-string 64`.
2. **10px spacer cloning**: the first spacer commit classed *every*
   spacer, so `hn.js` cloned the last `.spacer` = the 10px pre-More row,
   inserting a spurious 10px gap per hide. Fixed by classing only
   per-item gaps (`"spacer"`) and giving the pre-More gap a distinct
   `"morespace"`.
3. **symbol/string `(the op)` mismatch**: `snip-pair` first set
   `(w/the op (sym ...))` but `respond`/`hidelink` use strings; `(is
   'news "news")` is nil, so re-rendered hide links came out non-clicky.
   Fixed by keeping `(the op)` a string.
4. **paginated `onop` -> null**: on a paginated page the hide link's
   `goto`/`onop` is the full whence (`newest?next=12&n=3`), so `(is onop
   "newest")` failed and `snip-pair` returned `null`. Fixed by matching
   newest on its base op.

## Key decisions

- **Don't touch `hn.js`.** It already encodes the right contract
  (newest sends a cursor + updates morelink; other pages just append).
  The server figures out the front-page refill itself.
- **Front page is page-1 only.** Ranked + page-based pagination can't be
  refilled correctly on deeper pages without page info the client
  doesn't send; deeper pages no-op rather than insert a wrong story.
- **snip-story responds as text/html** (plain `newsop` body printing
  `to-json`); `fetch().json()` parses it regardless of content-type.

## Important context for future sessions

- **Testing idiom**: load + simulate a request. The render path needs
  `(load-userinfo)` and `(load-items)` after `(load "news.arc")`, plus a
  bound request: `(w/the req (inst 'request ...) (w/the ip ...) (w/the me
  "u" ...))`. A hand-made profile also needs `(= (votes* u) (table))` or
  `votelink` calls nil. Gotcha: `((newstories maxend*) 2)!id` is invalid
  syntax (`!` after a close paren) — now noted in CLAUDE.md.
- **Restart the server to pick up `sha1.lisp` / any `.arc` changes**;
  `boot.lisp` loads from source each start, but a running instance holds
  old code.
- `arc/news/hmac-key` is a gitignored server secret (per prior handoff).
- Branch `main`, clean after this handoff commit. All work above is
  committed (range `f07764c`..`34d3976`).
