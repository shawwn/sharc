---
name: float-timing-and-quasisyntax
description: msec and friends now use double-float for sub-millisecond timing, with clean disp/~F printing and num rounding at the display sites; adds now/nsec clocks; quasisyntax (#`) now auto-converts arc symbols to CL symbols; fixes med to a true median (drops redundant median); plus newstring/num precision fixes and a ?perf cache bypass.
type: project
---

# Handoff: float timing, clocks, quasisyntax, median (2026-06-04)

Eleven commits on top of the previous handoff
(`7fd6564 docs: add handoff for byte vectors, utf-8, and isotable`).
Three near the start (`900c98b`, `2b180d8`, `1148f47`) are Shawn's own.

## Commits

| sha | what |
|---|---|
| `900c98b` | Minor whitespace |
| `2b180d8` | num: use (expt 10d0 digits) for more precise decimals |
| `1148f47` | newstring: fill with spaces by default |
| `232445d` | arc.arc: cache bypasses caching when timef returns nil |
| `e9ed8a1` | arc1.lisp: quasisyntax converts symbols to CL symbols |
| `27a1497` | arc0.lisp: disp prints doubles cleanly and recurses with disp |
| `52a1324` | arc0.lisp: msec returns a double for sub-millisecond precision |
| `bae7cfa` | news.arc: show fnid count in the admin bar |
| `4e826bd` | arc0.lisp: add now and nsec time primitives |
| `3730dbf` | arc.arc: fix med to return the true median |
| `e28cb33` | arc.arc: remove redundant median |

## Timing / floats (the main theme)

The motivation was sub-millisecond perf timing.  The whole chain:

- **`msec`** (`52a1324`): was `(floor ...)` (integer ms); now
  `(* 1d0 (* 1000 (/ (get-internal-real-time) internal-time-units-per-second)))`
  -> a **double** with sub-ms resolution.  Must be `1d0`, not `1.0`: a
  single-float loses precision once get-internal-real-time grows past
  ~16M (a few hours uptime).  `current-process-milliseconds` got the same
  double treatment (it has no arc callers).
- **`disp` clean doubles** (`27a1497`): `arc-disp-val` prints a
  double-float via `~F` (`137.207`, not `137.207d0`), and now recurses
  into lists with `arc-disp-val` instead of `arc-write-val` (so nested
  strings/chars display unquoted, matching Racket display).  `write` is
  unchanged, so it still prints doubles readably as `137.207d0` -- that's
  correct for `write`, don't "fix" it.
- **`num`** : gained an optional `nocomma` arg (`52a1324`) to suppress
  the thousands separator, and `(expt 10d0 digits)` (`2b180d8`) for
  precise decimal scaling.
- **Rounding at display sites**, because a raw *computed* double delta
  prints its full float expansion (e.g. `0.9220000000000255`):
  - `srvlog`/`log-request`: `(num parsetime 3 t t t)` -- rounded, no comma
    (it's a log column); the `***` slow check still uses the raw doubles.
  - news admin bar: `(num elapsed 3 t t)` -- rounded, comma kept (human).
  - `/optimes` avg/median/total all round (median via `only&num`/round).
  - The `time` macro deliberately still shows the raw value (Shawn is OK
    with the noise there).
- **`newstring`** (`1148f47`): `(newstring n)` now fills with spaces
  (was `#'make-string`, implementation-dependent fill); matters for
  `num`'s zero-padding and string building.

### Clocks (`4e826bd`) -- read the comment block in arc0.lisp

- `now`  -- wall-clock Unix time (double seconds, microsecond precision,
  `get-time-of-day`).  Absolute, but **can jump** (NTP).  For "what time
  is it" stamps.
- `msec` -- monotonic milliseconds (double).  For durations.
- `nsec` -- monotonic nanoseconds (integer, `clock-gettime` with
  `CLOCK_MONOTONIC`).  **Jump-proof**, high-res.

`msec`/`nsec` have arbitrary, unrelated epochs (`nsec` ~ uptime, not Unix
time), so only *differences* are meaningful -- don't compare them to
`now` or each other.  Use `now`/`nsec` for wall stamps vs durations
accordingly.  (`CLOCK_MONOTONIC_RAW`/`UPTIME_RAW` aren't defined on this
SBCL/Mac.)

## median (`3730dbf`, `e28cb33`)

`med` took `(round (/ n 2))`, off by one for odd lengths and never
averaging for even.  Now: middle element for odd n, average of the two
middles for even n (so even-length medians can return a ratio/double, not
an input element).  Test added (odd/even/single/pair).  The separate,
weaker `median` (`(sort > ns)`, trunc index, no averaging, no test arg)
was unused and removed.

## quasisyntax (`e9ed8a1`)

`ac-qs` now runs `cl-quoted` on atoms instead of passing them through, so
arc symbols inside `` #` `` become their CL symbols (uppercased), like
`#'`/`function`.  A bare `` #`(let ...) `` now yields a real `(CL:LET ...)`
-- no more `cl::` on every operator.  `#,` holes are still ac-compiled.
A symbol that isn't a real CL symbol still interns as a fresh uppercase
:arc symbol (undefined if called), same as `#'`.

## ?perf cache bypass (`232445d`)

`cache` treats a nil cache duration as "don't cache": when `(timef)` is
nil it calls `(valf)` fresh instead of erroring on `(< ... nil)`.
`newscache` uses `{if arg!perf nil (* caching* time)}`, so `?perf` on a
request forces an uncached render for measuring real render time.  The
admin bar also shows `(len fns*) fnids` (`bae7cfa`).

## Status

`./sharc test.arc` => **413 passed, 0 failed** (added `med` test, plus
earlier `table`/`isotable`/`byte-vectors`/`utf8`/`urlencode`/`fn-names`/
quasisyntax bare-operator assertions).  `news.arc` loads clean.  Branch
`main`, working tree clean, 17 commits ahead of `origin/main` (not pushed
before this doc).
