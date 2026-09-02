---
name: memory tooling and the utf-8 comment cache
description: The live image had grown to 2.32GB and nothing could say where it went. Adds backward heap search (retainers, retaining-path, heap-big) alongside the existing forward tools, fixes three ways object-size and heap-hist were lying -- heap-hist was under-reporting the heap by 1.5GB -- then uses them: comment-cache* now holds utf-8 bytes rather than 4-byte-per-character strings, handed to the socket verbatim by a new writebytes. Also combines utf-16 surrogate pairs in from-json, tightens the read*/write* arities, and adds reload.arc.
type: project
---

# Handoff: memory tooling and the utf-8 comment cache (2026-09-01)

Covers `3a6834c..f70f5c6`. The 25 commits between the previous handoff
(`2026-08-27-001-hetzner-deploy-eof-and-err.md`, at `8c0b150`) and
`3a6834c` -- scraper fixes, deploy changes, UI tweaks -- are **not**
covered here; this batch is one continuous thread and documenting the
rest from the outside would have meant guessing.

Test suite: 1032 -> 1039 assertions. Note it does **not** load
`news.arc`, so nothing here validates the comment-cache change; that was
verified by simulation against the real function bodies, and production
is its first real exercise.

## Commits

| sha | what |
|---|---|
| `55a88e5` | arc0.lisp: `globals`, `global-sizes`, and `object-size`'s blind spots |
| `17ed281` | arc0.lisp: `retainers`, `retaining-path`, `heap-big`, `deref` |
| `2dc50ca` | arc0.lisp: scan every heap space when searching for retainers |
| `2e9c483` | arc0.lisp: drop array dimensions when bucketing `heap-hist` |
| `e2fa90a` | json.arc: combine utf-16 surrogate pairs in `from-json` |
| `2d14efc` | arc.arc: fix incorrect nil arg to `readc` and `readb` |
| `718ca9d` | arc0.lisp: rework read*/write* to take exactly one arg |
| `3a36d3e` | arc0.lisp: define `writebytes` |
| `2fef91f` | news.arc: store cached comment bodies as utf-8 bytes |
| `e380b70` | arc.arc: load `reload.arc` last on every reload |
| `f70f5c6` | news.arc: no longer wipe `comment-cache*` each reload |

## Why

The perf bar read `2,319,986,000 total bytes`, up from ~1.3GB the day
before. It accounted for 673MB of that -- items 642.79MB, users 30.66MB,
votes 0.24MB -- and nothing could say where the other 1.6GB was.

Note that not all of the growth is a leak: `items*` fills lazily, and was
at 371,596 of 462,293 items when this started.

## 1. Forward tools, and what they were getting wrong

`object-size` and the new `global-sizes` walk **forward** from a root:
given `comment-cache*`, what does it hold? `object-size` had two blind
spots that made its answers wrong rather than merely incomplete.

**It recursed down cdr spines.** A 300k-element list blew the control
stack long before it ran out of heap, and news.arc holds lists that long.
Now iterative.

**It never looked inside closures.** `primitive-object-size` of a closure
is ~32 bytes -- a header plus one word per captured value. So *every*
`defmemo` and `defcache` in the image sized as 32 bytes, because their
caches live only in a closed-over variable and nothing else points at
them. A memo with 2000 entries went from 32 to 74,656 bytes once
`do-closure-values` was walked.

`global-sizes` shares one `visited` table across the whole scan, so an
object reachable from two globals is charged to whichever is walked first
and the totals partition the reachable heap instead of double-counting.
Globals are walked in name order so two snapshots diff cleanly -- which
is the actual use, since one snapshot only tells you `items*` is big.

It is expensive: the visited table grows to one entry per live object, so
on a multi-gigabyte image expect it to add a gigabyte of its own. Run it
off-peak.

## 2. `heap-hist` was under-reporting the heap by 1.5GB

This is the most transferable thing in this batch.

`heap-hist` bucketed on `type-of`, which calls a 60-character string a
`(simple-array character (60))` and a 61-character one a *different type
entirely*. Strings therefore shattered across thousands of length
buckets. On the live image the top 30 rows by bytes summed to **795MB
against a 2.32GB heap**: no single string length was ever large enough to
rank, and the fourteen length buckets that did make the cut held 1.24
million string objects between them.

The tool confidently reported that the heap was mostly conses and hash
tables. That is simply what you see once every string has been divided
into a thousand pieces.

Arrays now bucket by element type, everything else `type-of` returns as a
list specifier by its leading symbol. Its tables are also keyed `equal`
now rather than `eq`, since list type specifiers are never `eq`.

**Nobody has re-run it since the fix.** The 1.5GB is still unexplained.

## 3. Backward tools: `retainers`, `retaining-path`, `heap-big`

The forward tools cannot answer "who is holding this?", and `heap-hist`
names the type eating the heap, never the owner. These walk backward.

* `(retaining-path x)` -- the chain from a named global down to `x`, root
  first, as labels. Uses `sb-vm::map-referencing-objects` a level at a
  time, stopping at the first global.
