# Concurrency Races Under Normal Usage

## Original Request

> see if you can think of any multithreading bugs under normal usage patterns.
> (multiple concurrent votes for the same item, multiple items submitted at the
> same time, multiple simultaneous edits, etc)

Audited on the `lock-levels` branch at `546a6af`, after reading
`2026-08-02-001-remove-global-mutex.md`, `examples/locking/`, and the
`main..lock-levels` diff. This is the ranked findings list; the strategy and
principles live in the remove-global-mutex plan and are not repeated here.

**Every finding on this page is fixed.** Each carries the commit that fixed it.
They are kept because the reasoning is what justifies the fix, and because each
explains a class rather than an instance. The hot-reload design note has been
rewritten: what it originally described as the working-tree fix was later
reversed, and that section now records the state as it stands.

Finding 5 grew a second half that the original audit missed entirely: the fnid
harvester was not just racy, it was silently under-reclaiming under concurrency,
which presents as a memory leak rather than as a race. That is the one worth
reading even if the rest is settled.

Six more races were found after the original audit, while fixing these; they
are in their own section below, and all six are fixed. Finding 13 was the
serious one, the only entry on this page that could write *fabricated* data to
a file rather than lose data already there, and it falsifies two of the "what
is *not* broken" claims below, which are struck rather than deleted so the
reasoning that was wrong stays visible. Three design notes were added: never
run arbitrary code under a table's own mutex, `writefile` takes `place-lock*`
(which constrains every lock level in the tree), and the output locks do not
cover what they appear to.

What is left is not a race. `loaded-item-ids` walks and sorts every key of
`items*`, which does not survive tens of millions of items however the walk is
implemented; it is now the largest open item and it wants an index, not a lock.
See the suggested order for that and two smaller leftovers.

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
  file-related bug below is staleness — with one exception, finding 13, where
  the snapshot handed to `writefile` contains a row that was never in the
  table. The file is written perfectly; its contents are fabricated.
- ~~**Iterating a table while another thread mutates it does not error.**~~
  **This claim was wrong. See finding 13.** The original test measured only
  `(len (keys h))` and only looked for errors, so it never checked whether the
  keys it got back were real. They are not: a concurrent insert can make
  `maphash` yield keys that were never in the table. "Stale" badly understates
  it.

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

**Fixed in `88576d8`,** with a generation counter bumped by `uncache-comment`
and sampled before the render, so a store that was invalidated mid-flight
declines instead of winning. Note the second option this section originally
offered, storing body and timeout as one value, does **not** fix it: it makes
the pair consistent, but a stale body with a consistent fresh deadline is
served exactly as long.

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

**Fixed in `b168e44` (the two submit paths) and `efdbe0e` (voting).**

None of these had a lock spanning the check and the act:

- **`votable`** (`news.arc:2108`) — a double-click or retried vote applied
  score, sockvotes and karma twice, and pushed two entries into `i!votes` and
  `my!votes`. `unvote-for` walks one vote's effects, so it undoes only one: the
  inflation was permanent. hn.js hides the arrow on click (`static/hn.js:35`),
  so this was mostly guarded client-side, but the server had no protection and
  the vote URL is a plain link.
- **`find-duplicate-comment`** — a double-submitted comment created two items.
- **`live-story-w/url`** — two users submitting the same URL at once created
  two stories; `url->story*` ended up pointing at one of them.

### The submit paths: one lock, held wide

`submit-lock*` at level 10 wraps all three `process-*` handlers. Each has
exactly one caller and all three are wrapped, so there is no unlocked path to
the same race.

The span is deliberately wide: wrapping the form handler rather than
check-plus-create holds the lock across everything a submission does, which is
half a dozen file writes (`save-item` for the item, `save-item` for the parent
on comments, `save-site-items`' full `save-table`, then `submit-item`'s
`vote-for` with its `save-item`, `save-prof`, `save-votes` and `adjust-rank`'s
`save-topstories`, plus `newslog`). Every submission serializes globally against
every other, so at roughly ten milliseconds each this caps submissions near a
hundred per second — far above what this site sees, and it buys a fix that is
four lines instead of a restructure.

