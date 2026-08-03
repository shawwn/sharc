# Locking examples

Executable demonstrations of the concurrency properties of sharc's lock
hierarchy. Three of these are regression tests for work that is not
finished, so two of them are *expected to fail* right now. Read the
header comment in each file before concluding anything from its output.

Run them from the repo root:

```sh
./sharc examples/locking/reentrancy.arc
```

(The `#!./sharc` line matches the other files in `examples/`, but a
relative interpreter path does not resolve here, so invoke `./sharc`
explicitly rather than executing the file directly.)

They use threads and sleeps, so each takes a few seconds. `lost-updates.arc`
takes the longest (60000 increments across two threads).

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
| `deadlock-place-then-atomic.arc` | `place-lock*` (40) then `*arc-mutex*` (0), because `placewiths` evaluates the value expression under the lock | **lock-order error** |
| `atomic-interleaved.arc` | an `atomic` block torn by a bare `=`, since the two use different locks | **`*** INTERLEAVED ***`** |

There used to be a `deadlock-table-then-place.arc` here, holding a data
table's own lock via `w/lock` and then assigning inside the body. It is
gone because `lockable` now requires a real lock, one built by
`make-lock` and tagged `'type` `'lock`, so `(w/lock some-data-table ...)`
fails immediately with `Not a lock` and the scenario is unreachable.
Passing a dedicated lock instead is fine and is the intended use: a lock
at level 10 sits *above* `place-lock*` at 40, so assignments inside its
body are ordered correctly.

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
