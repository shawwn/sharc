---
name: Closing the concurrency audit
description: Every finding in the concurrency-races doc is fixed, plus six more found while fixing them; three new locks (submit 10, vote 11, rank 12); the phantom-key bug in maphash; and the measurement habits that repeatedly overturned confident reasoning.
type: project
---

# Handoff: Closing the concurrency audit (2026-08-09)

## What was accomplished

Started from `docs/agents/plans/2026-08-03-001-concurrency-races.md` with
findings 5, 6, 7 and 8 open, and finished with **every finding on that page
fixed** — the original eight, plus six more (9 through 14) discovered while
fixing them. The doc was updated after each one, so it is the primary
reference; this handoff covers what a fresh agent needs that the doc does not
say.

Roughly thirty commits on `lock-levels`, from `3b62dc0` to `3baca02`. The
branch is **63 commits ahead of `main`** and has not been pushed.

Three new locks, all in `arc.arc`'s table (which `1a5b30e` made the single
source of truth — keep it in sync):

| level | lock | protects |
|---|---|---|
| 10 | `submit-lock*` | the three `process-*` submit handlers |
| 11 | `vote-lock*` | `vote-for` / `unvote-for`, striped 64 ways per user |
| 12 | `rank-lock*` | `stories*`, `comments*`, `ranked-stories*` |

Beyond the races, two things landed that are not concurrency fixes and are easy
to miss in the log:

- **`w/appendfile` never appended.** `outfile` (`arc0.lisp`) compared its mode
  argument against the *string* `"append"` while `w/appendfile` passes the
  *symbol*. Every open truncated, so every log file since the port held exactly
  one line — 40 of the 42 files in `arc/logs/` were one line covering a whole
  day. `2f39dcc` fixed the test with `arc-sym=`.
- **The front page ranks past 180.** `gen-topstories` was capped at 180, which
  capped `/news?p=N`. Now it ranks every story among the 10000 most recent
  items, with a trim in the debounce thread and batched loading at boot
  (`219c3ca`).

Finding 4's class was closed last, in `3baca02`: `save-topstories` and
`save-admins` were the only two callers still handing a caller-evaluated
snapshot to `writefile`/`dispfile` rather than going through `save-table`. Note
`a58b79f`'s message claims debouncing `save-topstories` retired that race
because a single writer cannot race itself — wrong, there are three writers
(the bgthread plus two in `scrape.arc`).

## The one to read first: finding 13, phantom keys

`maptable` walked with a bare `maphash`. When another thread **inserts a new
key**, the table rehashes, and a walk already in flight can visit storage slots
mid-move and yield `0` — SBCL's fill value for an unused key slot, a
"key" that was never in the table. `keys`, `vals` and `tablist` were all
built on it.

It surfaced as a crash in the `update-avg` background thread during a scrape
(`(profile 0)` returning nil, then nil being applied), but **the crash is the
harmless half**. `tablist` feeds `save-table`, so a save racing an insert can
write a `(0 0)` row into `hpw`, `cooks` or `uids`. That row survives the round
trip, loads back as a genuine key, and `(downcase 0)` errors — so
`register-accts` throws and the server will not boot. Silent at write time,
fatal at read time, arbitrarily later.

Two things about the trigger that took measurement to establish:

- It needs **growth** (a rehash to a larger table). Value updates on existing
  keys produce nothing; insert-and-remove churn at constant size produces
  nothing. My first two measurements of "churn causes phantoms" were wrong —
  see the detector note below.
- `e221ed8`'s striped save lock does **not** help. It serializes savers against
  each other, not against a thread inserting into the table being snapshotted.
  The two problems look adjacent and are unrelated.

## Key decisions

**Two mechanisms in `maptable`, on purpose.** `tabkeys`/`tabvals`/`tabpairs`
snapshot under the table's own SBCL mutex; `maptable` validates on read
(re-fetch the value, skip when nil). The builders want a consistent
point-in-time view and are cheap to copy; `maptable` must not allocate a
list nor hold a mutex across a walk, because `items*` may reach tens of
millions of entries. Someone will want to unify these. Don't.

**`maptable`'s validation depends on `sref` remhashing nil**, which is what
makes `(gethash k table)` a liveness test. If a live entry could ever hold nil,
`maptable` would silently skip every one. Its contract is now *may skip, may
duplicate, never fabricates*.