The narrower version stays available if submit latency shows up in `optimes*`:
hold the lock across the dup check and the in-memory publish only, and release
before the saves. `28d92fc` made that cheaper by moving the `items*` publish to
the front of every `create-*`.

### Voting: why the obvious fix is wrong

The tempting fix is to claim `(voted i)` with `or=` at the top of `vote-for`,
testing the result with `id` rather than `is`. **`id` is genuinely required
there** — two simultaneous votes build structurally equal lists, so `is` calls
both racers winners, measured as `id-winners=1` against `is-winners=2` over five
trials.

But that fix is wrong on its own, and the reason is worth keeping. The effects
list is built *as `vote-for` runs*, so moving the claim to the front opens a
window in which `unvote-for` sees a vote whose `vote!5` is still empty,
subtracts nothing, wipes it, and lets `vote-for` go on to apply the score and
karma. Orphaned effects with no record left to undo them, which is worse than
the double vote. Today's ordering, with `(= (voted i) vote)` last, means an
unvote arriving mid-vote finds nil and does nothing.

So `efdbe0e` leaves both bodies untouched and wraps them in a striped
`vote-lock*` at level 11, which makes the pair atomic in all three directions
at once: two votes, two unvotes, and a vote racing an unvote. `unvote-for` had
the mirror race — two concurrent unvotes both read the same vote and both
subtract, driving the score *below* where it started.

```
without the lock: score=2 votes=2   (5 of 5 trials)
with the lock:    score=1 votes=1   (5 of 5)
```

Per-user is the right grain because the contested state is `(voted i)`, which is
`((votes* (me)) i!id)` — keyed by user first. Two different users voting one
item share only `i!score`, `i!votes` and the author's karma, each an
individually atomic place operation, with `save-item` already serialized per
file by `save-locks*`. There is no composite invariant across users.

That grain is also why this is cheap where `submit-lock*` is not: a user
contends only with themselves, so the lock is uncontended in normal operation
and bites exactly when the race would have occurred. Unrelated voters collide
only on a stripe hash collision, about one in sixty-four. Votes are the hottest
write on the site, so a single global lock here would have cost far more than
the one on submissions.

## 8. Minor

**Fixed in `49fce23`.**

- `(= (req-times* ip) (queue))` in `abusive-ip` (`srv.arc:119`) and
  `(unless (optimes* name) (= (optimes* name) (queue)))` in `save-optime`
  (`srv.arc:207`) both dropped a queue when two first-requests raced. Both are
  now `or=`. A hundred barrier-synced threads lost up to 82 of 100 enqueues
  before, 0 after. **The barrier is what makes that a test**: an earlier attempt
  started the threads without one, reported 200 of 200 on the *unfixed* code,
  and proved nothing — natural start jitter lets the first thread win before
  the others check.
- `(push s stories*)` at submit time could invert the descending-time order the
  list is documented to keep (`news.arc:282`) when two submissions interleaved.

The second bullet originally said "`put-item` would preserve it." That was
wrong, and the reason is worth keeping. `put-item` is `insortnew`, whose
`reinsert-sorted` rebuilds the entire tail through `rem` even when there is no
duplicate to remove, under `place-lock*`: 11.8 ms per insert into a
50000-element list against `push`'s 0.008, and it exhausts the control stack
past 300000. `add-item` (`news.arc:363`) uses `insort` instead, whose
`insert-sorted` shares the tail rather than re-consing it — 0.018 ms flat, and
it survives a million.

That is only sound because nothing being inserted at those sites can already be
present, and **that was not true when the change first landed**. The `create-*`
functions saved to disk before publishing to `items*`, so a concurrent
`(item id)` could load a second object for the same id and register it
independently; `28d92fc` swapped the two lines so `items*` is populated first
and the claim in `item` can never be won by a competing `read-item`. Only then
does the dedup become genuinely dead weight.

A guard that does **not** work, recorded so it is not tried again: wrapping the
`rem` as `(if (some [same elt _] seq) (rem elt seq same) seq)` so the common
case shares structure. It is a wash on speed, because the `some` scan costs
about what the re-consing did, and it does not remove the stack ceiling,
because the walk *to* the insertion point is itself non-tail recursive. Making
`reinsert-sorted` cheap or stack-safe means rewriting it iteratively.

