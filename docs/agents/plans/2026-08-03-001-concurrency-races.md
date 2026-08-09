# Concurrency Races Under Normal Usage

## Original Request

> see if you can think of any multithreading bugs under normal usage patterns.
> (multiple concurrent votes for the same item, multiple items submitted at the
> same time, multiple simultaneous edits, etc)

Audited on the `lock-levels` branch at `546a6af`, after reading
`2026-08-02-001-remove-global-mutex.md`, `examples/locking/`, and the
`main..lock-levels` diff. This is the ranked findings list; the strategy and
principles live in the remove-global-mutex plan and are not repeated here.

Findings 1 through 5 are fixed and each carries the commit that fixed it. They
are kept because the reasoning is what justifies the fix, and because each
explains a class rather than an instance. Findings 6 through 8 are open. The
hot-reload design note has been rewritten: what it originally described as the
working-tree fix was later reversed, and that section now records the state as
it stands.

Finding 5 grew a second half that the original audit missed entirely: the fnid
harvester was not just racy, it was silently under-reclaiming under concurrency,
which presents as a memory leak rather than as a race. That is the one worth
reading even if the rest is settled.

Four more races were found after the original audit, while fixing these; they
are in their own section below, and all four are fixed. Two design notes were
added: `writefile` takes `place-lock*`, which constrains every lock level in
the tree, and the output locks do not cover what they appear to.

Commit hashes in this doc were rewritten when `lock-levels` was rebased onto
`main`; they refer to the current history.

## Scope note: what is *not* broken

Worth stating up front, because it narrows the search a lot:

- **`place-lock*` makes the read-modify-write macros atomic.** `push`, `pop`,
  `swap`, `rotate`, `zap`, `setmem`, `togglemem`, `pushnew`, `pull` and
  `insortnew` all evaluate getter and setter under one global lock, with no
  symbol-place shortcut to escape through. `++` and `--` were the exception
  until `96ea700`; they now take the same path for everything but lexicals,
  which are thread-local. See finding 1.
- **Plain `=` on a bare symbol is still a bare `assign`.** It takes no lock, so
  it is atomic against nothing. That is only safe where the value form does not
  read the place. `todisk` is the trap here, because it expands its value form
  in place; see the `ignore-log*` entry below.
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

**Fixed in `8680301` for ssyntax places and `96ea700` for bare symbols.**
`arc.arc:730`

At `546a6af`:

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

### The bare-symbol half, fixed in `96ea700`

The shortcut was still taken for genuine bare-symbol globals, and it was **not**
safe there either. `expand=` sends a symbol with no ssyntax to
`(assign place val)`: the store is a single gcell write, but the read in `val`
is not part of it. Same test, same result:

```
(++ requests*) expands to: (= requests* (+ requests* 1))
before: expected 40000 got 27246
after:  expected 40000 got 40000
```

This doc originally called for `atomic-update`, a CAS loop, on the grounds that
there is no place form to hang a lock on. That was wrong: routing bare symbols
through `placewiths` gives them the same lock as every other place, and the
level already exists. What `96ea700` kept the shortcut for is genuine lexicals,
which are thread-local and need no lock, and where the lock would cost about
4.5x and turn every `(++ n)` inside a lock above 40 into a hard lock order
violation.

The exposure before the fix was stats-only, because the two counters that would
have been catastrophic to lose (the id allocators at `app.arc:54` and
`news.arc:378`) were already inside `maxuid-lock*` and `maxid-lock*`.

What this does **not** cover: `=` on a bare symbol still compiles to a bare
`assign`, so `++` is atomic against another `++` but not against a plain
`(= requests* 0)`. Every live bare-symbol `++` site is a counter that is only
ever incremented, so that gap is currently unreachable — but it is the same gap
that made `ignore-log*` a real lost update, and there the value form did read
the place.

Both halves are worth a regression test in `examples/locking/`, in the shape of
`lost-updates.arc`: they reproduce deterministically, and the ssyntax half is
the exact bug the lock hierarchy exists to prevent.

