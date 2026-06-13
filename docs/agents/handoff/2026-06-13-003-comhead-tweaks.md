---
name: comhead dead-marker and anchored redirects
description: Two small comment-header tweaks: deadmark shows [dead]/[flagged] to all viewers (no seesdead gate), and the kill/delete/blast/flag links redirect back to the acted-on comment via whence#<id>.
type: project
---

# Handoff: comhead dead-marker + anchored redirects (2026-06-13)

> Continues [`2026-06-13-002-comment-collapse`](2026-06-13-002-comment-collapse.md).

## Commits

| sha | what |
|---|---|
| `6258c12` | show [dead]/[flagged] markers unconditionally |
| `469ed76` | anchor kill/delete/blast/flag redirects to the comment |
| `d77a1ea` | make vars-form redirect after submit |

## What changed

- **`deadmark`**: dropped the `(seesdead)` gate on the `[flagged]` and
  `[dead]` markers, so they render for all viewers, not just those with
  showdead. `[deleted]` stays admin-only. Pairs with the earlier
  "always render the byline in itemline" change: regular viewers now see
  the byline + `[dead]`/`[flagged]` on dead/flagged comments.
- **anchored moderation redirects**: kill/delete/blast/flag (and the
  pollopt kill/delete) now get `whence#<id>` instead of bare `whence`,
  so acting on a comment returns you to it rather than the top of the
  page. Comments only anchor when `astree` (bare whence otherwise).
- **`vars-form` redirects after submit** (`d77a1ea`): switched
  `vars-form` (app.arc) from `taform` to `tarform`, so its `done`
  callback's *return value* is a redirect URL instead of rendering a page
  inline (same fix as the vote op, avoids the blank/duplicate page).
  Callers now return urls: news profile -> `user-url`, newsadmin ->
  `"newsadmin"`, edit -> `here`; blog edit -> `permalink`. (If you add a
  new vars-form caller, its done thunk must return a url now.)

## Still deferred (unchanged from 002)
- the **`collapse` server op** (hn.js pings `collapse?id=...` to persist a
  logged-in user's collapsed state, but no op exists, so collapse is
  client-side only and lost on refresh). Needs a `(newsop collapse (id un)
  ...)` recording a per-user collapsed set and rendering those comments
  pre-collapsed (the `coll` class + nosee/noshow).
- **Hide story** (`/snip-story`, `/hide`) and `morelink` AJAX paging.

## Status
Working tree clean. Several commits ahead of origin; run
`./sharc test.arc` before pushing. `static/news-hn.js` stays untracked.
