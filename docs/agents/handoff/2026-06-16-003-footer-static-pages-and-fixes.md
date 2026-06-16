---
name: page footer, static pages, newsadmin fixes
description: A grab-bag of news polish - a page footer + the standard HN static pages (faq/guidelines/security/welcome), robots.txt, perpage/threads-perpage made editable from newsadmin, a kill-all-by crash fix, eschtml for the from title, and a [delayed] pseudo-text marker.
type: project
---

# Handoff: page footer + static pages + newsadmin fixes (2026-06-16)

> Continues [`2026-06-16-002-from-site-links-and-lists-rework`](2026-06-16-002-from-site-links-and-lists-rework.md).

## Commits (oldest first)

| sha | what |
|---|---|
| `46ddebe` | minor whitespace |
| `988edf9` | add `robots.txt` disallowing action/auth endpoints (matches HN's) |
| `11ccacc` | make `perpage`/`threads-perpage` editable from newsadmin |
| `3dc6261` | fix kill-all-by passing the profile object instead of the username |
| `1b732b3` | use `eschtml` for the from-page title's site name |
| `a518cf9` | show `[delayed]` for delayed items in pseudo-text |
| `d41adf3` | add page footer + standard static pages (faq, guidelines, security, welcome) |

## What changed

### kill-all-by crash fix (`3dc6261`) - the notable bug
The newsadmin "kill all by" form (converted to `urform` back in `7a42289`)
bound `subject` to `(profile arg!id)` - the **profile object** - then passed it
to `killallby`/`submitted-url`, which both want a **username string**.
`killallby` -> `submissions` -> `(uvar subject 'submitted)` expands (via
`uvar`, news.arc:154) to `((profile <profile-object>) 'submitted)`; `profile`
of a non-username returns nil, and `(nil 'submitted)` is "Function call on
non-function: NIL". Only triggered for users that actually exist (so the
`profile` guard passed). Fixed to bind `subject` to `arg!id` and use `profile`
purely as the existence guard:
```arc
(urform (let subject arg!id
          (if (profile subject)
              (do (killallby subject) (submitted-url subject))
              "newsadmin"))
  ...)
```

### Page footer + static pages (`d41adf3`)
- New `footer` fn (Guidelines / FAQ / Lists / API / Security / Legal / Apply /
  Contact), wired into `longpage` as `(or (hook 'longfoot) (footer))`; the
  `br2` was moved out of `admin-bar` to sit above it.
- New `site-email*` config var (in the `this-site*` block, atstring-escaped as
  `"hn@@ycombinator.com"`) used by the Contact `mailto:` link.
- Dynamic `welcome` op **removed**; `welcome-url*` now points at the static
  `newswelcome.html`.
- Static assets added under `static/`: `newsfaq.html`, `newsguidelines.html`,
  `security.html`, `newswelcome.html`, `yc.css`, `yc500.gif` (these are
  HN's pages; edit the prose to suit this forum, and note they reference
  `yc500.gif`/`yc.css`). `.html` already serves statically; `.gif`/`.css` too.

### Smaller items
- `robots.txt` (`988edf9`): `static/robots.txt` with a crawl-delay and
  `Disallow` for the action/fnid/auth paths (`/vote? /reply? /flag? /hide?
  /login /logout /x? /r?` ...). Mirrors HN's robots.txt.
- newsadmin config (`11ccacc`): `perpage*` and `threads-perpage*` added to
  `nad-fields` and the setter `case`, so they're tunable live from newsadmin.
- `from` title (`1b732b3`): `(eschtml site)` instead of
  `(tostring:pr-escaped site)`.
- `pseudo-text` (`a518cf9`): added a `(delayed i) "[delayed]"` case before the
  `"[dead]"` fallthrough.

## Status
Working tree clean; all committed and loading (verified `./sharc` ->
`(load "news.arc")`). Several commits ahead of origin. `static/*.js` stays
untracked; the new `static/*.html`/`yc.css`/`yc500.gif`/`favicon.ico`/`robots.txt`
are tracked.

## Open / follow-ups (carried)
- The new static pages are HN's verbatim - reword for this forum before
  shipping publicly.
- `/upvoted` unbounded paging (from `de17066`) - decide whether to cap.
- `/newest` uses `?p=` not the HN `?next=&n=` cursor (conscious choice).
- `sitename->stories*` only indexes post-feature submissions; backfill over
  `stories*` if `from` should cover old stories.
- Still deferred: `collapse` server op (client-side only), hide-story, AJAX
  `morelink` paging.