## 2. `insert-items` silently drops concurrent submissions

**Fixed in `e56c93d`.** `news.arc:572`

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

**Fixed in `e3360fa`.** `news.arc:358` and `news.arc:108`

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

What landed in `e3360fa` splits the loader instead. `read-item` does the bare
`temload` outside any lock; `or=` claims the table entry and nothing else;
`register-item` (the old `put-item`/`register-url` half) runs only for the
thread whose object won the claim, tested with `ident`, since `is` is
isomorphic and two equal items would both look like winners. Losers discard
their copy and return the winner's, so the object-identity split is closed and
`place-lock*` is held only across the store. `profile` and `votes` take the
same shape without the side-effect split.

## 4. `save-*` snapshots race with each other

**Fixed in `e221ed8`.** `save-item`, `save-prof`, `save-pws`, `save-cookies`,
`save-uids`

`writefile` is atomic, so nothing corrupts. But `(tablist h)` was read at an
unordered point relative to the `mvfile`: A snapshots, B mutates and writes, A
writes its older snapshot. In-memory state stays correct; the *file* loses the
update, so the loss only surfaces on the next restart.

Concrete cases under normal load:

- two simultaneous signups can lose one account's row from `hpw`
- two simultaneous logins can lose a cookie from `cooks` (that user is silently
  logged out at next restart)
- two votes on one item can persist the lower score
- two comments on one story can lose a kid from the parent's file, which orphans
  the comment: the item file exists but nothing links to it, so it never renders
  in the thread again

That last one self-repairs while the server keeps running, because the next
save of that parent rewrites the file with everything. It only becomes durable
when the racing save is the last one for that item before a restart.

The fix is a striped lock in `save-table`, not in `writefile`: `writefile`'s
`val` argument is evaluated by the caller, so the snapshot has already happened
by the time it is entered. The property it buys is that **a file can no longer
regress to an older snapshot** — writes to one path are serialized and each
`tablist` runs inside the critical section.

Two things it does not cover, both of which call `writefile` directly with the
snapshot as an argument:

- `save-topstories` (`news.arc:555`) has the identical shape and is untouched.
- Every `diskvar` saves through `writefile`, not `save-table`. Of the thirteen
  `todisk` sites, only `ignore-log*` also read its own place; see below.

It also does not make mutate-then-save atomic. Where the in-memory value is
already wrong, the lock faithfully persists the wrong value.

## 5. fnid harvesting lost its atomicity on this branch

**Fixed in `3b62dc0`.** `srv.arc:457` (`forget-fnid`), `srv.arc:544`
(`harvest-fnids`)

Both dropped their `atomic` in `9db6bf7` and got nothing in its place.
`forget-fnid` was a bare five-table wipe across `fns*`, `fnids*`,
`timed-fnids*`, `fnkey->fnid*`, `fnid->fnkey*`.

`new-fnid` (`srv.arc:485`) reuses a cached fnid via `or=` on `fnkey->fnid*`. If
the harvester wiped `(fns* key)` just after that lookup, the request rendered a
link that was dead the moment it was clicked: "Unknown or expired link" on a
page that just loaded. Partial-wipe states were also observable —
`fnkey->fnid*` still pointing at a fnid whose `fns*` entry was already gone.

This only fires above `fnid-harvest-max*` (50000 fns), but that is a
steady-state condition on a busy server, not an edge case.

`fnid-lock*` at 24 now covers `forget-fnid`, and also `fnid`, `timed-fnid` and
`afnid` across `new-fnid` and the population that follows, so a create cannot
interleave with a forget. Four concurrent creators against two harvesters leave
0 dangling index entries.

The level has to be below 40: everything inside does table places and takes
`place-lock*`. Nothing on this path touches the save lock at 22, so 22 through
39 were all viable and `1a5b30e` had left 24 free.

### The half the audit missed: the harvester was under-reclaiming

