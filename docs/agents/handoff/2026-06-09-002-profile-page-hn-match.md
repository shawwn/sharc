---
name: profile page HN match
description: Reworks the news.arc profile page to match Hacker News. Renames "saved" to "upvoted" (split into submissions/comments, private), gives the username its own header row with a created timestamp, folds the page's links into user-fields as rows, and adds a `raw` vars-form field type plus a `td timestamp` html attribute.
type: project
---

# Handoff: profile page HN match (2026-06-09)

> Follows the fnid work in
> [`2026-06-09-001-fnid-content-dedup`](2026-06-09-001-fnid-content-dedup.md)
> (same session, unrelated feature).

## Commit

| sha | what |
|---|---|
| `fb91d4b` | news.arc: rework the profile page to match HN (app.arc, html.arc, news.arc) |

## What changed

The profile page (`user-page` / `profile-form` / `user-fields`) was
restyled to look and behave like Hacker News's.

### "saved" became "upvoted"

- `newsop saved (id)` -> `newsop upvoted (id comments)`. The page now
  splits into **upvoted submissions** and **upvoted comments**, selected
  by the `comments` arg (`"t"`/`"T"` truthy), like HN's `/upvoted`.
- `saved-url`/`savedpage`/`voted-stories` are gone, replaced by
  `upvoted-url` (takes an optional `comments` flag), `upvoted-page`, and
  `voted-items` (filters voted items by `cansee` then a story/comment
  test). `saved-link` was also removed.
- The page is private: `upvoted-page` only renders for `(me user)` or
  `(admin)`, and the `upvoted-links` row is `view`=u. Matches HN, where
  upvotes are visible only to the owner.
- **No `/saved` alias was kept** -- this is a fresh instance with no live
  `/saved` URLs to preserve. Add `(newsop saved (id) (upvoted-page id nil))`
  if old links ever need to keep working.

### user-fields restructure

`user-fields` now leads with a `raw` username header row (`user-field`:
an HN-style `<tr class=athing>` with the username linked, `class=hnuser`,
and the account age via a `timestamp` td attribute). Below the editable
fields it appends label-less rows for reset-password, submissions,
comments, and upvoted links, plus an email-visibility note (`email-msg*`).

The field tuple is `(typ id val view mod)`:
- `view` gates whether the row shows; `mod` whether it's editable.
- Rows with `id`=nil are intentional **label-less** rows (server-rendered
  HTML in the value); `only&pr` prints the `id:` label only when non-nil.

`user-submissions-link` / `user-comments-link` are now **unconditional**
(the old `(when (some astory:item ...))` guards were dropped), so the
links always show even for a user with none -- a deliberate HN-style
choice, not a bug.

### new `raw` field type (app.arc)

`showvars` intercepts `(is typ 'raw)` and just `(pr val)`, bypassing the
`tr`/`td` wrapper, so a raw value injects its own pre-rendered HTML rows
(used for the username header and a `<tr height:5px>` spacer).

`raw` is **view-only by construction**, no guard needed:
- display short-circuits on `raw` *before* the `mod` branch, so it never
  renders an input even if `mod`=t;
- the submit side (`vars-form`) only `readvar`s fields `(when (and mod v))`,
  and a raw field renders no input, so nothing is ever submitted or parsed
  under its name.

### html.arc

Added `(attribute td timestamp opnum)` so `(tag (td timestamp N) ...)`
emits `<td timestamp="N">` for HN-style relative-age rendering.

### form CSS (news.arc)

`input`/`textarea` fonts Courier -> monospace, explicit `color` dropped
(inherits black), textarea gains `resize:both`.

## Display safety note

`varline` prints `string` values with `pr` (no escaping), so the
server-generated HTML in `email-msg*` and the link rows renders as
intended. This is safe because those values are server-controlled;
user-editable `string` fields are still `striptags`-ed on input in
`readvar`, unchanged.

## Status

`./sharc test.arc` => **413 passed, 0 failed**, news.arc loads clean. No
dangling refs to the removed `saved-*` / `voted-stories` defs. Commit
`fb91d4b` is local (one ahead of `origin/main`), not yet pushed.
