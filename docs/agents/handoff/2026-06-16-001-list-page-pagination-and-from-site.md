---
name: list-page pagination and from-site listings
description: Real URL-based pagination for the news list pages (?p=N page-numbers and ?next=ID[&n=N] id-cursors) via a whenceurl/pageurl/nexturl layer + paginate, a new from?site= submissions-by-site page backed by a sitename->stories* disktable, a spam-sites admin page, and a srv-level guard against empty/relative redirect Locations.
type: project
---

# Handoff: list-page pagination + from-site listings (2026-06-16)

> Continues the HN-clone work; previous handoff
> [`2026-06-13-003-comhead-tweaks`](2026-06-13-003-comhead-tweaks.md).

## Commits (oldest first)

| sha | what |
|---|---|
| `7ec7787` | news.arc: use index syntax (`parts!1`) for sitename host/path parts |
| `2fca7b2` | arc.arc: `saferead` only reads string args |
| `d4aa07d` | arc.arc: `cache` keys on args (table) instead of a single stored value |
| `4a4da01` | arc.arc: tidy `empty`; `assert` prints the failing expr via `tostring:pr` |
| `e83d355` | srv.arc: never emit an empty or relative redirect `Location` |
| `333875e` | news.arc: housekeeping (safe-* coercers, newsop arg->body, drop dead `votejs*`) |
| `7a42289` | news.arc: add spam-sites admin page (manage `big-spamsites*`) |
| `800a162` | news.arc: paginate list pages via `?p` / `?next` URLs + from-site listings |
| `8b85b8f` | news.arc: format the spam-sites prose with `para` |
| `b0b2d5f` | news.arc: only show `[dead]` marker to users who see dead items |
| `f98e840` | news.arc: use `ulink` for the manage-spam-sites link |
| `b969679` | news.arc: cosmetic listpage url-arg wrapping; `with` in upvoted-page |

The `800a162` commit is the core feature; the rest are supporting refactors,
follow-on tweaks, or cosmetics. The big change was split into independently
loadable commits on purpose (housekeeping -> spam-admin -> pagination+from);
each was load-tested in isolation. `from` rides in the pagination commit
because its op shares a diff hunk with the `bestcpage` change.

## What changed

### `cache` now keys on args (`d4aa07d`)
`(cache timef valf)` returns `(fn args ...)` and stores per-args results in a
table, each entry expiring after `(timef)`. This is the enabler for the next
item.

### `newscache` takes args
`(newscache name args time . body)` — the cached page fn can now take params
(e.g. `whence`), keyed through the per-args `cache`. Caching is **disabled**
whenever `arg!perf`/`arg!p`/`arg!n`/`arg!next` is present (those pages depend
on request args not captured in the cache key). Every `newscache` call site
gained an args list, usually `()`.

### URL builder layer (in news.arc, near `listpage`)
- `whenceurl (whence (o next) (o n) (o p))` — the primitive. Picks `?`/`&`
  separator by whether `whence` already contains `?`. Emits `p=`, or
  `next=`(+optional `n=`), or bare whence.
- `pageurl (whence (o p (curpage)) (o n (cur-n)))` — page-number URLs (`?p=N`).
- `nexturl (whence (o next arg!next) (o n (cur-n)))` — id-cursor URLs
  (`?next=ID[&n=N]`).
- `fromurl (site (o next))` — the `from?site=...&kind=story[&next=ID]` URL.
- `curpage`/`cur-n` — read `arg!p`/`arg!n` (default 1).

### `paginate` + `display-items`/`morelink`
- `(paginate items perpage)` returns `(start end numstart items)`. `?p=N` =
  index window with `numstart=start+1`; `?next=ID` = keep `[<= _!id it]` (lists
  run newest-id-first), `start 0`, `numstart=(cur-n)`; else whole list.
- `listpage` gained an `(o moreurl)`; it calls `paginate` then `display-items`.
- `display-items` gained `(o moreurl)` and `(o numstart (+ start 1))`. Numbers
  count from `numstart`; the "More" cutoff is now `(<= (+ numstart (- end
  start)) maxend*)` (rank-based, not index-based, so cursor pages stop
  correctly).
