# Concurrency Races Under Normal Usage

## Original Request

> see if you can think of any multithreading bugs under normal usage patterns.
> (multiple concurrent votes for the same item, multiple items submitted at the
> same time, multiple simultaneous edits, etc)

Audited on the `lock-levels` branch at `9b2175a`, after reading
`2026-08-02-001-remove-global-mutex.md`, `examples/locking/`, and the
`main..lock-levels` diff. This is the ranked findings list; the strategy and
principles live in the remove-global-mutex plan and are not repeated here.

Finding 1 (in part) was fixed in the working tree while this doc was being
written; it is kept because the reasoning is what justifies the fix, and
because it explains the class. Findings 2 and 3 have since been fixed as well,
and each carries the commit that fixed it. The hot-reload design note has been
rewritten: what it originally described as the working-tree fix was later
reversed, and that section now records the state as it stands.

## Scope note: what is *not* broken

Worth stating up front, because it narrows the search a lot:

- **`place-lock*` makes most read-modify-write macros atomic** — `++` and `--`
  are the exception, see finding 1. `push`, `pop`, `swap`, `rotate`, `zap`,
  `setmem`, `togglemem`, `pushnew`, `pull` and `insortnew` all evaluate getter
  and setter under one global lock, with no symbol-place shortcut to escape
  through.
- **`or=` is a correct atomic get-or-create.** It holds `place-lock*` across
  the check and the initializing expression. Several bugs below are "should
  have used `or=`". Note the second half of that sentence is also a cost:
  because the initializing expression runs under the lock, `or=` is only the
  right answer when that expression is cheap and takes no other lock. Where it
  does I/O, load outside the lock and use `or=` only to claim the entry; see
  finding 3.
- **`writefile` is atomic at the filesystem level** (`arc.arc:1026`): unique
  tmp name per write, then rename. No torn or corrupt files, ever. Every
  file-related bug below is staleness, never corruption.
- **Iterating a table while another thread mutates it does not error.**
  Verified empirically on SBCL: 20 `(len (keys h))` passes against a thread
  doing continuous insert and remove produced 0 errors. `maptable` uses raw
  `maphash` (`arc0.lisp:1670`), so a snapshot may be stale, but `save-table`
  and `dead-fnids` will not blow up.

Finding 1 aside, the remaining bugs are all **composite invariants**:
check-then-act, or multi-step updates that are individually locked but not
collectively.

## 1. Lost votes and karma: `++` escaped `place-lock*` on ssyntax places

**Fixed in the working tree for ssyntax places; still open for bare symbols.**
`arc.arc:730`

At `9b2175a`:

```arc
(mac ++ (place (o i 1))
  (if (isa!sym place)
      `(= ,place (+ ,place ,i))
      ...placewiths...))
