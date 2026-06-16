---
name: from-site links, lists rework, favicon
description: Follow-ons to the pagination work - story domains in the comhead now link to their from?site= page (admins keep the ban-toggle and get a separate "from" link), the lists hub page was reorganised and promoted to the top nav (replacing "leaders"), list pagination no longer hard-caps at maxend, plus a real favicon (.ico serving + static/favicon.ico).
type: project
---

# Handoff: from-site links + lists rework + favicon (2026-06-16)

> Continues [`2026-06-16-001-list-page-pagination-and-from-site`](2026-06-16-001-list-page-pagination-and-from-site.md).

## Commits (oldest first)

| sha | what |
|---|---|
| `0684157` | add a favicon: serve `.ico` files and ship `static/favicon.ico` |
| `6b732c3` | rework the lists page and point the top nav at it |
| `afe9778` | link story domains to their from-site page |
| `de17066` | don't cap list pagination at maxend |
| `7895cf5` | give the badips sub-listings a whence |

## What changed

### Favicon (`0684157`)
- `srv.arc`: added `ico -> image/x-icon` to `type-header*` and `"ico" -> 'ico`
  to the static-filetype extension map, so `.ico` files serve statically.
- `news.arc`: the `favicon.ico` redirector op is now only defined
  `(unless (empty favicon-url*))`. With no `favicon-url*` set, the static
  `static/favicon.ico` is served directly instead of 302-looping (this was the
  repeated favicon.ico 302s seen in the browser network tab).

### Lists page + nav (`6b732c3`)
- Top nav: `"leaders"` toplink replaced by `"lists"` (-> the lists hub).
  `toplabels*` updated accordingly (`"leaders"` -> `"lists"`).
- The `lists` page reorganised: reordered the public rows, added `leaders`,
  `topcolors` (with a `topcolors-label` helper that uses `underlink`), an
  editor-only section (`flagged`/`killed`), and an admin-only section
  (`optimes editors topips spurned badlogins goodlogins badguys badsites
  badips`), separated by spacerows.

### Story domain -> from-site link (`afe9778`)
- The sitename shown in a story's comhead is now a link to its `from?site=`
  page (HN-style). Implemented by rewriting `fromlink` and pointing the comhead
  `sitestr` at it.
- **Admin vs non-admin split (intentional):**
  - non-admin: the comhead domain *is* the from-link (`fromlink` prints no bar,
    link text = the sitename).
  - admin: the comhead domain stays the site-ban toggle (`w/rlink` cycling
    ignore/kill/nil), and admins instead get a separate `| from` link in the
    itemline subtext via `(if (admin) (fromlink s))` (here `fromlink` prints the
    bar and link text `"from"`).
  - `fromlink`'s internal `(admin)` checks line up with both call sites.
- `fromurl` now appends `&kind=story` only when there's a `next` cursor. Cosmetic
  (the `from` op defaults `kind` to `"story"` when absent), so first-page URLs
  are the cleaner `from?site=X`.

### Pagination no longer capped at maxend (`de17066`)
- `display-items`' "More" gate dropped the `(<= (+ numstart (- end start))
  maxend*)` term; it's now just `(< end (len items))`.
- For the ranked/linear lists this is a **no-op** because their producers
  already cap at `maxend*` (`topstories`/`newstories`/`beststories`/`noobs` all
  take `maxend*`), so `(len items) <= maxend*`.
- Real effect is on the **uncapped** producers: `from` (`stories-from` returns
  all of a site's stories) and `upvoted` (`voted-items` is uncapped) now page
  through everything. Intended for `from`; **`upvoted` is now unbounded too** -
  revisit if that's not wanted (would need an explicit cap, since the maxend
  gate that used to provide it is gone).
- Also a whitespace reflow in `morelink` (no behaviour change).

### badips whence (`7895cf5`)
- The two admin "dead from <ip>" / "live from <ip>" sub-listings regained a
  `"badips"` whence arg on their `listpage` calls.

## Status
Working tree clean; all five commits load (verified `./sharc` ->
`(load "news.arc")` after the final commit). Several commits ahead of origin;
run a load/`./sharc test.arc` before pushing. `static/*.js` stays untracked
(`static/favicon.ico` is now tracked).

## Open / follow-ups (carried + new)
- **`/upvoted` unbounded paging** (new, from `de17066`) - decide whether to cap.
- `/newest` still uses `?p=` not the HN `?next=&n=` cursor (conscious choice).
- `sitename->stories*` only indexes submissions made after the feature landed;
  a one-time backfill over `stories*` is needed for old stories to appear under
  `from`.
- Still deferred from earlier handoffs: the `collapse` server op (client-side
  only), hide-story, AJAX `morelink` paging.
