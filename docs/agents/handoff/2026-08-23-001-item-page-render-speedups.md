---
name: item page render speedups
description: Cut /item?id=49397074 (1600 comments) from 490ms to 50ms logged out and 3050ms to 364ms as an admin, by turning on explicit-flush (force-output per disp was a write() syscall per pr on the response socket), adding native fast paths to eschtml/urlencode/text-time, rebuilding the comment cache around a self-pruning (key body) slot so it covers nested comments instead of only the top level, and fixing fnkey->fnid* whose isotable hashed every fnid key identically and went quadratic.
type: project
---

# Handoff: item page render speedups (2026-08-23)

`http://localhost:1234/item?id=49397074&perf=t` reported 812ms. Target was
~100ms. It now reports ~50ms for a logged-out viewer and ~112ms for a
logged-in one.

Measured on an isolated server (port 1235) over a `cp -al` hardlink copy of
`arc/`, so the live server and its data were never touched. `writefile` is
atomic-rename, so a hardlinked shadow is safe to write to.

## Where the time went

| | ms |
|---|---|
| baseline | 490 |
| + `explicit-flush` | 264 |
| + native `eschtml` / `urlencode` | 118 |
| + comment cache covering all depths | **50** |

Logged in as an admin, which bypasses the comment cache and mints 6,838
fnids, the same page went **3,052ms -> 364ms** from the `fnkey->fnid*` fix
in section 4.

The 812ms the user saw was the same page on a busier box; the server process
also runs `scrape.arc` and sits at ~104% CPU.

### 1. `force-output` on every `pr` (the big one, 490 -> 264)

`arc-disp` and `arc-write` in `arc0.lisp` ended with
`(unless *arc-explicit-flush* (force-output port))`, and **nothing in the tree
ever declared `explicit-flush`**. `respond` writes straight to the socket
fd-stream (`arc-socket-accept` makes it `:buffering :full`), so every `pr`
forced a `write()` syscall. A 2.6mb page is a few hundred thousand of them.

Flipped the `defvar` default to `t`. Nothing needed the implicit flush:

- sbcl line-buffers stdout/stderr, so `prn` still reaches a terminal on its own;
- the places that print a *partial* line already call `flushout` explicitly
  (`arc-tl2`'s repl prompt at `arc0.lisp:2239`, `noisy-each`'s dots at
  `arc.arc:1969-1980`) -- the tree was already written for this mode;
- the response socket is flushed by the `close` in `handle-request-1`.

`(declare 'explicit-flush nil)` restores the old behavior.

No restart needed: `reload` calls `reload-runtime`, which recompiles and loads
the `.lisp` runtime as well as re-loading `loaded-files*`, and `maybe-reload`
watches `(runtime-changed)` alongside the `.arc` files. See
`2026-08-21-004-reloadable-lisp-runtime.md`.

### 2. Character-at-a-time string plumbing (264 -> 118)

Bisecting `display-subcomments` (94% of the page) showed the cost was not data
lookups -- `comment-navs` 9ms, the whole `ranked-kids` tree sweep 4ms,
`superparent` 0.8ms -- but html generation. Per comment: `agelink` 22us,
`votelinks` 30us, four `clickylink`s 42us.

The common factor was `eschtml`, which `sanitize` runs on **every dynamic tag
attribute** -- each href, id, class and title on the page:

```arc
(def eschtml (str) (tostring (each c str (pr (eschtml-char c)))))
```

Three functions got native fast paths, following the `posmatch1`/`multisubst1`
convention in `strings.arc` (pure version kept under the `1` suffix, native
version in front, differential tests in `test.arc`):

| | before | after | |
|---|---|---|---|
| `eschtml` (`html.arc`) | 4.75us | 0.12us | 39x |
| `urlencode` (`strings.arc`) | 10.1us | 0.66us | 15x |
| `text-time` (`news.arc`) | 4.71us | 0.79us | 6x |