```

`i!score` *reads as a symbol*, so `(isa!sym place)` was true and `(++ i!score n)`
expanded to `(= i!score (+ i!score n))`. `expand=` then sees a symbol that has
ssyntax, takes the `setforms` branch, and — per the deliberate hoist added on
this branch — evaluates the value expression **outside** the lock:

```arc
(withs (... g (+ i!score n)) (w/place-lock (setter g)))
```

So the read and the write were not atomic with respect to each other. Every
`++`/`--` on an `a!b` or `(tbl k)`-shaped place written in ssyntax form was a
lost-update race. Measured with two threads doing 20000 increments each:

```
old++: expected 40000 got 23930     ; 40% of increments lost
new++: expected 40000 got 40000
```

Live call sites, all in `vote-for`/`unvote-for` (`news.arc:2083`, `2126`):

```arc
(++ i!score     (effect 'score ...))
(++ i!sockvotes (effect 'sockvotes 1))
(++ (karma (by i)) (effect 'karma ...))
(-- i!score n)  (-- i!sockvotes n)  (-- (karma (by i)) n)
```

This is the direct answer to "multiple concurrent votes for the same item":
two upvotes landing together could each read score 5 and each write 6. The
`effect` list recorded per vote stays correct, so `unvote-for` then subtracts
both — driving the score *below* where it started. Karma is corrupted the same
way, and both are persisted by the following `save-item` / `save-prof`.

The fix is `(isa!sym:ssexpand place)` in `++` and `--`: `(ssexpand 'i!score)` is
`(i 'score)`, not a symbol, so the place takes the `placewiths` path and the
getter stays inside the lock.

### The bare-symbol half is still open

The shortcut is still taken for genuine bare-symbol globals, and it is **not**
safe there either. `expand=` sends a symbol with no ssyntax to
`(assign place val)`: the store is a single gcell write, but the read in `val`
is not part of it. Same test, same result:

```
(++ requests*) expands to: (= requests* (+ requests* 1))
bare global: expected 40000 got 27246
```

There is no place form to hang a lock on here, which is why the plan calls for
`atomic-update` — a CAS loop — in phase 2 rather than a lock. Live sites:

| site | impact |
|---|---|
| `srv.arc:92` `(++ requests*)` | undercounted request total |
| `news.arc:2901` `(++ comments-printed*)` | undercounted stat |
| `news.arc:2919` `(++ cc-hits*)` | undercounted cache-hit stat |
| `app.arc:54` `(++ maxuid*)` | safe — inside `maxuid-lock*` |
| `news.arc:378` `(++ maxid*)` | safe — inside `maxid-lock*` |

So the exposure today is stats-only, because the two counters that would be
catastrophic to lose (the id allocators) are the two already covered by their
own locks. That is worth knowing but not worth relying on: the next bare-symbol
counter someone adds will be silently racy, and nothing in the lock hierarchy
will catch it, because no lock is involved.

Both halves are worth a regression test in `examples/locking/`, in the shape of
`lost-updates.arc`: they reproduce deterministically, and the ssyntax half is
the exact bug the lock hierarchy exists to prevent.

## 2. `insert-items` silently drops concurrent submissions

**Fixed in `409efb7`.** `news.arc:572`

```arc
(= stories*  (merge-item-lists stories* items!story items!poll)
   comments* (merge-item-lists comments* items!comment))
```

A read-modify-write whose value expression is evaluated **outside**
`place-lock*`. The comment at `expand=` is right that plain `=` performs no read
*of the place*; it is wrong that this means there is no read-modify-write
window, because the value expression can read the place itself. Finding 1 is
the same root cause reached by a different route.

It races with `(push s stories*)` (`news.arc:2301`, `2469`) and
`(push c comments*)` (`news.arc:2827`), which are correctly locked but get
clobbered anyway:

| thread A (any request that lazily loads an item) | thread B (submitter) |
|---|---|
| read `stories*` | |
| | `(push s stories*)` |
| `merge-item-lists` over ~15k items | |
| assign `stories*` = pre-push merge | |

The new story is gone from `stories*` until restart: it never appears on
`/newest` (`news.arc:1230`) or `/newcomments` (`news.arc:3333`). It survives in
`items*`, on disk, and on the front page via `ranked-stories*`, which makes the
symptom look like a display bug rather than data loss.

The window is one `merge-item-lists` over the full list (tens of ms), but the
trigger is hot, not rare. `w/loading-items` runs `insert-items` on any request
that lazily loads an item, including `commentlink`'s
`(w/loading-items (- (visible-family i) 1))` — once per story per front-page
render — plus `/active`, `/best`, `/bestcomments`. "Someone submits while
someone else loads a page containing an uncached comment" is enough.

Fix: this is a real transaction over two globals. It wants a lock, or a
`zap`-shaped rewrite so the merge happens under `place-lock*`.

The lock is what landed: `w/place-lock` around the two assignments, with
`(hook 'initload items)` left outside it, since a hook is arbitrary user code
and would hold the lock across I/O or reach a lower level. The cost is that
`place-lock*` is now held across two `merge-item-lists` passes over the full
lists, so every assignment in the image stalls for that span on any request
that lazily loads an item. If that shows up in latency, the escape hatch is a
dedicated lock for `stories*`/`comments*`, taken by all four writers
(`insert-items`, the two `push` sites, `put-item`). Its level has to be below
40 numerically, like `users-lock*` at 10, so that the assignments inside its
body can still take `place-lock*` in increasing order.

`examples/locking/insert-items-drop.arc` is the regression test. It exercises
the real `insert-items` against a real `(push s stories*)`; reverting the fix
drops about 170 of 200 submissions.

## 3. Double-load produces two objects for one id

**Fixed in `30b13b3`.** `news.arc:358` and `news.arc:108`

```arc
(def item (id) (items*|load-item id))
(def profile ((t u me)) (profs*|load-prof u))
```

Two threads missing at once both `temload` and both store. Last writer wins in
the table, but `load-item` also does `put-item` into `stories*`/`comments*` as
a *separate* step, so with the interleaving A-set, B-set, B-put, A-put you get
`items*` and `stories*` holding **different objects for the same id**. A vote
mutates one while the front page renders the other, and each `save-item`
overwrites the other's fields.

For profiles the loser's mutations are lost from memory and then from disk: a
karma increment applied to the orphaned table is overwritten when the surviving
table is saved.

Exposure: `initload-users*` is nil, so every profile is lazily loaded — two
concurrent front-page renders after a restart hit this for every author shown.
Items are warmer (`initload*` is 15000, loaded before `serve`), so item
double-load needs concurrent requests for the same *older* item.

Fix: `or=`, but not the one-liner it looks like. `(or= (items* id) (load-item
id))` would hold `place-lock*` across a `temload` plus `put-item`'s insort into
`stories*`, which is the design note below reintroduced on a hotter path than
the one it was written about.

What landed in `30b13b3` splits the loader instead. `read-item` does the bare
`temload` outside any lock; `or=` claims the table entry and nothing else;
`register-item` (the old `put-item`/`register-url` half) runs only for the
thread whose object won the claim, tested with `ident`, since `is` is
isomorphic and two equal items would both look like winners. Losers discard
their copy and return the winner's, so the object-identity split is closed and
`place-lock*` is held only across the store. `profile` and `votes` take the
same shape without the side-effect split.

## 4. `save-*` snapshots race with each other

`save-item`, `save-prof`, `save-pws`, `save-cookies`, `save-uids`

`writefile` is atomic, so nothing corrupts. But `(tablist h)` is read at an
unordered point relative to the `mvfile`: A snapshots, B mutates and writes, A
writes its older snapshot. In-memory state stays correct; the *file* loses the
update, so the loss only surfaces on the next restart.

Concrete cases under normal load:

- two simultaneous signups can lose one account's row from `hpw`
- two simultaneous logins can lose a cookie from `cooks` (that user is silently
  logged out at next restart)
- two votes on one item can persist the lower score

Fix: per-file write serialization, or per-domain locks covering
mutate-then-save as a unit. Principle 6 (idempotence and ordering beat locking)
applies: a lost race here costs only redone work if the operation is replayable.

## 5. fnid harvesting lost its atomicity on this branch

`srv.arc:452` (`forget-fnid`), `srv.arc:535` (`harvest-fnids`)

Both dropped their `atomic` on `lock-levels` and got nothing in its place.
`forget-fnid` is now a bare five-table wipe across `fns*`, `fnids*`,
`timed-fnids*`, `fnkey->fnid*`, `fnid->fnkey*`.

`new-fnid` (`srv.arc:479`) reuses a cached fnid via `or=` on `fnkey->fnid*`. If
the harvester wipes `(fns* key)` just after that lookup, the request renders a
link that is dead the moment it is clicked: "Unknown or expired link" on a page
that just loaded. Partial-wipe states are also observable — `fnkey->fnid*`
still pointing at a fnid whose `fns*` entry is already gone.

This only fires above `fnid-harvest-max*` (50000 fns), but that is a
steady-state condition on a busy server, not an edge case.

This is a genuine regression from the mutex removal, and it is the one site on
the list where the plan already names the fix: a `fnid-lock*` at the level 20
slot reserved for it in the `arc0.lisp` header comment.

Pick a free level, though — the two lock-level tables disagree. `arc0.lisp:1510`
assigns 20 to `fnid-lock*`; `arc.arc:349` assigns 20 to `maxid-lock*`, and also
lists `queue-lock*` (25) and, in `app.arc:50`, `maxuid-lock*` (21), neither of
which appears in the `arc0.lisp` list. `examples/locking/README.md` has a third,
shorter version. Reconciling the three into one table is worth doing before
adding a fourth lock; the levels are the load-bearing part of the design.

## 6. Stale comment bodies pinned for up to a day

`news.arc:2916`

```arc
(= (comment-cache-timeout* c!id) (cc-timeout c!time)
   (comment-cache* c!id)         (tostring (gen-comment-body ...)))
```

If another thread edits, kills, or votes and calls `uncache-comment`
(`news.arc:2926`) while this thread is inside `gen-comment-body`, the wipe is
immediately undone by the stale string **plus a fresh timeout**. `cc-timeout`
scales with comment age, so for a comment older than a day the stale render is
served for up to 24 hours.

Symptom: "I edited my comment and it didn't change." Hard to debug from the
report, because it is timing-dependent and long-lived.

Fix: re-check a generation counter (bumped by `uncache-comment`) before
storing, or store body and timeout as one value so a stale body cannot inherit
a fresh deadline.

## 7. Check-then-act on user actions

None of these has a lock spanning the check and the act:

- **`votable`** (`news.arc:2075`) — a double-click or retried vote applies
  score, sockvotes and karma twice, and pushes two entries into `i!votes` and
  `my!votes`. `unvote-for` (`news.arc:2126`) walks one vote's effects, so it
  undoes only one: the inflation is permanent. hn.js hides the arrow on click
  (`static/hn.js:35`), so this is mostly guarded client-side, but the server has
  no protection at all and the vote URL is a plain link.
- **`find-duplicate-comment`** (`news.arc:2807`) — a double-submitted comment
  creates two items. The `atlet` that used to wrap the creation was dropped on
  this branch; it started *after* the dup check so it never closed this hole,
  but the path is now fully unlocked.
- **`live-story-w/url`** (`news.arc:2287`) — two users submitting the same URL
  at once create two stories; `url->story*` ends up pointing at one of them.

## 8. Minor

- `(= (req-times* ip) (queue))` in `abusive-ip` (`srv.arc:119`) and
  `(unless (optimes* name) (= (optimes* name) (queue)))` in `save-optime`
  (`srv.arc:207`) both drop a queue when two first-requests race. Both should
  be `or=`.
- `(push s stories*)` at submit time can invert the descending-time order the
  list is documented to keep (`news.arc:282`) when two submissions interleave.
  `put-item` would preserve it.

## Design note: `place-lock*` is still a world lock, held across I/O

`expand=` hoists binds and value out of the lock, but `++`, `--`, `push`,
`pull`, `zap`, `setmem` and `togglemem` still evaluate their **binds** inside it
(`arc.arc:730` and neighbors). In this codebase those binds routinely do disk
reads:

```arc
(++ (karma (by i)) ...)          ; binds evaluate (profile u) -> temload on miss
(pull [is _!1 i!id] my!votes)    ; same
```

Every assignment in the image serializes behind that disk read. `adjust-rank`
is the other bad one: `insortnew`'s `zap` re-sorts up to 180 stories and calls
`frontpage-rank` with the lock held.

This is principle 4 being violated by the replacement for the thing principle 4
was written about. The `=` fix (hoist binds out, hold only across the store)
extends to the RMW macros for their *bind* forms; only the getter genuinely has
to stay inside.

## Design note: hot reload

At `9b2175a`, `maybe-reload` (`arc.arc:1749`) still took level-0 `atomic`, which
no longer excluded anything, because `=` no longer takes it. A reload
re-evaluated toplevel `(= ...)` forms concurrently with in-flight request
threads, where previously it had blocked every other thread at its first
assignment.

`bbdf3fb` went the other way: the `atomic` is dropped and nothing replaces it,
with a comment recording the exposure: reload runs unsynchronized on the accept
thread, and requests in flight may observe half-redefined definitions.
The inner `loaded-files-changed` re-check went with it, correctly:
`maybe-reload` is called only from `handle-request` (`srv.arc:82`), which is
the body of the accept loop (`srv.arc:54`), so the re-check was guarding
against a racer that cannot exist.

So hot reload is knowingly unsynchronized today, and reload safety rests on
not reloading under load. The option not taken was `(w/place-lock ; stop the
world ...)`, which would restore the old property by holding the lock every
mutation must pass through, matching the plan's "keep a real global lock here
and be honest that it is global". If that is ever revisited, two consequences:

- `reload` runs arbitrary code (file I/O, every toplevel form in every loaded
  file), so a level-40 lock would be held across all of it, stalling every
  assignment in the image for the length of a reload. Any lock at level ≤ 40
  acquired during a reload would become a hard `Lock order violation` rather
  than a deadlock. Nothing in the current load path appears to take one, but
  `atomic` (0), `maxid-lock*` (20), `maxuid-lock*` (21), `queue-lock*` (25) and
  `scrape-lock*` (30) are all tripwires for anything added to load time later.
- `place-lock*` could only ever be a partial stop. Anything that mutates
  without going through a place form is not stopped by it: finding 2's `=`, and
  finding 1's `++` on bare symbols, which still compiles to a bare `assign`
  today.

## Suggested order

1. ~~`insert-items` (#2)~~: done, `409efb7`.
2. ~~The double-load sites (#3)~~: done, `30b13b3`.
3. `fnid-lock*` (#5) — restores something this branch removed. Pick a free
   level by hand: `a608f98` removed the level 20 slot the `arc0.lisp` header
   used to reserve for it, and 20 and 21 are now `maxid-lock*` and
   `maxuid-lock*`. 22 through 24 are free.
4. `atomic-update` for the bare-symbol counters (#1, second half) — the impact
   today is stats-only, so this is not urgent, but it is the last piece needed
   before "every mutation goes through a lock" is actually true.
5. The rest as convenient.

Repros for #1, #2 and #3 belong in `examples/locking/`, in the style of
`lost-updates.arc`. #1 in particular is worth landing as a permanent regression
test now that half of it is fixed: it reproduces deterministically, and it is
the canonical example of a place form that looks locked and is not. A version
covering both halves would also fail today, which makes it a useful marker for
when #1 is finished.
