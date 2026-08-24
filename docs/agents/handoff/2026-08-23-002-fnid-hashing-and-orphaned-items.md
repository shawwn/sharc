---
name: orphaned items and the fnid isotable
description: Chased two reported anomalies to root cause. `(len comments*)` being a third of the comments in `items*` was `w/loading-items` using `do1`, so any error in the body skipped the insert and stranded the whole batch permanently; the admin item page taking 3.1s was `fnkey->fnid*` being an isotable whose psxhash gave every fnid key the same value. Also records three negative results (CL `loop` vs tail recursion, a `zeropad` rewrite, and a lost-update race that turned out not to exist) and two unfixed findings in the scraper.
type: project
---

# Handoff: orphaned items and the fnid isotable (2026-08-23)

Continues `2026-08-23-001-item-page-render-speedups.md`, which covers the render
work itself (explicit-flush, native `eschtml`/`urlencode`/`text-time`, the
comment cache rebuild, and the fnid fix as its section 4). This one is about
the two anomalies the user spotted afterwards, and about several things that
were measured and *not* changed.

Everything here was measured against a `cp -al` hardlink shadow of `arc/` under
the scratchpad, with test servers on ports 1235/1236. `writefile` is
atomic-rename, so a hardlinked shadow is safe to write to and the live server on
1234 was never touched.

## 1. Items were vanishing from stories* / comments*  (the real bug)

Reported as:

```
arc> (len stories*)                          2680
arc> (len (keep astory (vals items*)))       9118
arc> (len comments*)                        127924
arc> (len (keep acomment (vals items*)))    360658
```

Both lists holding roughly a third of what `items*` had.

**Cause.** `w/loading-items` parks every item loaded inside it in
`(the loaded-items)` and only merges them into `stories*`/`comments*` when the
scope ends -- and it ended with `do1`, which does not survive a non-local exit:

```arc
(do1 (do ,@body)
     (only&insert-items (the loaded-items)))   ; skipped if the body throws
```

One error anywhere in the body stranded the entire batch. There is no recovery
path: `(item id)` short-circuits on the existing `items*` entry, so
`register-item` never runs for those ids again. They are orphaned for the life
of the process.

Reproduced directly on the shadow data:

| | items* | stories* | comments* |
|---|---|---|---|
| clean `w/loading-items` | +1000 | +17 | +983 |
| one whose body threw | +1000 | **+0** | **+0** |

This reaches every caller: `each-item` / `latest-items` (so `/newest`, `/best`,
`gen-topstories`), `offspring`, `visible-family`, `commentlink`. On a scraped
mirror a single dangling kid id is enough to throw, and a whole thread's worth
of comments goes with it.

Fixed by the user in `2f7df11` as `after` instead of `do1`. Verified: orphans
go to zero. `w/the` was already unwind-safe, so `loading-items` itself does not
leak -- only the insert was being skipped.

### Wrong turns worth not repeating

Three hypotheses were tested and disproved before the real one:

- **`import-scrape!` clobbering `stories*`.** It really does
  `(= stories* stories)` with only the current pass's front ids
  (`scrape.arc:939`), and simulating it reproduces the *shape* of the anomaly
  exactly. But the user does not call `import-scrape!`, and it does not explain
  `comments*`, which is never assigned that way.
- **`merge-item-lists` dropping items.** It does not. 5,000 + 5,000 real items
  in, 10,000 out, all ids distinct. (It has a different bug -- see below.)
- **A lost-update race in `import-scraped-comments`.** The `seen` scan is
  outside `rank-lock*`, which looks like a read-modify-write hazard, but the
  `comments*` read that feeds `merge-item-lists` is *inside* the lock and
  `add-item` takes the same lock. A concurrent adder running through the whole
  190ms window lost nothing.

The diagnostic that actually worked was to instrument every path into `items*`
in isolation and confirm each one keeps the two in step -- startup, on-demand
`(item id)`, inside `w/loading-items`, a page render -- and then look for what
was different about the scopes that did not.

## 2. `merge-item-lists` is given inputs sorted three different ways

Unfixed, and reported to the user rather than changed, because the intended
sort key is a design decision.

`merge-item-lists` merges with `(compare < !id)` -- ascending by id. But:

- `items-by-type` hands it buckets sorted `(compare > !id)`, descending by id;
- `stories*` / `comments*` are maintained by `insert-sorted` with `compitem`,
  which is `(compare > !time)`, descending by *time*.