All three are written as `#'(defun ...)` inline CL (handoff `009` documents the
form). Two gotchas found doing it:

- CL code inside a `#'` body cannot call an Arc function -- `cl-quoted` upcases
  the whole form, and Arc functions live in gcells under lowercase names. The
  escape table therefore moved to the CL side as `eschtml-char-1`, with
  `eschtml-char` as its Arc-visible wrapper, so there is still exactly one copy
  of it.
- A package-marker symbol like `sb-ext:string-to-octets` does not resolve
  inside a `#'` body either. `urlencode-fast` takes the bytes as an argument
  and lets Arc's own `utf8-encode` produce them.

`eschtml` and `urlencode` return the *same object* when there is nothing to
escape, which is worth knowing if anything ever mutates a returned string.

### 3. The comment cache was covering 6% of the page (118 -> 50)

`should-cache-comment` required `(no showpar)`, but `display-subcomments` passes
`showpar = (> indent 0)`. So only depth-0 comments were ever cached: **98 hits
out of 1611**. It is now 1579 of 1580.

Rebuilt per the user's design. `comment-cache*` holds ONE slot per comment id,
and the slot is a `(key body)` pair. A lookup recomputes the key and compares;
a miss overwrites the slot in place. The cache therefore cannot hold more
entries than there are comments no matter what changes about how a comment
renders, and nothing has to prune it. `comment-cache-timeout*` and `cc-window*`
are gone; `uncache-comment` now only bumps `comment-gen*`, since that counter is
part of the key.

The key is `whence`, `indent`, `showpar`, `showon`, the comment's **`cnav`
entry** (root/prev/next/n -- so reordering a thread cannot leave a cached
comment pointing at stale neighbours), `comment-gen*`, and `cc-timeout` as an
age bucket, because the body prints a relative "N hours ago".

Caching is now restricted to `(no (me))`. This is both faster and a fix: the old
predicate excluded admins, editors and the author, but **not an ordinary
logged-in user**, whose flag/fave/unvote links would be baked into the shared
cache and served to everyone else. A logged-in body is genuinely per-viewer
(`flaglink`, `favelink`, `unvotelink`, `editlink`, and `user-name`'s noob
colouring all read `(me)`), so it is not sharable. Keying on the viewer instead
would work, but with one slot per comment two people reading at once would just
evict each other.

Consequence: a logged-in or admin view does not use the cache and lands at
~112ms rather than ~50ms. Still 7x better than where it started.

## How it was verified

- **A/B against a pristine `git worktree` at HEAD, same shadow data**: rendered
  the page with the pre-change tree and the optimized tree and diffed. Once the
  relative-age strings that ticked over between the two runs are normalised, the
  diff is **0 lines** on a 2.59mb page.
- Cached vs uncached vs repeated renders in one process: **byte-identical**
  (`comment-caching*` off, then on cold, then on warm).
- Differential fast-path vs pure-path runs: ~3200 `eschtml` cases (every char
  0-1000, random strings over `<>&"'/`, plus non-string sequences), ~6000
  `urlencode` cases (every char 0-2000, random multibyte), 20,400 `text-time`
  timestamps. Zero mismatches.
- `./sharc test.arc`: **963 passed, 0 failed**, up from 927. The 36 new
  assertions lock in fast-path/pure-path agreement for `eschtml` and
  `urlencode`, including the returns-the-same-object case. `text-time` has no
  test there because `test.arc` does not load `news.arc`; it is covered by the
  differential run only.
- Invalidation: `uncache-comment` on one comment drops exactly one cache hit
  from the next render.

### 4. Every fnid key hashed to the same value (admin: 3050 -> 364ms)

Separate, pre-existing, and only visible when logged in as an admin, which
is the one view that puts a `w/rlink` on every comment (edit / flag / kill /
blast / delete / collapse). An item page with 1580 comments mints **6,838
fnids**, and the page took **3.1 seconds**.

