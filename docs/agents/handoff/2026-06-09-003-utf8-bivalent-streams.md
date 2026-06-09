---
name: utf-8 bivalent streams
description: Fixes a LATIN-1 stream encoding crash on any codepoint >255 (a curly ' U+2019 in profile about-text crashed both the disk write and the socket write). Switches infile/outfile/socket to :element-type :default + utf-8, which stay bivalent (utf-8 text via readc/writec, raw bytes via readb/writeb), and removes the now-redundant -binary stream variants.
type: project
---

# Handoff: utf-8 bivalent streams (2026-06-09)

> Surfaced while testing the HN profile rework
> ([`2026-06-09-002-profile-page-hn-match`](2026-06-09-002-profile-page-hn-match.md)):
> a profile `about` containing a curly apostrophe crashed on save and on
> serve.

## Commit

| sha | what |
|---|---|
| `9af72a5` | arc0.lisp: serve and store utf-8 via bivalent streams, drop -binary variants |

## The bug

Saving or serving any string with a codepoint >255 signalled
`:LATIN-1 stream encoding error ... the character with code 8217 cannot
be encoded`. 8217 = U+2019, the curly `'` that macOS substitutes for a
typed apostrophe. It crashed in two places, both LATIN-1 streams:

- `writefile` -> `outfile` persisting the profile (`profile/<id>.tmp`).
- `respond` writing the page to the socket.

## Root cause

The input path was already Unicode but the I/O streams weren't:

- `urldecode` (strings.arc) decodes percent-encoding as UTF-8 into real
  codepoints (documented/tested: `(urldecode "x%ce%bbx") => "xλx"`), so a
  browser-submitted `%E2%80%99` becomes the single char 8217 in memory.
- the response header already says `charset=utf-8` (srv.arc).
- but `infile`/`outfile` and the socket stream were `:external-format
  :latin-1`, which only encodes 0-255.

## The fix

Switch all three to utf-8 while keeping `:element-type :default`, which
makes them **bivalent** (this is the key fact, verified empirically):

- `readc`/`writec` (and `pr`/`disp`) encode/decode UTF-8.
- `readb`/`writeb` pass raw octets straight through, ignoring the
  external-format.

So image/binary serving is unaffected: it goes through `writeb`, which
writes verbatim bytes. Likewise reading a binary file via `readb` returns
raw octets even though the stream is utf-8.

Specifics (arc0.lisp):

- `infile`  -> `:element-type :default :external-format '(:utf-8 :replacement #\?)`
- `outfile` -> `:element-type :default :external-format :utf-8` (writes
  never need replacement; utf-8 encodes every codepoint)
- socket    -> `:element-type :default :external-format '(:utf-8 :replacement #\?)`
- the subprocess pipe (`pipe-from`) **stays `:latin-1`** on purpose
  (byte-preserving capture of arbitrary subprocess output).

`:replacement #\?` on the two read paths so a stray pre-utf-8 byte in old
data, or a malformed request byte, degrades to `?` instead of signalling
mid-request.

## Dropped the -binary variants

Because `:default` streams already do both text and bytes,
`infile-binary`, `outfile-binary`, and the `w/infile-binary` macro were
redundant and are removed. The one caller (static-file/image serving,
srv.arc) now uses plain `w/infile` + `readb`:

```arc
(w/infile i it
  (whilet b (readb i)
    (writeb b str)))
```

(`outfile-binary` had no callers at all.)

## Tests (test.arc)

- `utf8-file`: round-trips `U+2019` + `λ` + a CJK char through
  `writefile`/`readfile1`, the exact path that crashed.
- `binary-file`: reads `static/arc.png` (113 bytes, has the high `0x89`
  signature byte) via `w/infile`+`readb`, rewrites it via
  `w/outfile`+`writeb`, and asserts byte-for-byte identity.

## Migration

No data migration needed. The old LATIN-1 write path *crashed* on any
codepoint >255, so anything successfully persisted is effectively ASCII,
which reads identically under utf-8. The `:replacement` on reads covers
any stray high byte from before. The profile edit that triggered the
crash was never saved (the save is what blew up), so re-submitting it now
persists fine.

## Status

`./sharc test.arc` => **415 passed, 0 failed**. `9af72a5` is local,
3 commits ahead of `origin/main` (with the profile rework + its handoff),
not yet pushed.