All three disagree, so the merge is operating on reverse-sorted input. The
comment on it ("The resulting list is in desending order") is wrong -- measured
on real items, the result is ordered by neither time nor id. Nothing is lost,
but `stories*` and `comments*` get progressively scrambled, `insert-sorted`
then inserts at meaningless positions, and anything reading a prefix
(`/newcomments`, `latest-items`' early `break`) is reading from a shuffled list.

## 3. Two unfixed findings in the scraper

- **Import husks.** `comment-from-scraped-comment` does
  `(or= (items* c!id) (inst 'item 'id c!id))` *before*
  `(= it!by (get-user-uid ...))`, which asserts when the author has no local
  profile. `call-reporting` swallows it and `only&out` drops the item, but the
  `items*` entry is already there. Confirmed: items* 15,279 -> 15,280,
  comments* unchanged. The husk has `type` and `by` both nil, so it does *not*
  show up in a `(keep acomment ...)` count -- it was not the cause of section 1,
  but it does accumulate.
- **`import-scraped-comments` is O(n) per imported item.** At 127,924 comments
  the `(each c comments* (set (seen c!id)))` scan is 96ms and the
  `merge-item-lists` is 91ms, the latter holding `rank-lock*` -- the same lock
  every page render takes through `add-item`. With seven scrape bgthreads that
  is a lot of contention.

## 4. Negative results

Recorded so nobody re-runs them.

### CL `loop` instead of the `rfn` tail call

`while` / `whilet` / `loop` expand to a self-call through `rfn`, which is
`(let name nil (assign name (fn ...)))` -- a mutable lexical, so `ac-call`
emits `(arc-call1 v ...)` and SBCL cannot turn it into a jump. It is a genuine
funcall per iteration.

Prototyped the alternative properly: a `%while` special form in `ac`
(2 lines in `arc1.lisp`) plus `(mac while2 (test . body) (w/break (%while ...)))`,
semantically identical including `break` accumulation. Best-of-9, three runs,
byte-identical bodies:

| body | `while` | `while2` | |
|---|---|---|---|
| bare `i++` | 30.2 ns/it | 25.1 ns/it | 17% faster |
| two assignments | 38.9 | 40.1 | 3% *slower* |
| `(string i)` | 162.0 | 163.8 | ~0 |

Worth ~5ns/iteration and only when the body does nothing; it reverses as soon
as the body touches variables (probably because in `while2` the body sits inside
`w/break`'s `ccc` closure so the loop variables become closed-over cells anyway,
where in `while` the loop variable is an `rfn` parameter). Not pursued.

Note the mechanism blocker: this cannot be done as a macro. `#'` runs
`cl-quoted` over the whole form and upcases every symbol, so arc subforms cannot
be embedded inside a CL `loop`. It has to be a special form in `ac`. Same wall
that stopped `eschtml-fast` from calling `eschtml-char` (see 001).

**If iteration mechanics are ever worth attacking, `each` is the target, not
`while`:** `each` 41.8 ns/elt vs a hand-written `while` cdr-walk at 23.3. The
`across` closure call per element costs ~18ns, three to four times what the
`while` change would buy.

### `zeropad` via `format`

Proposed as `(#'format nil "~@{n},'0D" i)`. The atstring trick works and does
build `"~2,'0D"`, but it is **3x slower** (1.32us vs 0.45us) because a control
string built at runtime cannot be compile-time-compiled, and it is **wrong for
string arguments**: `(zeropad "a")` is `"0a"` today and `"a"` under `format`,
because CL's `~D` falls back to `~A` for non-integers and drops the padding.
`urlencode1` calls `(pr:zeropad (as!string b 16))`, so byte 10 would emit `%a`
instead of `%0a`.

### How much `text-time-fast` is actually worth

| | CL `format` | pure arc |
|---|---|---|
| logged out, cache on | 39.1 ms | 39.2 ms |
| uncached (admin / first view) | 99.6 ms | 112.0 ms |

Nothing on the common path -- cached comment bodies never call it. ~11% on the
uncached path only. It is the weakest change in 001 and the cheapest to revert.

The user's simplification of `text-time1` (drop the `rev`, destructure
`timedate` as `(s m h D M Y)`) is correct and ~12% faster; it landed, and the
comment above it was updated since it still described the removed `rev`.

## Gotchas for anyone measuring in this tree

- **Do not name a scratch variable `fresh`.** It is a real function
  (`arc.arc:1413`) used by `split`, and clobbering it produces a baffling
  `"www.seangoedecke.com" is not of type (UNSIGNED-BYTE 45)` deep inside
  `canonical-url`. Cost twenty minutes chasing a phantom bug in `sitename.arc`.
- **BSD `sed` has no `\b`.** `sed -i '' 's/\bfresh\b/x/g'` silently does
  nothing, which is how the above survived a rename.
- **The first render of a thread is not comparable to later ones.** `delayed`
  marks comments `mature` on first evaluation, so recent ones render as
  pseudo-text on render 1 and normally on render 2. Warm twice before diffing.
  This is also why a browser's first load of an item page reads ~250ms while
  curl on the same warm server reads ~50ms.
- **Absolute microbenchmark numbers drift between scripts** (GC pressure --
  `zeropad` alone read 0.45us in one script and 1.26us in another after 800k
  allocating calls). Only compare within a single run.