`fnkey->fnid*` (`srv.arc:455`) was an `isotable`, which SBCL builds with
`:hash-function #'sb-impl::psxhash`. `psxhash` descends only a couple of
levels into a list, and every fnid key buries what makes it distinct -- the
captured scope and the quoted body -- below that:

```
("test" "item" "?id=49397074" (w/rlink ((i 7) (whence "item?id=...")) ((do ...) (pr "kill"))))
```

Five different keys, one hash value: `2758056743257952364` for all of them.
The table degenerated into a single chain compared pairwise with `arc-is2`,
so insertion was O(n) -- 60us at 1000 entries, 400us at 4000 -- and building
a page went quadratic in its own link count.

Fixed by hashing the printed key into a plain table: `(def fnid-hash (key)
(tostring:write key))`. Flat 1.6us at any size. `psxhash` in this SBCL takes
no depthoid argument, so deepening the isotable's hash was not an option.

The one property this relies on is that `write` is faithful. If two keys
printed alike they would share an fnid and the second registration would
overwrite the first's function -- worse than a bucket collision, since
clicking "kill" on one comment could act on another. `*print-level*`,
`*print-length*` and `*arc-print-string-length*` are all nil outside the
repl's own printing of a result, so it is. An earlier version bound those
four specials off in a CL helper; that was checked against plain
`tostring:write` over deep nesting, 2000-character strings, quote and
backslash and symbol and char and float mixes -- identical on every one, and
the same speed -- so the helper went away. `define-test fnid-hash` in
`test.arc` locks the faithfulness property down.

`gen-fnid` is now the largest single piece of what is left (12us of
`rand-string 22`, so ~84ms of the 364).

## Gotcha for anyone re-measuring

The **first** render of a thread is not comparable to later ones, and this is
pre-existing, not caused by the cache. `delayed` (`news.arc:695`) marks each
comment `mature` the first time it is evaluated, so recent comments render as
pseudo-text on render 1 and normally on render 2. Always warm twice before
diffing.

### The startup progress output

Turning on `explicit-flush` broke the ordering of the startup messages: the
progress dots appeared *before* the `load 130 item buckets:` labels that
introduce them. `noisy-report` (`arc.arc:1969`) prints its dots to **stderr**
via `(w/stdout (stderr) ...)` while the labels are printed to stdout by the
caller. Both land on the terminal, and previously every `disp` force-flushed,
so the two streams stayed in program order by accident. `noisy-report` and
`noisy-flush` now flush stdout before switching over.

Worth remembering generally: anything that mixes stdout and stderr on the
same terminal now has to flush stdout itself.

## Not done

- `votelinks` is outside the cached body (it lives in its own `<td>`) and is the
  largest remaining uncached cost: caching it too took the page from 39ms to
  27ms in a ceiling experiment.
- `text-age` is still ~2.2us and pure; worth ~3ms.
- Whole-page caching was measured as a ceiling (2.5mb as one `pr` is 1.4ms) but
  not attempted -- the page varies per viewer for the same reasons the comment
  bodies do.
- The admin page still mints an fnid per admin link. Giving those links plain
  urls with an auth token, the way `vote` already works, would remove 6,838
  closure registrations from the page and is the next big win on that path.

## Picking these up in a running image

`(reload)` is enough for all of it, `.lisp` included -- `reload-runtime`
recompiles and loads the runtime sources, and `maybe-reload` (what `autoreload*`
polls) checks `(runtime-changed)` as well as `loaded-files*`.

Two initializers are worth knowing about, because a reload re-runs the *form*
but the form declines to reassign:

- `(defvar *arc-explicit-flush* t)` only takes effect on a variable that is
  still unbound, so an image booted before the change keeps its old value.
  `(declare 'explicit-flush t)` sets it directly.
- `(or= fnkey->fnid* (table) ...)` likewise keeps whatever is already bound, so
  an image that built the isotable keeps it. `(= fnkey->fnid* (table))` swaps
  it, and the entries do not need migrating -- they are only a cache.

Neither is a reason to restart; both are one form at the repl.