* `(heap-big [n] [min-bytes])` -- the largest individual live objects as
  `(bytes label ref)`. This is the way *in*, since `retaining-path` needs
  an object and `heap-hist` only gives you a type. `ref` is a weak
  pointer so the result list is not itself a retainer of everything in
  it; `deref` turns one back into the object.
* `(retainers x)` -- labels for everything directly referencing `x`.

Chains are made of labels rather than objects, so printing one at the
repl cannot dump a 400k-entry table to a terminal.

A full heap scan is ~0.03s per 430MB, so this is seconds, not minutes --
much cheaper than `global-sizes`.

### Three bugs, all "the search finds itself"

A naive version of this returns confident garbage. All three had to be
fixed before it gave a single true answer:

1. **`map-referencing-objects` closes its own callback over the target**,
   and hands that closure back as a referrer of *every* object you ask
   about. Filtered by code component, since the closure is anonymous.
2. **It walks *allocated* objects, not live ones.** Each level's dead
   scan results were still sitting in the heap pointing at everything the
   next level was about to ask about. Hence a full gc *per level*, not
   just once up front.
3. **The visited table, its pairs vector, the frontier spine and every
   node chain hanging off it** all reference objects under search. They
   go into the visited set, which doubles as the skip set.

Before these, a string plainly sitting in a global table reported ten
levels of anonymous closures.

`2dc50ca` is a fourth of the same kind: the scan passed `:dynamic`, but a
referrer can sit in static, immobile or read-only space, and scanning
only the dynamic heap reported such an object as retained by *nothing* --
which reads exactly like the "pinned by a thread stack" case that a
length-1 chain is supposed to mean.

### What it said about the live image

```
7130352  (vector 891291)   (global items*)         (table 373536)
2673904  (vector 334235)   (global dc-usernames*)  (table 148539)
2673904  (vector 334235)   (global comment-cache*) (table 159737)
2673904  (vector 334235)   (global uid->user*)     (table 148544)
```

Every one resolved to a named global in seconds. Also worth knowing:
671,835 hash tables and 672,163 mutexes, i.e. roughly one arc object per
table plus its mutex. Per-table overhead is ~516 bytes (131 table + 208
pairs vector + 177 index/next vectors) before any content -- **~347MB**
at that count. Structural, not a leak, but it is a third of what the
histogram accounted for.

## 4. `comment-cache*` as utf-8 bytes

`comment-cache*` holds one rendered comment body per comment id, never
pruned, bounded only by the comment count. It was at **159,737 entries**
and climbing, and appears nowhere on the perf bar.

The bodies were `(simple-array character)`, which SBCL stores at **4
bytes per character**. There is no utf-8 string type in SBCL and no way
to make one: there are exactly two string representations, and the width
is baked into the widetag.

| | bytes/char | holds |
|---|---|---|
| `simple-base-string` | 1 | `base-char` only -- `base-char-code-limit` is 128 |
| `(simple-array character (*))` | 4 | full unicode, ucs-4 |

`simple-base-string` was considered and rejected. It is a real string
(`stringp` is true, so `arc-type` returns `string` and it is a drop-in),
but it is all-or-nothing per string: `eschtml` escapes only `< > & " ' /`,
so a single smart quote, em-dash or accented username in a body forces
the whole thing back to 4 bytes/char.

utf-8 octets win regardless of content -- measured 2032 bytes for 2001
characters containing an em-dash, against 8032 as ucs-4.

### The body is never decoded

The obvious version decodes on every cache hit. Don't: it measured
**34ms of `octets-to-string` on a 1600-comment item page** (against ~48ms
for the whole page), plus ~1600 transient 4-byte-per-char strings -- and
then `stream-write-string` immediately re-encoded them to the *same*
octets. It also inverts the cache's stated purpose, which the comment
above it gives as generating less garbage.

Instead the octets go to the socket verbatim via `writebytes`. The
accepted-client stream is bivalent (`:element-type :default`), and
`respond` binds it directly with `w/stdout str`, so there is no
intermediate buffer. A cache hit now does **strictly less** work than
before this change: it skips the stream's own `string-to-octets` too.

`recache-comment` uses `lets`, which returns the bound variable, so the
miss path hands `writebytes` the bytes it just stored.

### `astree` is why this is safe

`should-cache-comment` requires `astree`, and this is now documented in
news.arc. Two reasons, and the first is the real one:

* `recache-comment` always generates with `astree t`. A tree render
  carries root/prev/next links and an anchored whenceid where a flat
  listing carries context and flag links, so a listing handed a cached
  body would show the wrong navigation.
* It also keeps the cache off the `tostring` paths. The pages `newscache`
  buffers into a string, and the story-refill endpoint, all render with
  `astree nil`.

Nothing depends on the second for correctness -- `writebytes` decodes
rather than signalling when handed a string stream -- but it is the
difference between handing the socket bytes verbatim and paying a decode.

### Deploy consequence of `f70f5c6`

