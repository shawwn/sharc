# Removing the Global Mutex

## Original Request

> Arc has a single shared global mutex. Dan Gackle already removed it in his
> version of arc, clarc. Help me come up with strategies to successfully
> remove the mutex, and some principles for how to be confident in the code

## What we're actually removing

`arc0.lisp:1476`:

```lisp
(defvar *arc-mutex* (sb-thread:make-mutex :name "arc"))
(defvar *arc-atomic-owner* nil)

(xdef atomic-invoke (f)
  (if (eq sb-thread:*current-thread* *arc-atomic-owner*)
      (arc-call0 f)
      (sb-thread:with-mutex (*arc-mutex*)
        (let ((*arc-atomic-owner* sb-thread:*current-thread*))
          (arc-call0 f)))))
```

One global mutex, made reentrant per-thread by `*arc-atomic-owner*`. Roughly
20 `atomic` call sites across `arc.arc`, `srv.arc`, `news.arc`, `app.arc`,
`scrape.arc`.

Two facts about this codebase change the shape of the problem considerably:

1. **Every hash table is already `:synchronized t`** (see handoff
   `2026-04-28-002-synchronize-all-tables.md`), and globals already resolve to
   `gcell`s with their own dedicated creation lock (`arc0.lisp:92`,
   `*arc-globals-lock*`; see handoff `2026-07-27-001-global-cells.md`). So the
   global mutex is *not* what makes basic table access or variable access safe.
   It is only doing work for **composite invariants across several
   structures**. That is a much smaller job than the call-site count suggests.

2. **The world lock is taken at least four times per HTTP request:**

   | Site | What it does |
   | --- | --- |
   | `srv.arc:126,131` | `abusive-ip` -> `deq` / `enq` on `req-times*` |
   | `srv.arc:212` | `save-optime` -> `enq-limit` on `optimes*` |
   | `srv.arc:711` | `srvlog`, called from `log-request` |
   | `srv.arc:154` | `harvest-fnids`, at the end of `handle-request-thread` |

   None of those four need to exclude each other. That is the real cost, and
   it is also the easiest part to delete.

The single worst site is `scrape.arc:535`. `fetch-hn-url` holds the global
mutex across `(scrape-delay!)` (a `sleep`) *and* a `curl-get`. Every other
thread in the image stalls behind a network fetch.

## The reframing that matters

**Don't go from 1 lock to 0. Go from 1 global lock to about five named,
ordered, documented domain locks.**

"Is this code correct?" is unanswerable for a global lock and quite answerable
per domain. The goal is to shrink the scope of exclusion until each remaining
critical section is small enough to audit by eye.

## Strategy

### Phase 0. Make it measurable before touching anything

Thread a label through the macro:

```arc
(mac atomic body
  `(atomic-invoke {do ,@body} ',(or script-file* 'unknown)))
