---
name: noob-coloring-profile-warning-and-followups
description: Follow-ups after the SES email feature -- a newspage regression fix, profile email warning, hot-reload docs, configurable 7-day noob window (green names for everyone), and a local DMCA page.
type: project
---

# Handoff: noob coloring, profile warning, and follow-ups (2026-06-22)

A run of small commits after the SES email / password-reset feature
(see `2026-06-22-001`). Range `061bc7a..c49181a` on `main`.

## Commits

| sha | what |
|---|---|
| `061bc7a` | news: fix newspage by restoring its plain whence arg |
| `3ea742e` | news: rewrap the forgot/reset email strings (cosmetic) |
| `a29444d` | news: warn on the profile page when email is missing |
| `ffb724f` | docs: document hot reload and tweak the run command |
| `1d43c77` | Adjust site color (noob users were hard to read) |
| `e9de40e` | news: make the noob window configurable and widen it to 7 days |
| `4377e99` | Add dmca.html |
| `c49181a` | news: replace the Legal footer link with a local DMCA page |

## Key changes

### newspage regression fix (061bc7a)

`df1c379` had changed `newspage`'s param to `(o whence "news")`. That
is a **bug**: `newscache` (news.arc:833) reuses its `args` both as a
param list *and* spliced into the cache-fn call site `(,gc ,@args)`,
so an `(o ...)` form is emitted as a literal call argument and errors
at runtime in the logged-out caching branch (it tries to call `o`). It
only blows up when logged out, so a plain load test does not catch it.
`newscache` only supports plain args; reverted to `(whence)`. All call
sites pass `whence` explicitly anyway.

### Profile email warning (a29444d)

Added `alert-msg` (a light-yellow notice box built from
`zerotable`/`tr`/`tdcolor`/`row`) and show it on the profile form when
`(blank prof!email)`, telling the user to add an address or password
reset can't reach them. Completes the password-reset loop.

### noob coloring reworked (e9de40e, 1d43c77)

- New `noob-days*` (default 7); `noob` now uses it instead of a
  hardcoded 1 day. **This widens the whole "new account" window**, not
  just coloring: `noob` also gates the top-bar "welcome" link
  (news.arc:570) and the `noob-comment-msg*` notice (news.arc:2397).
  All three now last 7 days.
- `user-name` greens new accounts for **all viewers** now, via
  `(and show-noob (noob user))`, dropping the old `(editor)`-only inline
  age check. Matches real HN (green usernames are public).
- `userlink` gained `show-noob` and `id` params. The `id='me'` anchor
  used to be hardcoded whenever `(me user)`, so it was emitted on every
  byline/comment of yours -- **duplicate HTML ids** on a page. Now `id`
  is caller-supplied and only `topright` passes `'me'` (the one
  guaranteed-once spot). Other callers omit it.
- `1d43c77` adjusted the site color because the now-everywhere green
  noob names were hard to read against the old background.

### Hot-reload docs (ffb724f)

README now shows running News as `./sharc news.arc` with `ARC_RELOAD=t`
(and an rlwrap hint), documents autoreload (`autoreload*` /
`(set autoreload*)`) vs. manual `git pull` + `(reload)` for production,
and **drops `(declare 'direct-calls t)`** from the perf-tuning list:
direct calls keep hitting a function's old definition after a hot
reload, so the two are incompatible. `direct-calls` still exists in the
runtime; it's just no longer recommended.

### Local DMCA page (4377e99, c49181a)

Added `static/dmca.html` and pointed the footer "DMCA" link at it
(replacing the external YC "Legal" URL), matching the `security.html`
static-page convention.

## Verification

Each change was reviewed and committed individually (the user stages
one change at a time and asks "what do you think of the staged
changes?"). `news.arc` loads cleanly after each. `noob` is equivalent
to the old age threshold at the boundary (`days-since < 1` matched the
old `minutes-since < 1440`); the only deliberate change there is the
7-day widening and the editor->everyone visibility.

## Still open

- **SES production access** is still pending AWS's reply to the support
  case; until granted, sending is sandboxed to verified recipients (see
  `2026-06-22-001`).
- `noob-days*`'s comment says "how long a user's name is colored green",
  which undersells it (also affects the welcome link and noob-comment
  notice). Left as-is; reword if it bothers a future reader.