`harvest-fnids` runs at the end of *every* request (`srv.arc:154`), and each
request is its own thread (`srv.arc:95`). So above the threshold every request
thread harvests concurrently, and each computed its kill list from the same
snapshot, picked the same oldest 10%, and forgot the same ids. Forgetting an
already-forgotten id is idempotent, so a wave of requests reclaimed what a
single one would:

```
8 staggered concurrent harvesters: removed 103
8 sequential harvest calls:        removed 800
```

The intuition to resist here is that concurrent harvesters *over*-cull. They do
not; they collide. The failure is that `fns*` grows past `fnid-harvest-max*`
under exactly the concurrent load the harvester exists to bound, which presents
as a memory leak rather than as a race.

Computing each kill list inside the lock fixes it, because the next harvester
through re-derives it against an already-trimmed table: both phases now measure
800 of 800, and creators running against harvesters converge on the threshold
instead of drifting above it.

Two details of that fix are load-bearing:

- The two phases take the lock **separately** rather than as one block, so it is
  released between them and a page render waiting to mint a link is not stalled
  across both table scans. Each re-checks the threshold under its own lock,
  since phase 1 can drop `fns*` below it.
- The unlocked `(len> fns* n)` ahead of each is the cheap path, not redundant.
  `harvest-fnids` runs per request and `fnid-lock*` is the same lock every
  render holds while minting links, so testing inside the lock made every
  below-threshold request pay for it: 46.3 ms per 100k calls against 7.5 ms.
  That is the shape `save-lock` already uses with its bare read ahead of the
  `or=`, and `ensure-uid` with its double check.

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

## Found after the original audit

These turned up while fixing findings 1 through 4. All four are fixed.

### 9. A session cookie that logout could never revoke

**Fixed in `44925fc`.** `app.arc:248` (`logout-user`), `app.arc:464`
(`good-login`)

`logout-user` wiped only the cookie `user->cookie*` happened to index. But
`good-login` minted under a check-then-act, so two logins for a user with no
cookie could both mint one: `cookie->user*` then mapped both while
`user->cookie*` kept whichever landed last. The browser holding the other one
stayed authenticated through every subsequent logout, because nothing pointed
at that cookie any more to wipe it.

`user->cookies*` now holds every cookie for a user and logout sweeps the list.
Note this **defuses** the race rather than closing it: `good-login` still
check-then-acts, and two threads can still both mint. The difference is that
both land in the list and both get revoked. The common case is still one cookie
per user, because a second login reuses the existing one through that `unless`.

The window needed a user with no cookie in the table, which means a fresh
account or one that had just logged out, reached by a double-submitted login
form or two devices at once.

### 10. `ignore-log*` lost an entry to `todisk`'s bare-symbol `=`

**Fixed in `46ad384`.** `news.arc:2366`

```arc
(todisk ignore-log* (cons (list user actor cause) ignore-log*))
```

`todisk` expands its value form in place, so this became a bare-symbol `=`
whose value form reads the symbol it writes. Two admins ignoring users at the
same moment kept one entry and dropped the other. The write raced too, and
`ignore-log*` is a `diskvar`, so finding 4's fix does not reach it.

One lock at level 23 over the whole form covers both halves. `push` alone would
have handled the read-modify-write but left the file able to regress.

This was the only `todisk` site whose value form reads its own place.

### 11. `auth-key` minted two hmac keys on a first-boot race

**Fixed in `2fadade`.** `app.arc:322`

A check-then-act on a bare global: two threads both see `hmac-key*` nil, both
mint, one wins the assignment, and whichever already returned the loser's key
signs tokens against a key that no longer verifies. Four threads racing it
computed the value four times; `or=` computes it once.

The lock-free `(or hmac-key* ...)` in front of the `or=` is load-bearing for a
different reason: `auth-for` runs once per vote, hide and fave link, so a plain
`or=` would take `place-lock*` dozens of times per front-page render to read a
value that never changes after boot.

The window is first boot only, before the `hmac-key` file exists.

### 12. `srvlog` interleaved two records onto one line