`insert-sorted` has the same non-tail recursion, so deep insertion into a long
list still has a control-stack ceiling. That is why `register-item`, which
inserts lazily loaded items that are old and therefore sort deep, gains only
about a fifth (19.55 ms to 16.06 ms at 50000) where the `create-*` sites gain
three orders of magnitude.

## Found after the original audit

These turned up while fixing the findings above. All six are fixed.

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

### 12. The output paths left their trailing newline outside the lock

**Fixed in `91fc2cd` (`warnset`), `e525f72` (`srvlog`) and `e440fd4` (`ero`).**
The `srvlog` half was only observable after `2f39dcc`.

All three share one root cause, so they are one finding rather than three.
`disp` force-outputs and `writec` does not (`arc0.lisp:613` and `535`), so a
`prn` writes its body through under the lock and leaves the trailing newline in
the stream buffer, to be flushed at some unordered later point. The fix in each
case is `flushout` as the last form inside the lock, not moving the lock.

They differ in how exposed each was:

- **`srvlog`** was the real bug. `w/appendfile` opens before the lock and closes
  after releasing it, so the newline flushed outside the lock entirely and two
  threads could land both bodies on one line.
- **`warnset`** wrote to stderr with no lock at all, so "*** redefining x"
  lines could interleave.
- **`ero`** was the least exposed: a single shared stderr rather than a stream
  it opens itself, and the newline was at least inside the lock. That made it
  correct by accident rather than by construction, since it depended on stderr's
  buffering instead of on a flush. Four threads, 100 records each: 400 lines, 0
  with more than one record on them.

The `srvlog` failure, verbatim:

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

### 13. `maphash` yields keys that were never in the table

**Fixed in `438a7c5`.** `arc0.lisp:1686` (`maptable`), `arc.arc:1264` (`keys`),
`arc.arc:1276` (`tablist`)

This is the one the scope note above got wrong, and it was the only finding on
the list that could put fabricated data into a file rather than losing data
already there.

`maptable` is a raw `maphash` with no lock. When another thread inserts, the
table rehashes, and a concurrent walk can visit storage slots mid-move and
yield `0`, which is SBCL's fill value for an unused key slot. `keys` then
accumulates that `0` as though it were a key. One thread growing a table while
another walks it:

```
table size: 2071471
keys yielded by maphash that then failed lookup: 818801
samples: (0 0 0)
```

It surfaced as a crash in the `update-avg` background thread during a scrape,
which is the pairing that makes it likely: `scrape-hn-stories` inserting into
`profs*` while `(defbg update-avg 45)` walks it.

```
rand-user -> loaded-users -> (keys profs* test)
  test called with _ = 0
  (uvar 0 submitted) -> ((profile 0) 'submitted)
  (profile 0) -> nil, because 0 was never in the table
  (nil 'submitted) -> (elt nil 'submitted)
  "The value ARC::|submitted| is not of type (UNSIGNED-BYTE 45)"
```

`(uvar 0 submitted)` and `(uvar nil submitted)` both reproduce that error
string exactly.

**`tablist` has the same hole, and that is the worse half**, because `tablist`
is what `save-table` writes:

```
phantom entries seen by tablist: 412677
sample entry: (0 0)
```

So a save racing a concurrent insert can persist a `(0 0)` row into `hpw`,
`cooks`, `uids`, or a profile file. Note the striped save lock from `e221ed8`
does **not** help here: it serializes savers against each other, not against a
thread inserting into the table being snapshotted. This is the one place where
the "every file bug is staleness, never corruption" claim in the scope note
above fails — the file is not stale, it has a row in it that never existed.

### What landed, and the two fixes that were rejected

`438a7c5` uses **two mechanisms on purpose**, which is the part most likely to
be "tidied" later by someone who assumes they should match.

`tabkeys`, `tabvals` and `tabpairs` snapshot under the table's own mutex, and
`keys`, `vals` and `tablist` became thin wrappers over them. They want a
consistent point-in-time view and are cheap to copy. `maptable` instead
validates on read, re-fetching the value and skipping the entry when it is nil,
so it neither allocates nor holds a mutex across the walk — which matters
because `items*` may reach tens of millions of entries, where both a snapshot
list and a mutex held for its duration are unacceptable.