- `morelink (f items label title start end number moreurl . args)`: if
  `moreurl`, the "More" link is `(moreurl ((items start) 'id))` (a plain URL);
  otherwise it falls back to the old afnid continuation. **Index note:** the
  cursor id comes from `items` at `start` (the boundary), because
  display-items passes its local `end` into morelink's `start` slot.

### Per-page wiring
- `?p=` (page numbers): news/`||`, best, bestcomments, active, newcomments.
  Root `||` uses `whence=""` so its paginated URLs are HN-style `?p=2` (not
  `/?p=2`).
- `?next=` (id cursor): noobs, from, threads, upvoted.
- `/newest` deliberately uses `?p=`, **not** the HN `newest?next=ID&n=N` form.
  Conscious choice (page-numbers for ranked/linear lists). Revisit if HN parity
  for /newest matters — switch it to `nexturl`.

### `from?site=` submissions-by-site (`800a162`)
- New `from` op: lists a site's story submissions, cursor-paginated.
- `disktable sitename->stories*` (`newsdir*/sitename-stories`) maps a sitename
  to a list of story ids (newest first). `register-sitename` pushes the id and
  `todisk`s on every URL submission (in the story-insert path).
- `stories-from` = `(visible (keep idfn (map item (sitename->stories* site))))`
  — the `keep idfn` guard matters: a stored id may no longer resolve and
  `cansee`/`visible` don't reject nil.
- `fromlink` adds a "from" link in each story's itemline subtext.
- **Backfill gap:** `sitename->stories*` only gets populated for submissions
  made after this change; existing stories aren't indexed. A one-time backfill
  over `stories*` would be needed if you want old stories to show up under
  `from`.

### Spam-sites admin (`7a42289`, `8b85b8f`, `f98e840`)
- `spamsites-page` (linked from newsadmin via `ulink`): add/remove entries in
  the `big-spamsites*` table (`todisk` on change).
- newsadmin's kill-all-by / ban-ip forms converted to `urform` redirectors.
- Submit-time spam check simplified to `(big-spamsites*:sitename url)`;
  `recent-spam` dropped (left as a `; could also match` TODO comment).

### Redirect Location guard (`e83d355`)
In `respond` (srv.arc), a redirector's `Location` is now coalesced: if the
returned location is empty or starts with `?` (e.g. blank `whence`, or
`?p=2`), prefix `/`. Fixes the post-login / logout-from-homepage white page at
`/y` (an empty `Location` made the browser reload `/y` itself). See the two
screenshots that prompted it: blank whence -> empty Location -> blank `/y`.

### Other
- `safe-id`/`safe-int`/`safe-whole`/`safe-posint` = `ok-*:saferead`; the `ok-*`
  predicates now **return the value** (truthy) instead of just `t`.
- `deadmark`: `[dead]` is now gated on `(seesdead)` (matches `[deleted]` being
  admin-gated). (Note: this re-adds a gate that `6258c12` had removed for the
  comment-header markers; `deadmark` here is the story/item marker.)

## Important context / gotchas
- **`?next=` assumes descending-id order.** True for stories*/comments*/
  sitename->stories*/noobs source. `upvoted` sorts by `item-age`, which only
  approximates id order — harmless in practice but slightly fragile.
- **Test constants were restored** to production values: `perpage* 30`,
  `threads-perpage* 10`. If you drop them low again to test paging, restore
  before committing.
- Arc gotchas in play (see CLAUDE.md): `[<= _!id it]` is fine (multi-element
  bracket); a lone `[_!x]` would mis-call. Atstrings are on, so `title`s like
  `"@{user}'s upvoted @(if comments 'comments 'submissions)"` interpolate.

## Status
Working tree clean; all of the above committed. Several commits ahead of
origin. Run `./sharc` then `(load "news.arc")` (or `./sharc test.arc`) before
pushing — every commit in this series was verified to load. `static/*.js`
stays untracked as before.

## Possible follow-ups
- Decide /newest: keep `?p=` or switch to `?next=&n=` for HN parity.
- Backfill `sitename->stories*` from existing `stories*` if `from` should cover
  old submissions.
- Still deferred from prior handoffs: the `collapse` server op (client-side
  only today), hide-story, and AJAX `morelink` paging.