**Fixed in `e525f72`,** and only observable after `2f39dcc`.

`disp` force-outputs and `writec` does not (`arc0.lisp:613` and `535`), so
`prn` wrote the record body through to the file under `log-lock*` but left the
trailing newline in the stream buffer. `w/appendfile` closes outside the lock,
so that newline flushed after the lock was released, and two threads could land
both bodies on one line:

```
1786256474 ddd 1 2 31786256474 bbb
```

Four threads, 400 records, ten trials: 11 damaged lines before, 0 after adding
`flushout` inside the lock.

None of it was observable earlier, because `outfile` compared its mode argument
against the string `"append"` while `w/appendfile` passes the symbol, so every
open truncated and the file never held more than one record. `2f39dcc` fixed
the mode test. The evidence is still on disk: of the 42 files in `arc/logs/`,
the 40 written before the fix are one line each, one line per day, and the two
written after it are growing normally.

## Design note: `writefile` takes `place-lock*`

This constrains every lock level in the tree and is not obvious from reading
`writefile`. Its unique temp name comes from `rand-string`, and `rand-elts`
takes `place-lock*` at 40:

```
(arc-check-lock-level 40 ...)
(RAND-ELTS 16 "0123456789abc...")
(RAND-STRING 16)
(TMPNAME ".../ignore-log")
(WRITEFILE ...)
```

So **no lock at or above 40 can wrap a `writefile`**, which rules out all three
output locks (51 srvlog, 52 scrapelog, 59 ero) for anything that saves. Two
attempts hit this before it was understood: wrapping `srvlog`'s `w/appendfile`
in `log-lock*`, and wrapping `log-ignore` in the same lock. Both killed every
logging thread with a hard `Lock order violation` rather than misbehaving
quietly, which is the hierarchy working.

It also fixes the window for the save lock at both ends: above 21, because
`ensure-uid` holds `maxuid-lock*` across `save-uids`, and below 40 for the
reason above. That leaves 22 through 39.

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

At `546a6af`, `maybe-reload` (`arc.arc:1749`) still took level-0 `atomic`, which
no longer excluded anything, because `=` no longer takes it. A reload
re-evaluated toplevel `(= ...)` forms concurrently with in-flight request
threads, where previously it had blocked every other thread at its first
assignment.

`3f88137` went the other way: the `atomic` is dropped and nothing replaces it,
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
  without going through a place form is not stopped by it. `++` on bare symbols
  now routes through `placewiths` as of `96ea700`, but plain `=` on a bare
  symbol still compiles to a bare `assign`.

## Suggested order

1. ~~`insert-items` (#2)~~: done, `e56c93d`.
2. ~~The double-load sites (#3)~~: done, `e3360fa`.
3. ~~The bare-symbol half of `++` (#1)~~: done, `96ea700`, with a lock rather
   than the `atomic-update` this doc originally called for.
4. ~~The `save-*` snapshot races (#4)~~: done, `e221ed8`.
5. ~~`fnid-lock*` (#5)~~: done, `3b62dc0`, at level 24.
6. Comment cache staleness (#6) — the longest-lived symptom on the list, up to
   a day of a stale body, and the hardest to diagnose from a user report.
7. Check-then-act on votes and comments (#7) — the one with user-visible
   permanent effects (inflated score that `unvote-for` cannot undo).
8. `save-topstories` and the `diskvar` writes, the two exclusions from #4's fix.
9. The rest as convenient.

Levels 20 through 24 are now `maxid-lock*`, `maxuid-lock*`, `save-locks*`,
`ignore-log-lock*` and `fnid-lock*`. Free: 26 through 29 and 31 through 39.
Anything that saves, or that reaches `writefile` by any route, has to stay
below 40; see the `writefile` design note.

Repros belong in `examples/locking/`, in the style of `lost-updates.arc`. #1's
is the canonical example of a place form that looks locked and is not, and #4's
needs the losing interleaving forced (snapshot first, write last), because in a
tight loop the next save repairs the file and the race hides.