**Filtering stays outside the table lock.** Pushing the test into `tabkeys`
looks like a free allocation saving and was tried. It runs arbitrary arc code
under the table mutex, and the real tests take `place-lock*` (`loaded-users`'
predicate reaches `profile`'s `or=`) and do disk I/O (`load-prof`'s `temload`).
That inverts the writer's `place-lock*`-then-mutex order, and
`arc-check-lock-level` **cannot see SBCL table mutexes**, so the failure is a
hang rather than the loud violation that caught every other ordering mistake on
this branch. This is now a design note in the doc; it is the most reusable
thing here.

**The vote fix is a lock, not an `or=` claim.** The obvious fix — claim
`(voted i)` with `or=` at the top of `vote-for`, testing with `id` rather than
`is` — is wrong on its own. The effects list is built *as `vote-for` runs*, so
moving the claim to the front lets an `unvote-for` see a vote whose `vote!5` is
still empty, subtract nothing, wipe it, and leave `vote-for` to apply the score
and karma anyway: orphaned effects with nothing left to undo them, which is
worse than the double vote. Leaving both bodies untouched and wrapping them in
a striped per-user lock makes the pair atomic in all three directions (two
votes, two unvotes, vote racing unvote). `id` really is required if anyone
revisits the `or=` approach — two simultaneous votes build structurally equal
lists, measured as `id-winners=1` against `is-winners=2`.

**`submit-lock*` is deliberately wide.** It wraps the form handlers rather than
check-plus-create, holding across half a dozen file writes, which caps
submissions near a hundred per second. That is far above what this site sees and
it bought a four-line fix. The narrower version (lock across the dup check and
the in-memory publish, release before the saves) is written up in the doc if
`optimes*` ever says it is needed; `28d92fc` made it cheaper by moving the
`items*` publish to the front of every `create-*`.

**`add-item` versus `put-item`.** `put-item` is `insortnew`, whose
`reinsert-sorted` rebuilds the entire tail through `rem` even when there is no
duplicate: 11.8 ms per insert into a 50000-element list against `push`'s 0.008,
and it exhausts the control stack past 300000. `add-item` uses `insort`, which
shares the tail — 0.018 ms flat, survives a million. Use `add-item`
wherever the id is known new.

## Measured

Numbers that decided something, so they need not be re-derived:

```
adjust-rank, by ranked-stories* length   180: 0.036 ms   1000: 0.183   10000: 2.17
tablist, 20000 entries                   before 1.37 ms   after 0.10 (13x faster)
batched load vs one add-item each        2000: 404 -> 25 ms   5000: 2411 -> 66 ms
fnid harvest under concurrency           8 staggered: 103 reclaimed   8 sequential: 800
save-optime queue drop (barrier-synced)  lost (82 1 26 0 47 69) of 100 -> all 0
double vote                              score=2 votes=2 -> score=1 votes=1 (5/5)
srvlog interleaving                      11 damaged lines per 4000 -> 0
save-topstories per story vote           0.267 ms of adjust-rank's 0.612
```

## Method that repeatedly changed the answer

This is the part most worth carrying forward. Several confident claims —
mine — were overturned by measuring them:

- **Always check a regression test fails against unfixed `HEAD`.** A test that
  can only pass is worthless. `examples/locking/phantom-keys.arc` reports 251770
  phantoms against the unfixed tree and 0 with the fix.
- **Barrier-synchronise racing threads.** The first version of the
  `save-optime` test started threads without a barrier, reported 200 of 200 on
  the *unfixed* code, and proved nothing: start jitter lets the first thread win
  before the others check. With a barrier it loses up to 82 of 100.
- **Detect phantoms by type, not by a failed lookup.** A key that fails a lookup
  may simply have been removed after the walk started — ordinary staleness.
  Conflating the two overstated the damage by hundreds of thousands and produced
  two wrong numbers before the type check fixed it.
- **Claims that did not survive measurement**, recorded so they are not retried:
  the `(if (some [same elt _] seq) (rem ...) seq)` guard for `reinsert-sorted`
  is a wash on speed and does not lift the stack ceiling; concurrent fnid
  harvesters *under*-reclaim rather than over-cull; `put-item` is the wrong tool
  for known-new insertions.

## Things to watch

- **`arc.arc`'s lock table is authoritative.** Every level must be justified on
  both sides. Two constraints decide almost all of them: anything reaching
  `writefile` must stay **below 40**, because `writefile` takes `place-lock*`
  through `tmpname`'s `rand-string`; anything reached from a submission must
  stay **above 10**. `vote-lock*` at 11 and `rank-lock*` at 12 sit between them.
  Free: 1-9, 13-19, 26-29, 31-39.
