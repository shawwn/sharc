---
name: stdin-passthrough-auth-and-favorites
description: Subprocess stdin passthrough for (system)/(pipe-from); auth/redirect helpers moved to app.arc with a CSRF-protected logout; a favorites feature; and a batch of small news.arc cleanups/hardening.
type: project
---

# Handoff: stdin passthrough, auth refactor, favorites (2026-06-30)

A long review-and-commit session: one runtime change, two refactors, one
feature, and several small news.arc fixes.  All commits are on `main`.
**`main` is 10 commits ahead of `origin/main` -- nothing was pushed this
session.**  One small change is still loose in the working tree (see the
end).

Commits (oldest first):

- `60b7c4d` arc: pass current stdin to (system) subprocesses
- `4f11d20` arc: pass current stdin to (pipe-from) subprocesses too
- `1c73360` auth: move auth/redirect helpers to app.arc and CSRF-protect logout
- `671db29` app: move shell helpers from scrape.arc to app.arc
- `4fb849b` news: add favorites for stories and comments
- `fc80b77` Fix favorites link  (user's own)
- `ff32709` news: store nil topcolor when it equals the site default
- `b3acd1b` news: show member names to members; don't self-color in orange
- `a1ec78b` news: build email-msg* with the tag macro
- `9bd352b` news: only load items for integer ids
- `6fc3d0f` news: iterate loaded items by key instead of scanning maxid*

(`56a43fa`, `21a1c0b` "Minor whitespace" are the user's.)

## Runtime: subprocess stdin passthrough (arc0.lisp)

`(system cmd)` and `(pipe-from cmd)` used to give the child no stdin
(SBCL's `run-program` defaults `:input` to /dev/null), so e.g.
`(fromstring "foo" (system "cat"))` printed nothing.  Both now pass
`:input *standard-input*`:

- A real fd-stream (the interactive terminal) is inherited directly, so
  the child keeps the tty (isatty checks pass, interactive programs
  work).
- An in-memory stream like `fromstring`'s `string-input-stream` is copied
  to the child by SBCL through a background pipe, so the foreground
  output-pump can't deadlock against the input write.

Verified: cat/wc/head/read see stdin; partial reads (head) and ignored
stdin (echo) don't error; 200k input works; `pipe-from`'s lazy output
stream still delivers stdin even when read *after* the `*standard-input*`
binding has unwound (SBCL captured the stream at run-program time).
Test suite still 443/0.

**Bonus, untested interactively:** the scraper's `read-password-noecho`
runs `(system "stty -echo")`, which previously got /dev/null and silently
failed (password could echo); it now acts on the real terminal.  Confirm
next time a scraper password prompt comes up.

## Auth/redirect refactor (app.arc + news.arc), `1c73360`

Moved generic helpers from news.arc up into app.arc (the framework
layer): `auth-key`, `auth-for`, `good-auth`, `safe-goto`, `relative-url`.

- **`logout` is now CSRF-protected**: a `defopr` that requires a per-user
  hmac token (`good-auth (me) "logout"`) and redirects to a safe goto,
  instead of an unauthenticated op that printed text.
- **`login`** takes a `goto` and fires a `'login` hook; news.arc supplies
  `ensure-news-user` + `newslog` via `defhook login` instead of app.arc
  hardcoding news calls.
- **`relative-url`** was broadened from rejecting any leading `/` to only
  rejecting `//` (protocol-relative), so same-origin `/path` redirects
  are allowed; `//host`, `scheme:` urls, and backslashes are still
  rejected.  Matches `safe-goto`'s new default of `"/"`.
- **`hmac-key*` moved** from `newsdir*/hmac-key` (arc/news/hmac-key) to
  `arcdir*/hmac-key` (arc/hmac-key).  An existing deployment will
  regenerate the key (invalidating tokens in already-rendered links);
  harmless since links regenerate per page load, but move the file if you
  want to preserve it.

`671db29` similarly moved `shellquote/shellargs/shell/shellsafe` from
scrape.arc to app.arc (generic, and the news server doesn't load
scrape.arc).  scrape.arc keeps just its curl wrappers.

## Favorites feature (news.arc), `4fb849b` + `fc80b77`

HN-style favorites: mark any visible item as a favorite, view a user's
favorites at `/favorites?id=user` (publicly visible, like HN).

- new `favorites` profile field; `set-favorite` toggles membership via
  `(= (mem it (uvar user favorites)) (no un))` and **persists with
  save-prof** (the persistence call was missing in a first draft and was
  added before commit).
- `fave` / `favorites` ops, `fave-url` / `favorites-url`, and a `favelink`
  shown on item pages and the favorites page; profile gains a
  `favorited-links` row; favelink wired into the story subline and comment
  display.
- **Intentional CSRF tradeoff** (commented at the `fave` op): the
  `(good-auth "" id auth)` "fave on login" fallback uses a token bound to
  the empty user, which is identical for all logged-out visitors and thus
  effectively public.  That lets an attacker CSRF a logged-in user into
  favoriting an item.  Accepted because favoriting is benign, public, and
  easily undone; the sibling `hide` op deliberately has no such fallback.

## Small news.arc changes

- `ff32709` **topcolor**: saving the profile form with topcolor equal to
  the site default (`hexrep site-color*`, `"aaaae6"`) now stores `nil`
  instead of pinning the literal hex, so the user tracks `site-color*` if
  it changes.  Only normalizes an exact lowercase match (the form
  pre-fills lowercase, no `#`).
- `b3acd1b` **member visibility**: `user-fields` `m` is now "admin, or
  (profile owner is a member AND viewer is a member)"; the `name` field is
  visible to members (was owner/admin only) and editable by owner-or-admin
  (`(and m u)`).  `user-name`'s orange member color now skips your own
  name (`(~me user)`).  Note: the admin/blue clause was intentionally
  *not* given the same `~me` guard.
- `a1ec78b` **email-msg***: rebuilt with `(tag (font size 2) ...)` instead
  of a raw `<font>` string; output byte-identical.
- `9bd352b` **load-item** now guards `(when (isa id 'int) ...)`, so a
  non-int id can't reach the `(+ storydir* id)` file path (path-traversal
  hardening).  Safe: `load-items` maps `int` over the dir, `safe-id` ->
  `ok-id` requires `exact`, and `items*` is int-keyed.  Verified 1132
  items still load.
- `6fc3d0f` **each-loaded-item** iterates `(sort > (keys items*))` instead
  of looping `maxid*` down to 1, visiting only loaded items in the same
  descending order.  Verified identical results; all callers
  (`loaded-items`, `killedsites`, `banned-site-items`, `badips`) are
  read-only scans, so the keys snapshot is equivalent.

## Things explicitly ruled out / reverted

- A staged change making the **resetpw-link visible to admins** on other
  users' profiles (`,w` -> `,u`) was **rejected** and dropped: `resetpw`
  is `(me)`-scoped (`set-pw (me) ...`), so the link would have reset the
  *admin's own* password while appearing to act on the viewed user.  If
  admin-resets-other is ever wanted, parameterize `resetpw`/`try-resetpw`
  by user (or wire to the existing `changepw-page user` flow).

## Branch status / loose ends

- `main` is **10 commits ahead of origin** (unpushed).  User has been
  reviewing each change before commit; ask before pushing.
- **Still unstaged in the working tree** (deliberately not committed): a
  small `nil`-guard tweak in the `down`-loop scan near news.arc:354 --
  `(and i stop (stop i))` and `(when (and i (test i)) ...)` -- guarding
  against `(item id)` returning nil (now possible since load-item can
  no-op).  Likely a follow-on to `9bd352b`; commit it with the other if
  resumed.
- No automated test covers app/news/srv (`./test.arc` is core-only, 443
  passing).  Load-test by piping `(load "news.arc")` into `./sharc`;
  exercise behavior by running `(nsv)` and hitting http://localhost:8080.
