---
name: fnid content dedup
description: Reinstates the content-keyed fnid dedup experiment that 2026-06-04-003 recorded as removed. fnids are now memoized by (user, op, GET args, scopekey) through fnkey->fnid*/fnid->fnkey* (an isotable), so identical links reuse one fnid across renders. Also covers the thread-locals leak fix, the fnid symbol-interning fix, and an still-open 64-byte/refresh leak.
type: project
---

# Handoff: fnid content dedup (2026-06-09)

> Reinstates the `fnkeys*`/isotable experiment that
> [`2026-06-04-003-byte-vectors-utf8-isotable`](2026-06-04-003-byte-vectors-utf8-isotable.md)
> explicitly recorded as **removed** ("isotable is currently unused --
> a fnkeys* experiment ... was the motivation but was removed"). It is
> back and in use. If you read that older note, this supersedes it.

## Commits this session

| sha | what |
|---|---|
| `100b91c` | srv.arc: free per-request thread-locals when the request thread ends |
| `5ba6c92` | srv.arc: never treat localhost as abusive |
| `7f41403` | arc.arc: always register the disk saver in fromdisk |
| `6c29bfe` | arc0.lisp: add heap-hist, a live-object histogram by type |
| `c6b7c61` | news.arc: show post-GC memory in bytes on the perf bar |
| `df7caa4` | app.arc: fix indentation of the rlinkf line in urlink |
| `96332f9` | srv.arc: dedup fnids by request and captured-scope content |

The dedup feature is `96332f9` (+ the `longpage` line in news.arc). The
rest are independent fixes that happened alongside it.

## What the dedup does

Before, every render of a link called `(sym (rand-string 22))` and minted
a brand-new fnid, so reloading a page filled `fns*` with duplicate
closures that only `harvest-fnids` eventually reclaimed. Now an fnid is
keyed by its **content** and reused when that content recurs.

The content key (`fnid-key`) is:

```
((get-user) req!op (when GET (reassemble-args req)) <scopekey>)
```

and `scopekey` is `(name (scopevals scope) 'body)`:

- **name** -- which macro made the link (`'flink`, `'w/rlink`, `'aform`, ...).
- **body** -- the quoted source of the link's handler/expr. This is what
  distinguishes two textually-different links at the same call site.
- **scopevals scope** -- a scrubbed snapshot of the in-scope lexicals the
  closure captures, so two links with identical bodies but different
  closed-over data (e.g. different story items) get different ids.

`new-fnid` memoizes through two globals:

- `fnkey->fnid*` -- an **isotable** (deep-structural keys via `arc-is2` +
  `psxhash`; see 2026-06-04-003). Maps a content key to its fnid. Needs to
  be an isotable because the key contains tables/conses that a normal
  `equal` table would compare by identity.
- `fnid->fnkey*` -- the reverse map, so `forget-fnid` can evict both.

## scopevals / scrub-scopeval / ignored-scopeids*

`scopevals` walks the bare `scope` reflection (the `(name getter setter)`
triples for every in-scope lexical; see 2026-06-04-003's `scope`/`%scope`),
calls each getter, and keeps the ones `valid-scopeval` allows.

`scrub-scopeval` reduces each captured value so the key is small, stable,
and serial-comparable:

- a **table with an `'id`** collapses to `(obj id <id>)` (story/comment/
  profile items), so the key holds the id, not a deep copy.
- the **request table** (`(the req)`) is dropped.
- a **closure** (`fn`) becomes `nil`.
- a value off `valid-scopeval`'s allowlist (string/vector/sym/cons/int/
  num/char/table) is dropped entirely.

`ignored-scopeids*` excludes specific lexical bindings from the snapshot.
This is essential for any **per-request-varying** binding, otherwise its
value changes every request and the link never dedups ("churn"). Two are
registered, both at macroexpansion of the binding's `w/uniq` gensym:

- the `defop-raw` request timer (`(let t1 (msec) ...)`).
- `longpage`'s start-time `(let gt t1 ...)` in news.arc.

`longpage` is the **only** page macro that threads `(msec)` into the
lexical scope of an inline `. body`; `fulltop`/`shortpage` take no time
param, and `listpage`'s `t1` never reaches its links because they render
inside helper functions (`votelinks`, `display-story`), which are
lexically isolated by the function boundary. So those two ignores cover
all the churn there is.

## Bookkeeping rework

- `fns*`, `fnids*`, `timed-fnids*` are now **id-keyed tables** (were a
  table + two push-lists). `fnids*` value is `(created user)`,
  `timed-fnids*` value is `(created lasts user)`. An id lives in exactly
  one of the two (each setter wipes the other). Re-registering a deduped
  id overwrites rather than appending, so no duplicate rows / no
  stale-timestamp early expiry.
- `forget-fnid` wipes all three tables **and** both fnkey maps, so nothing
  leaks when an id is reclaimed.
- `harvest-fnids` (gated on `fns*` exceeding `fnid-harvest-max*` = 50000)
  first drops time-expired ids via `dead-fnids` (timed past `lasts`, plain
  past `fnid-hours-max*` = 6h), then if still over, culls oldest-first
  (`fnids` sorts `fnids*` by `created` via `sortable`'s new key arg).
- **gen-fnid keys `fns*` by the random string itself, not an interned
  symbol**, and dispatch reads `(fns* arg!fnid)` directly (was
  `(fns* (sym arg!fnid))`). This removed a real leak: `sym` interns into
  the `:arc` package and interned symbols are never GC'd, so every minted
  fnid used to leak a symbol forever, and `(sym arg!fnid)` on a bogus
  deadlink interned attacker-controlled garbage (a memory-exhaustion
  vector). String keys close both.

## Known tradeoff (documented inline, fail-open)

Commented at `scopevals` and `fnid-key` in srv.arc:

- closures scrub to `nil` and off-allowlist values are dropped, so two
  links differing *only* by such a value collapse to one fnid;
- POST-rendered links aren't keyed on args.

Both are **over-collapse** risks and the snapshot **fails open** (assumes
two links are the same when it can't prove otherwise). In practice the
quoted body plus op/user/args distinguish them, and fnids are scoped per
user (`get-user` is in the key), so a collision is bounded to one user's
own equivalent actions, not cross-user. If it ever bites, the fix is to
make `scopevals` **fail closed**: bail to a fresh `gen-fnid` the moment it
hits a value it can't represent. We chose fail-open deliberately; the
fail-closed guard is a clean separate change if wanted.

The POST-args omission is, on analysis, a redundancy rather than a hole:
a link whose behavior depends on the page's args must close over them
(the fnid-invocation request carries no such args), and closed-over values
are already in the scopekey. The GET args are belt-and-suspenders.

## Leaks fixed, and one still open

- **~4kb/refresh (fixed, `100b91c`):** `respond` stashes req/ip/me in
  `thread-locals*` keyed by the current thread, and each request runs on
  a fresh thread, so the entry (dead thread object + locals table) leaked
  forever. Now wiped when the request thread ends -- in th1's `after`
  cleanup and in the watchdog th2 after it breaks th1 (the wedged case).
  `(= (tab k) nil)` calls `remhash` (arc0.lisp `sref`), so it truly
  deletes.
- **per-fnid symbol leak (fixed):** see gen-fnid string-keying above.
- **~64 bytes/refresh (STILL OPEN):** reproduces on `/?perf=t`, a page
  that mints no fnids, so it is *not* fnid- or symbol-related. Not yet
  localized. Tooling is in place: `(heap-hist)` (arc0.lisp `6c29bfe`)
  does a full GC then returns the top live-object types; the perf bar
  shows post-GC bytes (`c6b7c61`). Diff `(heap-hist)` across N refreshes
  to see which object type grows. Leading unconfirmed suspects: the
  `optimes*` enq-limit queue during its first 1000 requests (bounded, so
  should plateau -- rule it out first), or `sb-thread:thread` objects
  from the 2 threads/request not being reclaimed.

## Status

`./sharc test.arc` => **413 passed, 0 failed**. Working tree clean,
7 commits ahead of where the session started (`fa3cf37`).

## Open follow-ups

- Localize the 64-byte/refresh leak with `heap-hist` (above).
- Decide whether to harden the scope snapshot to fail-closed (above).
- Optional: the ratio-cull path in `harvest-fnids` only trims `fnids*`
  (plain), not `timed-fnids*`; timed ids are reclaimed only via
  `dead-fnids`' `lasts` check. Fine while plain fnids dominate.