```

Record per-site acquire count, wait time, and hold time. Log any hold over a
few ms. This turns "remove the mutex" from a rewrite into a ranked list, and
`fetch-hn-url` will announce itself immediately. Keep the instrumentation on
through the whole migration; it is how each phase gets validated.

### Phase 1. Delete the sites that never needed a lock

Sorting the call sites by the invariant they actually protect:

**Output interleaving.** `ero` (`arc.arc:1700`), `srvlog` (`srv.arc:711`),
`scrapelog` (`scrape.arc:59,62`), `examples/coroutines.arc:60`. These only want
"don't split a line across threads." Give them a lock per output stream. A log
line should never take the world lock.

**Lazy init / check-then-set.** `or=` (`arc.arc:725`), `thread-locals`
(`arc.arc:1940`), `ensure-uid` (`app.arc:55`), `init-user` (`news.arc:148`).
These don't want a critical section, they want an idempotent get-or-create.
`sb-ext:with-locked-hash-table` on the one table involved is exactly right and
composes with the `:synchronized t` already in place. Note that `or=` is on the
load path for every global table in the system, so this one is hot.

**External resource pacing.** `scrape.arc:535,678`. Wants a scraper-private
lock, and per principle 4 should not hold it across the fetch at all: take the
lock to claim a slot and stamp `last-fetch-time*`, release, then fetch.

**Queues.** `enq` / `deq` / `enq-limit` (`arc.arc:1713-1736`). Wants a lock per
queue, stored in the queue itself. The existing comment at `arc.arc:1710`
("Despite call to atomic, once had some sign this wasn't thread-safe. Keep an
eye on it.") is worth taking seriously: `(q 2)` and `(car q)` are updated
separately, and `deq` decrements the count before popping.

### Phase 2. Build the primitives first

Expose `sb-thread` recursive mutexes to arc as `(mutex name level)` plus a
`w/lock` macro, with the lock-level check from principle 3 baked in. Recursive,
because arc code freely re-enters itself and we are replacing something that
was reentrant. Add `atomic-update` (a CAS loop) for plain counters like
`opcounts*`.

### Phase 3. Convert the true transactions, one domain per commit

What remains is genuinely multi-structure:

- **User store** (`news.arc:148,191,224,257`, `app.arc:55`). `duplicate-user`,
  `erase-user`, `rename-user`, `init-user`, `ensure-uid` touch `profs*`,
  `votes*`, `hpasswords*`, `user->uid*`, `uid->user*`, `dc-usernames*`,
  `admins*`, and `maxuid*` as a unit. One `users-lock*`.
- **Fnids** (`srv.arc:453,540`). `forget-fnid` and `harvest-fnids` span `fns*`,
  `fnids*`, `timed-fnids*`, `fnkey->fnid*`, `fnid->fnkey*`. One `fnid-lock*`.
- **Moderation** (`news.arc:1992`, `toggle-blast`). Touches item flags plus
  site bans.
- **Reload** (`arc.arc:1675`, `maybe-reload`). This one is legitimately global:
  it swaps code out from under running threads. Keep a real global lock here
  and be honest in the comment that it is global.

Because the global mutex still exists throughout the transition, each site
moved out is independently correct and shippable. Never big-bang this.

### Phase 4. Close the door

Once the list is empty, redefine `atomic` to either error or alias the reload
lock, so nothing reintroduces a world lock out of habit.

## Principles for confidence

**1. Name the invariant, not the region.** For each `atomic`, write the
sentence "no other thread may observe X." If you can't write it, the `atomic`
is cargo cult; delete it. If you can, the sentence names the data, and the data
names the lock.

**2. Locks belong to data, not to code.** Every lock carries a comment listing
exactly which globals it protects; every protected global carries a comment
naming its lock. If a global ends up under two locks, that is a design bug
surfaced before it becomes a runtime bug.

**3. Total lock order, asserted at runtime.** This is the highest-value thing
to build, and it should exist before a single site is converted. Give each lock
an integer level. `w/lock` pushes onto a thread-local list of held locks and
asserts the new level exceeds every level currently held. The thread-local
machinery already exists (`arc.arc:1940`). The global mutex being removed is
structurally deadlock-free; N locks are not. This converts every possible
deadlock into a loud assertion on first execution instead of a hang under
production load. It is what makes the whole project safe to attempt.

**4. Never hold a lock across anything that blocks or runs arbitrary code.**
No I/O, no `sleep`, no network, no `join-thread`, no calling a caller-supplied
fn, no `eval`. `scrape.arc:535` violates this today. The rule bounds hold times
*and* keeps the lock-order graph small enough to reason about: code that cannot
call arbitrary things cannot take arbitrary locks.

**5. Prefer an atomic operation to an atomic region.** Lazy-init wants an
idempotent get-or-create. Counters want CAS. Queues want a queue lock. Only
real multi-object transactions want a region. Most call sites here fall in the
first three buckets.

**6. Idempotence and ordering beat locking.** `rename-user` (`news.arc:257`)
already carries the comment "Written such that news still loads if killed at
any point." That is the same discipline crash-safety needs, and it is the one
that survives lock removal: if any prefix of an operation leaves a loadable
state, the worst a lost race costs is redone work. Extend that comment style to
every operation that gets unlocked.

**7. Consider single-writer instead of locking.** Where contention is real,
funnel writes through one thread fed by a queue and let readers run lock-free
against the already-synchronized tables. Often less code than getting a lock
right, and trivially deadlock-free.

**8. You cannot test races into correctness.** Build three things that are not
tests: (a) the lock-order assert from principle 3; (b) an audit that every
mutated global has exactly one owning lock, driven by grepping mutation sites;
(c) a chaos mode where `w/lock` inserts a random `(sleep 0)` on entry and exit
to widen race windows. *Then* test: use `parallel.arc` to hammer signup,
rename, vote, and fnid-harvest paths, and write `check-user-store-invariants`
(every uid maps to a user that maps back, every profile has a votes file, no
orphaned uids) to run after each stress round. Invariant checkers plus widened
windows plus order asserts is what confidence actually looks like here.

**9. Keep the reentrancy.** The `*arc-atomic-owner*` trick means existing code
assumes it can re-enter freely. Use recursive mutexes throughout, or the first
conversion will deadlock against itself.

## Open question: what clarc actually did

Unverified. The claim that dang removed the global mutex in clarc has not been
checked against clarc's source from this session, and his design is not
reproduced here. Before committing to the phase plan above, diff clarc's
`atomic-invoke` and its call sites against this codebase's and note where the
two designs agree or diverge.

## Suggested first commit

Phase 0 plus principle 3: the per-site instrumentation and the lock-level
assert, before any call site is converted.