`comment-cache*` was briefly initialized with `=` so a reload would clear
entries left from when the slot held a string. `f70f5c6` put `or=` back,
so **the cache survives the reload and the pre-deploy string bodies stay
in it**.

That is safe, and was tested: `write-sequence` of a character string to
the bivalent fd-stream just writes characters, so a stale string body
renders correctly and is replaced with bytes the next time its key
changes. The tradeoff was one-time cleanliness against wiping a
159k-entry cache on *every* future reload.

## 5. `writebytes` and the read*/write* arity change

`writebytes` (`3a36d3e`) writes an octet vector with `write-sequence`,
falling back to decoding when the port is not an `sb-sys:fd-stream`.
`stream-element-type` cannot be used to discriminate -- it reports
`CHARACTER` for both a bivalent fd-stream and a string-output-stream.

`718ca9d` reworked `readc`/`readb`/`peekc`/`writec`/`writeb` from `&rest
args` to `&optional port`. Worth knowing why this broke the build
(`2d14efc` fixed it): the bodies only ever read `(car args)`, so they
were unchanged -- but `&rest` *accepts* any arity, and `allchars` and
`allbytes` were calling `(readc str nil)` with a second argument that was
being silently dropped. `&optional` made that a hard
`invalid number of arguments: 2` at the call, before the body ran.
`filechars` goes through `allchars`, so it took out the whole suite.

That second `nil` was arc's eof-value convention, which `sread` still
implements. It was dropped at the two call sites rather than given
meaning; if `readc` ever wants an eof argument, that is where to look.

All `.arc` files were audited for over-arity calls by reading them with
arc's own reader (car/cdr recursion, so dotted macro arglists don't skew
it), not by grep. Clean.

## 6. `from-json` and utf-16 surrogate pairs

`json-parse-unicode-escape` read exactly four hex digits and coerced them
straight to a character, so a character outside the bmp -- which arrives
as a **pair** of escapes -- parsed as two halves of a character.

The halves are worse than wrong: a surrogate is not a unicode scalar
value, and SBCL's `character` will hold one but utf-8 cannot encode it.
So nothing failed until something wrote the string back out, and then
`string-to-octets` signalled nowhere near the parse that caused it.

Pairs are now combined; an unpaired surrogate becomes U+FFFD, which
encodes. `json-parse-trailing-surrogate` **rewinds** when what follows a
high surrogate is not the low half, so a stray one does not swallow the
text after it -- that is the easy thing to get wrong.

This is latent, not live: the only caller of the parser is `load-json` on
the local notify config, and the scraper fetches html rather than the
firebase api. It stops being latent the moment the scraper switches to
the api, where emoji arrive exactly this way.

## 7. `reload.arc`

A place for code that should run once against the live image after the
next reload. `loaded-files` moves it to the end of the load order.

`rem`, not `pull`, deliberately: `pull` is `(wipe (mem ...))` and would
strip it from `loaded-files*` on each call, so `loaded-files-changed`
would stop watching its mtime while `load` kept putting it back.

Being last also contains the damage when it is broken or missing --
`call-quietly` only muffles style-warnings, so an error still escapes,
but by then every other file has loaded.

## Status

`./sharc test.arc` => **1039 passed, 0 failed**. Tree clean and pushed to
`origin/main`.

Deploy is the push: `update-repo.sh` polls origin and `git reset --hard`s,
which bumps mtimes and trips `maybe-reload`. No restart, so the
accumulated heap survives -- which is what you want, since it is the
evidence. Checked for this batch: no defstruct changed shape, so
`reload-runtime` will not refuse; and it runs before the `.arc` files
load, so `writebytes` exists by the time `news.arc` wants it.

One pre-existing wrinkle worth knowing on any deploy: if `arc0.lisp`
fails to compile, `reload-runtime` returns nil but `reload` loads the
`.arc` files anyway.

## Open follow-ups

* **Re-run `(heap-hist)`.** Nobody has seen an honest histogram yet --
  every reading predates `2e9c483`. The 1.5GB is still unexplained, and
  character strings are the obvious suspect.
* `comment-cache*` has no perf-bar line. `items*`, users and votes do.
  It was at 159,737 entries and invisible.
* The `defmemo` caches -- `item-url`, `lightweight-url` -- never evict.
  `memo` has no bound. These were invisible to `object-size` until
  `55a88e5` and have never been measured.
* The ~64 bytes/refresh leak from
  `2026-06-09-001-fnid-content-dedup.md` is still open and unrelated to
  any of this.
* `comment-cache*` bodies are pure render output. If they are mostly
  ascii, `simple-base-string` would have been equivalent; the octets were
  chosen because they win on non-ascii too. Worth measuring what the
  ascii fraction actually is before drawing conclusions from the ratio.
* The scrape threads are throwing `SSL connect to news.ycombinator.com:443
  failed: SSL_get_error=2` in a loop and dumping full backtraces into the
  repl. Unrelated to memory, but it is noise in the pane.
