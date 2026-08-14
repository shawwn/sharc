# Locking examples

Executable demonstrations of the concurrency properties of sharc's lock
hierarchy. Two of them track work that is not finished and are
*expected to fail* right now. Read the header comment in each file
before concluding anything from its output.

Run them from the repo root:

```sh
./sharc examples/locking/reentrancy.arc
```

(The `#!./sharc` line matches the other files in `examples/`, but a
relative interpreter path does not resolve here, so invoke `./sharc`
explicitly rather than executing the file directly.)

They use threads and sleeps, so each takes a few seconds. `lost-updates.arc`
takes the longest (60000 increments across two threads), and
`phantom-keys.arc` allocates the most (it grows a table to 300000 keys).
`insert-items-drop.arc` and `comment-import-convoy.arc` load `news.arc`,
since they exercise the real `insert-items` and `put-item`.

`lockdump.arc` is not a test. It is a read-only diagnostic to load from a
repl attached to a wedged image: `(lockdump)` reports which locks are
held, by whom, and who is waiting; `(bt <bgthread-id>)` backtraces one
thread. Nothing in it acquires a lock.

## The lock hierarchy

Locks carry integer levels and must be acquired in strictly increasing
order. Re-entering a lock already held is always allowed. See
`arc0.lisp`, `arc-check-lock-level`, and principle 3 in
`docs/agents/plans/2026-08-02-001-remove-global-mutex.md`.

```
 0  *arc-mutex*      atomic
40  place-lock*      =, push, pop, swap, rotate, setmem, togglemem, ++, --, zap, or=
99  table locks      per-table, implicit on every read/write, leaf
```

## The files

| file | demonstrates | expected today |
|---|---|---|
| `reentrancy.arc` | nested `=` and nested `w/lock` on one lock do not self-deadlock | **passes** (`ALL OK`) |
| `lost-updates.arc` | why `call-w/locked-table` must not skip `place-lock*` when it already holds `*arc-mutex*` | **passes** (60000/60000) |
| `insert-items-drop.arc` | a `=` whose value expression reads its own place, racing a correctly locked `push` | **passes** (dropped 0 of 200) |
| `phantom-keys.arc` | `maphash` handing back a key that was never in the table, when a walk overlaps a rehash | **passes** (0 phantoms) |
| `deadlock-place-then-atomic.arc` | `place-lock*` (40) then `*arc-mutex*` (0), because `placewiths` evaluates the value expression under the lock | **lock-order error** |
| `atomic-interleaved.arc` | an `atomic` block torn by a bare `=`, since the two use different locks | **`*** INTERLEAVED ***`** |
| `comment-import-convoy.arc` | `put-item` once per element oversubscribes `rank-lock*`, blocking every other writer without any cycle | **`CONVOY REPRODUCED`**, by design |

There used to be a `deadlock-table-then-place.arc` here, holding a data
table's own lock via `w/lock` and then assigning inside the body. It is
gone because `lockable` now requires a real lock, one built by
`make-lock` and tagged `'type` `'lock`, so `(w/lock some-data-table ...)`
fails immediately with `Not a lock` and the scenario is unreachable.
Passing a dedicated lock instead is fine and is the intended use: a lock
at level 10 sits *above* `place-lock*` at 40, so assignments inside its
body are ordered correctly.

## `comment-import-convoy.arc`

`CONVOY REPRODUCED` is this file's **permanent** verdict, not a failure
to fix something. It calls `put-item` directly rather than going through
any importer, so it measures the shape rather than guarding a call site,
and it will keep reporting the convoy for as long as `put-item` costs
O(len list) inside `rank-lock*` — which is inherent to `reinsert-sorted`.
Treat it like `atomic-interleaved.arc`: a standing demonstration, worth
re-running before adding a new per-element `put-item`.

The call site that prompted it, `import-scraped-comments`, now batches:
one lock acquisition and one `merge-item-lists` per story instead of one
per comment.

It is also the only file here about a hazard that no assert can catch:
there is no cycle, no lock-order violation, and SBCL's own
`thread-deadlock` detection stays quiet, because nothing is deadlocked.
The lock is simply oversubscribed, and permanent blocking on a queue that
never drains is indistinguishable from a hang from outside.

Worth noting when reading its output: the *holder* rotates between the
three workers, while the other two are blocked in ~99% of samples. A
single `lockdump` from a live image names whichever thread happened to
hold the lock at that instant, which is not the thread to go fix.

## What "expected to fail" means here

The two deadlock files used to hang. They now produce a loud, immediate
`Lock order violation` instead. That is the assert working as designed,
and it is a large debugging improvement, but the underlying edges still
exist:

- `deadlock-place-then-atomic.arc` goes away once the binds and value
  expression are hoisted out of the critical section in `expand=` and
  `placewiths`. `zap`, `setmem`, and `togglemem` will remain, since
  calling a user function between the read and the write is their whole
  semantics.
- `atomic-interleaved.arc` demonstrates a hazard in the design rather
  than a bug in the tree, and there is currently **no known instance** of
  it. An earlier version of this file said `init-user` was vulnerable to
  `load-prof`'s bare `(= (profs* p!id) p)`; that was wrong, and the file's
  own header now explains why. It stays because the hazard is real
  whenever a composite invariant moves onto its own lock: every other
  writer of that data must take the same lock. Re-run it after each
  remaining `atomic` conversion. No assert will ever catch this one,
  which is why the executable test matters.

Toggling `*arc-check-lock-order*` to `nil` in `arc0.lisp` disables the
assert; the two deadlock files then hang again rather than erroring.
