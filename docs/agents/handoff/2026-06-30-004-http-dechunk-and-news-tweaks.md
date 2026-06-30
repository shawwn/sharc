# HTTP response dechunking + several news.arc review-and-commit tweaks

Date: 2026-06-30

A review-and-commit session in the same style as the prior handoff: the
user staged changes one at a time and asked "what do you think of the
staged changes?" for each, iterating until correct, then landed each as
its own commit. The substantial piece was diagnosing and fixing a
`arc-http-fetch` UTF-8 crash (chunked transfer-encoding) in `arc0.lisp`;
the rest were small `news.arc` changes. Session range on `main`:
`8a7f94a..2b91190` (parent `8a7f94a` "Minor comment fixup" was the prior
tip).

## What was accomplished

- **`7f9b327`** `news.arc`: `topright` extracts the logout/login URL
  construction into `logout-url` / `login-url`, and passes `"logout"` /
  `"login"` as the third `id` arg to `link` so the anchors render with
  `id="logout"` / `id="login"`. Behavior-preserving except the new ids.
  (A separate login-url build at `news.arc:1132` uses `(fave-url id auth)`
  as its goto, so it does **not** fit the new `login-url` helper - left
  alone.)
- **`a31382c`** `news.arc`: added `"ycombinator"` to `long-domains*` so
  the domain-shortening logic (`news.arc:~1984`) shows the third level for
  YC urls (e.g. `news.ycombinator.com`, `blog.ycombinator.com`) instead of
  collapsing to a bare `ycombinator.com`.
- **`5a3d620`** `news.arc`: `item-api` (the `item.json` endpoint) now
  omits content fields for deleted items. Wrapped the field set in
  `(let del i!deleted ...)` and guarded `by`/`dead`/`descendants`/`kids`/
  `parts`/`score`/`text`/`title`/`url` with `(unless del ...)`. Kept
  structural fields (`id`, `type`, `time`, `parent`, `poll`, `deleted`).
  Because Arc `obj` drops nil-valued keys, a deleted item serializes to
  just the structural fields (fields absent, not `null`). Matches HN's
  Firebase API and avoids leaking deleted story/comment contents.