That validation depends on `sref` remhashing when the value is nil
(`arc0.lisp:1697`), which is what makes `(gethash k table)` a valid liveness
test. If a live entry could ever hold nil, `maptable` would silently skip every
one of them. `maptable`'s contract is now **may skip, may duplicate, never
fabricates**: a rehash can still cause an entry to be missed or visited twice,
and no caller cares about either, but a fabricated row mattered a great deal.

It is also *faster*, not a tax. The old `tablist` was
`(accumulate a (maptable (fn args (a args)) h))`, which paid an arc call and a
fresh rest-list per entry. Collecting in Lisp instead, over 20000 entries:
1.37 ms to 0.10 ms for string keys, 1.38 ms to 0.105 ms for integer keys.

Two approaches were tried and rejected, both worth recording:

- **Consumer-side guards** (`[and (profile _) ...]` in `update-avg-user`) stop
  the crash and leave `tablist` and every other consumer exposed. Note guarding
  on the key itself does not work at all: `0` is truthy in arc, so the guard has
  to be on the lookup.
- **Pushing the test inside the lock**, so `tabkeys` filters while holding the
  table mutex, looks like a free allocation saving. It runs arbitrary arc code
  under that mutex, and the real tests take `place-lock*` (`loaded-users`'
  predicate reaches `profile` and its `or=`) and do disk I/O (`load-prof`'s
  `temload`). See the design note below for why that is the worst option
  available.

`examples/locking/phantom-keys.arc` is the regression test. It detects phantoms
**by type**, not by a failed lookup: a key that fails a lookup may simply have
been removed after the walk started, which is ordinary staleness. Conflating
the two overstates the damage by hundreds of thousands, and did so twice while
this was being investigated. Against the unfixed tree it reports 251770
phantoms, every one of them `0`.

What this does **not** fix: `loaded-item-ids` is `(sort > (keys items*))`, and
at tens of millions of items that is unusable however cheap the walk becomes.
It backs four 300-second `defcache`s plus `should-ban-ip`. That wants an
incrementally maintained index, in the shape `sitename->items*` and
`url->story*` already use, not a faster scan.

### 14. Creating an item made a second object for the same id

**Fixed in `28d92fc`.** `news.arc:2313` (`create-story`), `2484` (`create-poll`),
`2495` (`create-pollopt`), `2851` (`create-comment`)

Finding 3 again, reached from the other end. That one was two threads *loading*
one id; this is a thread *creating* one while another loads it.

All four `create-*` functions saved to disk before publishing to `items*`:

```arc
(save-item s)          ; the file exists from here on
(= (items* s!id) s)    ; but items* is not populated until here
```

In between, the item exists on disk and not in memory, which is exactly the
miss path in `item` (`news.arc:348`). A concurrent `(item id)` calls
`read-item`, gets a **second distinct object** for the same id, wins the `or=`
claim because the creator has not published yet, and `register-item` inserts
that object into `stories*` or `comments*`. The creator then overwrites `items*`
with its own object and inserts that one too. Two objects, one id, both in the
list, with `items*` naming only one: a vote mutates one while `/newest` renders
the other.

Reachable with nothing unusual on the client. `new-item-id` increments `maxid*`
and `todisk`s it *before* the item is published, and `safe-item`
(`news.arc:436`) will fetch any well-formed id off a request, so a GET for
`item?id=<maxid*>` landing inside the `save-item` call is enough.

The fix is to swap the two lines. With `items*` populated first, `item`
short-circuits and never reaches `read-item`. The new window — id allocated,
`items*` populated, file not yet written — is harmless because `read-item`
guards on `file-exists` (`e3360fa`), so a request for that id gets a clean nil
rather than a second copy.

It does invert which failure a crash produces. Before, a crash between the save
and the publish left the item on disk, invisible until something loaded it
lazily. Now a crash between the publish and the save loses it, and anything
that voted on it in the interim refers to an id with no file. The window is one
`save-item` call either way, and being consistent while running is worth more
than being durable across a crash inside it.

This is also what makes `add-item` sound at those sites; see finding 8.

## Design note: never run arbitrary code under a table's own mutex