- **`rank-lock*` correctness rests on every writer taking it**, because a
  bare-symbol `=` takes no lock at all — weaker than the `zap` it replaced.
  There are six: `ensure-topstories`, `gen-topstories`, `insert-items`, and
  three in `scrape.arc` (the import, `scrape-update-frontpage`, and
  `set-frontpage`). A seventh added without the lock silently reopens finding 2
  and nothing will catch it — `insert-items-drop.arc` races `insert-items`
  specifically, so it does not cover an arbitrary writer.
- **Hoist lock-free work out, keep the read of the place in.** `set-frontpage`
  had the whole rebuild outside `rank-lock*` and lost 40 of 200 concurrent
  inserts; moving only the `(map item ids)` and `memtable` out fixed it. This is
  the same rule that lets `gen-topstories` hoist its `rank-stories` call while
  `adjust-rank` cannot hoist its `reinsert-sorted`, and it is easy to get
  backwards because hoisting looks like a pure win.
- **`ranked-stories*` has no natural bound.** `put-item` inserts any story not
  already in it, `gen-topstories` only runs when the topstories file is missing,
  and `rerank-random` is commented out. The trim in the `topstories` bgthread is
  the only cap; `firstn 180` in `save-topstories` used to be, and only at the
  persistence boundary.
- **The two `10000`s in `news.arc` are unrelated** — one is `consider`
  (how many recent items to examine), one is the trim cap.
- **A story vote now holds `rank-lock*` for ~2.17 ms**, and `rank-lock*` is on
  the lazy-load path, since `insert-items` runs once per story per front-page
  render. Boot also lazily loads up to 10000 items. Both accepted, not fixed.

## Verification

```sh
for f in reentrancy lost-updates insert-items-drop phantom-keys; do
  ./sharc examples/locking/$f.arc
done
```

All four pass. `atomic-interleaved.arc` and `deadlock-place-then-atomic.arc` are
**expected to fail** — see `examples/locking/README.md` for why.

## Current state

Branch `lock-levels`, 65 commits ahead of `main`, unpushed. Working tree clean.

Open, and none of it is a race:

1. **An index for `items*`** — the largest item. `loaded-item-ids` is
   `(sort > (keys items*))`, backing four 300-second `defcache`s plus
   `should-ban-ip`. At tens of millions of items that is unusable however cheap
   the walk gets; it wants dead-items-by-site and items-by-ip maintained at
   `kill` and `register-item` time, the way `sitename->items*` already is.
2. **An iterative `reinsert-sorted`**, if `register-item`'s insertion cost
   or the control-stack ceiling on long lists ever matters.
3. **Generic coverage for `rank-lock*` writers.** `insert-items-drop.arc`
   races `insert-items` by name, so it caught nothing when `set-frontpage`
   arrived with the same bug. A repro that races an arbitrary writer of
   `ranked-stories*` would cover the class.

## Front-page sampling (`bfe572a`)

Landed after the first draft of this handoff, and worth its own note because
of how it went: five bugs, each one only visible after fixing the previous, and
four of the five invisible to reading.

`scrape-frontlog` fetches HN's `/news` every ten seconds, logs the ids to
`newsdir*/front/<date>`, and overlays that order onto `ranked-stories*`.
`parse-frontlog` reads a day back and divides sample counts by `6.0`, which is
why the pacing has to be a true ten seconds rather than a `defbg` interval —
an interval makes the period ten seconds *plus* the work, skewing every
duration.

The five, in the order they surfaced:

1. `(sleep (- 10 (since t0)))` goes negative when the fetch is slow. SBCL
   rejects a negative sleep, and `new-bgthread` only runs at
   `start-bgthreads`, so the thread would stay dead until a restart.
2. Overlaying by position (`cut` by `(len stories)`) duplicated any story
   already ranked deeper in the list — the normal case. Nothing downstream
   dedupes, and it persists through `save-topstories`.
3. `(mem _!id ids)` per element is 29.6 ms at ten thousand stories against
   thirty ids; a `memtable` is 1.6. It is held under `rank-lock*`.
4. Hoisting the rebuild out of the lock lost 40 of 200 concurrent inserts.
5. A throwing fetch skipped the sleep entirely: **13835 iterations per second**,
   hammering HN and the output locks. Fixed by putting the sleep in an `after`,
   which is unwind-protect, so it runs before the error reaches
   `call-reporting` at the bgthread level.