- **`cf6edbf`** `arc0.lisp`: **the main fix.** Reworked the HTTP client to
  read the response as raw octets and decode to text only after transfer
  framing is removed. See Key decisions for the bug. New helpers in the
  HTTP convenience layer:
  - `http-slurp-octets` - reads the whole response into an adjustable
    `(unsigned-byte 8)` vector, no char decoding. SSL path calls `ssl-read`
    directly (bypassing the gray stream's per-buffer UTF-8 decode); plain
    socket reads bytes to EOF (the stream is bivalent via
    `:element-type :default`).
  - `dechunk-octets` - strips chunked transfer-encoding framing at the byte
    level (hex size line, copy N bytes, skip CRLFs, stop at the 0 chunk;
    ignores chunk extensions after `;`).
  - octet helpers `octets-find-crlf`, `octets-find-crlfx2`,
    `octets->latin1`, plus `split-crlf` / `parse-http-headers`.
  - `http-parse-response` now takes an octet vector, splits headers
    (latin-1) from body, parses the status code, and dechunks
    (`Transfer-Encoding: chunked`) or trims to `Content-Length`.
  - `arc-http-fetch` reads via `http-slurp-octets`, then decodes the
    assembled body once as `'(:utf-8 :replacement #\?)` so a stray
    non-UTF-8 byte degrades to `?` instead of raising.
- **`2b91190`** `news.arc`: editing a story's url now re-registers it in
  the `sitename->items*` index under the new domain. `register-story` and
  `process-url` gained optional `url` / `urlname` args (and `process-url`
  now *uses* the passed `urlname` instead of recomputing `(sitename url)`).
  Added `unregister-item` (pulls an id out of the index). In the edit
  handler the `(= (i name) val)` assignment moved **above** the register
  calls so `register-story i` sees the new url, and a new clause
  `(when (and (is name 'url) (metastory i)) (register-story i))` fires on
  url edits.

## Key decisions

- **The HTTP UTF-8 crash was a layering bug, fixed by separating transport
  bytes from text decoding.** `arc-http-fetch` previously read the response
  with `read-char` in a loop; the SSL stream's `stream-read-char`
  (`arc0.lisp:~794`) decodes each `SSL_read` buffer as UTF-8 *immediately*,
  before HTTP framing is removed. `news.ycombinator.com` (Cloudflare)
  replies `Transfer-Encoding: chunked`, and a 3-byte char `E2 80 93`
  (U+2013 en dash "–") was split across a chunk boundary: the raw stream
  was `E2 [CRLF 2c1b CRLF] 80 93`, so `octets-to-string` saw `E2` followed
  by `0x0D` (CR, not a continuation byte) and raised
  `invalid-utf8-continuation-byte` ("byte position 717"). The byte array in
  the backtrace literally showed `... 91 226 13 10 50 99 49 98 13 10 128
  147 93 ...` = `[ E2 \r\n 2 c 1 b \r\n 80 93 ]`. Two layered problems:
  (1) decoding before reassembly; (2) `http-parse-response` never dechunked,
  so chunk-size lines would have leaked into the body even without the
  crash. A "just decode with `:replacement`" band-aid was explicitly
  rejected: it would mangle the split "–" into `?` and leave chunk framing
  in the body. Fix = byte-level read + dechunk, decode last.
- **`item-api` deleted-item suppression relies on `obj` dropping nil keys.**
  Confirmed in code: Arc hash assignment of nil removes the key, and
  `json-write-object` only emits `(keys h)`. So guarding fields with
  `(unless del ...)` makes them absent (not `null`). `parent`/`poll` are
  intentionally **not** guarded so deleted items keep their tree placement.
- **Editing a story's url keeps the old domain registration - intentional.**
  The user confirmed this is by design: a story stays findable under its
  old `sitename->items*` entry after a url edit. So `register-story` only
  adds the new domain; the old is left in place. `unregister-item` was
  reviewed for the alternative (clean up the old url) but is **not wired
  into the edit path** - it lands as a standalone helper / groundwork for a
  future caller (e.g. a delete path). The review flagged this as dead code
  twice before the user clarified it was intentional.
- **`process-url`'s `urlname` param must actually be used.** An earlier
  draft threaded `urlname` through but `process-url` ignored it (still did
  `(awhen (sitename url) ...)`), which is a silent footgun if a caller ever
  passes a non-default name. Fixed during review to `(awhen urlname ...)`,
  matching `unregister-item`.
- **`unregister-story` was renamed to `unregister-item`** (last review
  round) since it just removes an id from `sitename->items*` and isn't
  story-specific.

## Important context for future sessions

- **HTTP client** (`arc0.lisp`, "HTTP convenience layer", ~line 915+):
  `arc-http-fetch` / `http-fetch` now return a fully-decoded UTF-8 string
  with chunk framing removed. To extend (e.g. follow redirects, expose
  headers), the parsed headers are available as an alist via
  `parse-http-headers` and `http-parse-response` returns
  `(values status-code header-string body-octets)` with `body-octets` left
  undecoded. The gray-stream `stream-read-char` (`arc0.lisp:~794`) still has
  the latent cross-buffer split-multibyte bug, but the HTTP path no longer
  uses it; left unchanged as a separate concern.
- **Verifying the HTTP fix**: `printf '<expr>' | ./sharc` runs an arc
  expression (boot.lisp reads stdin). Cannot use `#–` char literals (reader
  rejects them) or negative `cut` indices. Verified this session:
  `(arc-http-fetch "https://news.ycombinator.com/item?id=48704289")`
  returns a 46546-char string, **exactly matching `curl`'s char count**
  (curl: 46546 chars / 46634 bytes), en-dash present, body ends at
  `</html>` (no leaked framing). Plain HTTP (`http://example.com/`) also
  verified - exercises the bivalent `read-byte` path + `Content-Length`
  branch.
- **`scrape.arc` `curl-get-public`**: an unstaged working-tree edit swaps
  `curl-get-public` from shelling out to `curl` to calling `(http-fetch
  url)`. This is what surfaced the dechunk bug (curl dechunks/decodes for
  you; native `http-fetch` didn't until `cf6edbf`). That switch is now safe
  to land but was **left uncommitted** this session.
- **Working tree**: `main`, ahead of `origin/main` (this session's commits
  unpushed). **Uncommitted/unstaged: `news.arc` and `scrape.arc`** were
  intentionally kept out of every commit - do not sweep them in. The
  `news.arc` working-tree edit is a set of nil-guards in the `down` loop
  around `news.arc:354` (`(and i stop (stop i))` / `(and i (test i))`); the
  `scrape.arc` edit is the `curl-get-public -> http-fetch` switch above.