Arc tables are `:synchronized` (`arc0.lisp:1657`), so each has an SBCL mutex,
and `sb-ext:with-locked-hash-table` can hold it across a whole walk. That is the
obvious way to make `maptable` safe, and it is the worst option available.

`(= (h k) v)` takes `place-lock*` at 40 and **then** the table's mutex, because
the setform goes through `placewiths` and the store itself is a synchronized
`setf gethash`. A walk that holds the table mutex and then runs a body which
takes `place-lock*` acquires the same two locks in the opposite order. The
bodies here really do that: `loaded-users`' predicate reaches `profile`, whose
`or=` takes `place-lock*`, and `load-prof`'s `temload` does disk I/O.

What makes this worse than an ordinary ordering bug is that **`arc-check-lock-
level` cannot see it**. The SBCL table mutex is not in arc's level table, so the
assert that has caught every other ordering mistake on this branch — the
`writefile` note below, the `srvlog` and `log-ignore` attempts, the level-24
`fnid-lock*` choice — is blind here. The failure mode is a hang, not a loud
`Lock order violation`.

So the rule is: a table mutex may be held across a **copy** and nothing else.
No arc calls, no I/O, no other lock. `438a7c5` follows it, which is why
filtering in `keys` and `vals` happens outside the lock even though doing it
inside would save an intermediate list.

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
6. ~~Comment cache staleness (#6)~~: done, `88576d8`, with a generation counter.
7. ~~Phantom keys from `maphash` (#13)~~: done, `438a7c5`, with a snapshot for
   the list-builders and validate-on-read for `maptable`.
8. ~~The queue drops and the submit-time ordering (#8)~~: done, `49fce23`, with
   `add-item` rather than the `put-item` this doc originally called for.
9. ~~The create-side twin of the double-load (#14)~~: done, `28d92fc`.
10. ~~Check-then-act on votes and comments (#7)~~: done, `b168e44` for the two
    submit paths and `efdbe0e` for voting. The vote half did **not** turn out to
    be the four-line `or=` claim this list used to describe; see finding 7 for
    why that fix is wrong on its own.
11. **An index for `items*`** — the largest open item, and the only one that is
    a scaling problem rather than a race. `loaded-item-ids` is
    `(sort > (keys items*))`, backing four 300-second `defcache`s plus
    `should-ban-ip`. Nothing here has to be walked: the derived data is
    dead-items-by-site and items-by-ip, both of which can be maintained at
    `kill` and `register-item` time the way `sitename->items*` already is.
12. `save-topstories`, the one exclusion from #4's fix that is worth doing; it
    is reached from `adjust-rank` on every story vote. The `diskvar` writes are
    the other exclusion and need nothing: `maxid*` and `maxuid*` already save
    inside their own locks, `ignore-log*` and `hmac-key*` are fixed, and the
    rest are whole-value replacements from admin forms.
13. An iterative `reinsert-sorted`, if `register-item`'s insertion cost or the
    control-stack ceiling on long lists ever matters. See finding 8 for the
    guard that looks like it would help and does not.
14. The rest as convenient.

The levels in use are now 10 `submit-lock*`, 11 `vote-lock*`, 20 `maxid-lock*`,
21 `maxuid-lock*`, 22 `save-locks*`, 23 `ignore-log-lock*`, 24 `fnid-lock*`,
25 `queue-lock*`, 30 `scrape-lock*`, 40 `place-lock*` and the output locks at
51, 52 and 59. Free: 1 through 9, 12 through 19, 26 through 29, 31 through 39.
`arc.arc` is the single table (`1a5b30e`); keep it in sync.

Two constraints bound almost every choice. Anything that saves, or reaches
`writefile` by any route, has to stay **below 40**, because `writefile` takes
`place-lock*` through `tmpname`. Anything reached from a submission has to stay
**above 10**, since `submit-item` calls `vote-for` from inside `submit-lock*`.
That is how `vote-lock*` ended up at 11, between the two.

Repros belong in `examples/locking/`, in the style of `lost-updates.arc`. #1's
is the canonical example of a place form that looks locked and is not, and #4's
needs the losing interleaving forced (snapshot first, write last), because in a
tight loop the next save repairs the file and the race hides.
