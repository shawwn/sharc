# Hide feature, HMAC auth tokens, and redirect hardening

Date: 2026-06-20

## What was accomplished

Several related pieces of work, committed individually on `main`:

### 1. Per-user "hide" for submissions (`476d0fc`)

HN-style hide/un-hide links so a logged-in user can remove stories from
their own listings without affecting anyone else. All in `news.arc`.

- New `hidden` field on the `profile` template (a list of item ids).
- `hidden`/`hide-item`/`unhide-item` predicate + mutators (saved via
  `save-prof`).
- `hidelink`/`hide-url` render a `hide`/`un-hide` link in the story
  subtext (gated on `news-type`, so only stories/polls are hideable).
  Link looks like `hide?id=N&un=t&auth=...&goto=...`, matching HN's URL
  shape.
- `hide` op (`newsopr`): checks item, login, auth, then toggles hidden
  and redirects via `safe-goto`.
- `hidden?id=user` page (`newsop hidden`): paginated list (like
  `newest`) of a user's hidden items with un-hide links.
- Hidden items filtered out of `topstories` (front page) and
  `newstories` (newest) via `(~hidden _)`. Cache-safe: `newscache`
  bypasses the shared cache for logged-in users, and anonymous users
  have no hidden items.
- Profile gets a conditional "hidden" link (`user-hidden-link`).

Access/visibility were made consistent (after review caught a leak):
both the link's view flag (`,u` = self-or-admin) and the page gate
(`(and (~me subject) (~admin))` = self-or-admin) allow the owner and
admins. So a regular user neither sees the link on someone else's
profile nor can hand-craft `hidden?id=alice`.

### 2. Auth HMAC tokens (in the hide commit)

- `hmac-key*` (diskvar, `arc/news/hmac-key`): a 64-char server secret,
  lazily generated via `auth-key` on first use and persisted. **This
  file is gitignored** (all of `arc/news/` is) and is a secret.
- `auth-for (user id)` = `HMAC-SHA1(secret, "user/id")`, downcased hex.
  Bound to **both** user and item id, so a token issued for one story
  can't be replayed against another. The `un` flag is deliberately not
  part of the token, so hide and un-hide of one item share an auth
  (matches HN's observed behavior).
- `good-auth (user id auth)` checks it.

### 3. SHA1 HMAC bugfix (`20c6489`)

`sha1.lisp`'s `hmac-sha1-digest` failed for a key of exactly 64 bytes
(the block size): it skipped both the `>64` shrink and `<64` pad
branches, reaching the xor loop with the key still a *string*, so
`(logxor #x5c #\c)` errored on a character. This was hit immediately
because `auth-key` generates a `rand-string 64`.

Fix: normalize the key with `(setf key (hash-vector key))` at the top of
the function. Verified against RFC 2202 test vectors and Python's `hmac`
for 30/64/65-byte keys; output is byte-identical for the previously
working `<64`/`>64` paths and now correct for `==64`.

### 4. Open-redirect hardening + safe-goto (`a69e371`, plus part of hide)

- `safe-goto (goto (o default "news"))` + `relative-url`: validates that
  a redirect target is a relative path back into the site (rejects
  schemes, `//host`, backslashes, `javascript:`), else returns `"news"`.
- Routed the `vote` and `reply` ops' redirects through `safe-goto`. In
  `vote`, `whence` is bound once to `(safe-goto goto)` so every path
  (including the **post-login** redirect, which was the exploitable gap)
  is covered. `reply` does the same for its `whence`, which protects the
  whole comment-submit chain because `whence` rides the fnid closure
  (`tarform`), not a resubmitted form field.
- Removed `safe-goto`'s own `urldecode`: `parseargs` (srv.arc:321) already
  url-decodes every query value, so decoding again was a double-decode
  that could mangle targets containing `+` or `%`.

### Minor/unrelated commits this session

- `f80ef36` rename `sitename->stories*` to `sitename->items*`.
- `2106f7e` index links in comments + add comments tab to `/from`
  (`urls`/`eachurl-pos` added in `app.arc`).
- `568a406` match HN's `/from` titles and toggle layout.
- `8d79433` count polls as submissions in `/from` and upvoted pages
  (`astory` -> `metastory`).
- `6b66e53` hide empty raw rows on the profile page.
- `0fa5826` close comments after 14 days instead of 45.
- `253da20` `(live:superparent i)` compose-syntax cleanup.

## Key decisions

- **Auth token is per-(user, id), not per-action.** Matches the two HN
  example URLs the user provided (same auth for hide and un-hide of the
  same id). Prevents cross-item replay.
- **HMAC over the cookie-as-auth approach.** The existing `vote` op puts
  the raw cookie in the URL (`auth=user->cookie*`). The new hide token
  is an HMAC of a server secret, so it never exposes the cookie. The
  `vote` op was left on its cookie scheme to avoid breaking `hn.js`,
  which builds vote URLs from the cookie.
- **Fixed the real sha1 bug rather than dodging it** (e.g. using a
  32-char key). Any 64-byte key was silently broken.
- **`safe-goto` does not url-decode.** Callers always receive
  already-decoded args from `parseargs`. Still safe against open
  redirects: a single-encoded `https://evil.com` is decoded by
  `parseargs` and rejected by `relative-url`. Double-encoded payloads
  return an ugly-but-on-origin path (no literal `:`, so browsers resolve
  it relative to our origin) rather than redirecting off-site.
- **`relative-url` is slightly over-strict** (rejects a `:` not preceded
  by `/`, so `item?id=5:6` falls back to `news`). Left as-is because no
  whence the app generates contains a bare colon; an RFC-accurate
  version (only treat `:` before the first `/?#` as a scheme) was
  proposed but not applied.
- **Hide is private even from admins on the page gate originally**, then
  changed to allow admins (`(and (~me subject) (~admin))`). Note: the
  earlier claim that "HN keeps hidden private from admins" was
  unverified speculation; the admin-visible behavior was the user's
  choice, not an HN match.

## Important context for future sessions

- **Running server must be restarted to pick up `sha1.lisp` changes.**
  `boot.lisp` loads `sha1.lisp` from source on every `./sharc` start (no
  core image, no `.fasl`), but a server already running holds the old
  code in memory. A stale running instance caused a confusing repeat of
  the 64-byte HMAC crash even after the fix was committed.
- **Secret:** `arc/news/hmac-key` is a generated server secret, gitignored.
  Don't commit it. If lost/regenerated, all existing hide/auth links
  become invalid (links are stable per user+item only while the key is
  stable).
- **Verification idiom used throughout this session:** load + smoke-test
  via `echo '(load "news.arc")(prn "OK") ...' | ./sharc 2>&1 | grep ...`.
  HMAC correctness was cross-checked against `python3 -c "import hmac..."`.
- **Pre-existing gaps noted but not fixed:** `process-comment` reads
  `whence` from the fnid closure (safe), but a future POST-only path that
  re-reads `whence` from form args would need its own `safe-goto`. The
  `vote` op still uses the cookie as its `auth` param (in the URL).
- Branch: `main`, clean after the handoff commit. All work above is
  committed.
- Relevant code locations in `news.arc`: hide/auth/safe-goto block sits
  right after the `vote` op (~line 1250+); profile template ~line 29;
  `topstories`/`newstories` filters ~line 378/909; profile links
  ~line 786-814; `hidden` page ~line 1340.
