---
name: Synchronize all hash tables in sharc
description: Pass `:synchronized t` to every `make-hash-table` in arc0.lisp — the user-visible `(table)` constructor and the two internal globals (`*arc-globals*`, `*arc-fn-signatures*`). Closes the `coros*` race noted in handoff 2026-04-28-001 at the runtime level rather than per-call-site. Default for now; revisit if perf complaints surface.
type: project
---

# Handoff: synchronized tables — 2026-04-28

Pass `:synchronized t` everywhere sharc constructs a hash table.
Three sites in `arc0.lisp`:

```diff
-(defvar *arc-globals*       (make-hash-table :test #'equal))
-(defvar *arc-fn-signatures* (make-hash-table :test #'equal))
+(defvar *arc-globals*       (make-hash-table :test #'equal :synchronized t))
+(defvar *arc-fn-signatures* (make-hash-table :test #'equal :synchronized t))

 (xdef table (&rest args)
-  (let ((h (make-hash-table :test #'equal)))
+  (let ((h (make-hash-table :test #'equal :synchronized t)))
     (when args (arc-call1 (car args) h))
     h))
```

Test suite still 207/207. `examples/coroutines.arc` produces the
same output it did before. Closes the open issue from
`2026-04-28-001`: the `coros*` hash race during concurrent
coroutine spawn startup is now gone at the runtime level, with no
change to the example file.

## Why we hit this

The `2026-04-28-001` refactor introduced a `coros*` global table
mapping `(current-thread) → coro`. At spawn time, multiple coro
threads can be in their startup code (`(= (coros* (current-thread))
c)`) concurrently — true on demo setup (four spawns in quick
succession) and any time a coroutine body calls `add-coro` mid-body.
SBCL's default hash tables aren't safe under that, even on
different keys: chain pointers and resize machinery are shared
state that a concurrent reader/writer can corrupt.

This isn't unique to coroutines — it's a property of arc threading
generally. Any threaded arc program that shares a table across
threads has the same issue, the coro example just made it visible.

## Why synchronize-by-default and not opt-in

This was the part I went back and forth on, so writing it down for
next time.

The conventional pick is opt-in: provide `(table :sync t)` or a
separate `sync-table` constructor, document that cross-thread
shared tables need it, leave normal tables fast. That's how
Java/Clojure/Python ended up — `ConcurrentHashMap`, atoms,
threading.Lock. The argument is "most code is single-threaded, so
default to fast and pay for safety only where you need it."

I argued for opt-in initially. The reasons I flipped:

1. **The perf cost is small in absolute terms** — uncontended
   pthread mutex on Apple Silicon is single-to-low-double-digit
   nanoseconds. Hash ops in arc are already going through dynamic
   dispatch and the arc runtime; the mutex is a small fraction of
   total cost. You won't notice it interactively, you'd notice it
   in tight hash-heavy loops, and sharc isn't running those.

2. **The safety value is real and recurring**. Multithreaded arc
   bugs are some of the worst to debug — they manifest under load,
   under timing, often only on certain hardware. Closing the
   footgun at the runtime is a one-line change that prevents a
   class of bugs forever. Per-call-site `atomic` wraps are the
   kind of thing that gets forgotten.

3. **sharc is a personal dialect, not a production runtime**.
   Nobody's benchmarking it. The cost-benefit looks different from
   "language implementation that ships to thousands of users."

4. **ARM (Apple Silicon)**: weaker memory model means under-
   synchronized cross-thread code is more likely to manifest as
   visible bugs (stale reads, reordering) than on x86 with TSO.
   Both the cost and the safety value go up on ARM; in this
   specific context the safety side dominates.

   (Honest note: `(4)` is a smaller effect than `(1)–(3)`. ARM
   was the prompt to revisit, not the deciding factor on its own.)

## Trade-off acknowledged

Every hash op in sharc now pays a mutex acquire. If a workload
shows up where this matters — tight inner loops over hash tables —
two relaxations are available:

- Add a `:sync` flag to `(table)` that defaults to `t`, so hot
  tables can opt out: `(table :sync nil)`.
- Or split: keep user `(table)` synchronized, expose a separate
  `(unsync-table)` for advanced use.

Neither is needed yet. Revisit when there's evidence.

## What dang says (answered 2026-04-28, folded in 2026-08-02)

Asked dang what clarc does while making this change. **Reply
received the same day; it confirms the choice made here.** Verbatim:

> I set :synchronized for every table. Btw weak hashtables dont work
> well with :synchronized - I got burned by that.
>
> Eventually dropped Arc's global atomic-invoke form because it was
> too much of a bottleneck.

Three things follow.

1. **Synchronize-by-default is validated.** clarc, with a longer
   history of arc-on-CL use than sharc, independently made the same
   call. The opt-in relaxations sketched under "Trade-off
   acknowledged" above stay available but there is now no evidence
   pulling toward them. Consider that open question closed.

2. **Weak hash tables are the exception, and the blanket rule hides
   it.** `:synchronized t` does not make a weak table safe, because
   weakness is implemented by the GC, which runs outside the table's
   mutex. This has its own writeup:
   `docs/agents/plans/2026-08-02-002-weak-tables-and-synchronized.md`.
   sharc has no weak tables today, so nothing is broken; read that
   doc before adding the first one.

3. **The global mutex is a known bottleneck in practice, not just in
   theory.** "Eventually" is doing real work in that sentence: clarc
   shipped with `atomic-invoke` for a while before removing it. This
   is direct corroboration for
   `docs/agents/plans/2026-08-02-001-remove-global-mutex.md`. What
   the reply does *not* say is what replaced it; see that plan's
   open-question section.

### Footnote: "every table" is no longer literally true here

As of `0d6e994` (compile-time global cells, handoff
`2026-07-27-001-global-cells.md`), `*arc-globals*` is deliberately
**not** `:synchronized`. Reads and writes of a bound global are now a
plain struct slot access, and only cell *creation* is serialized, by
a dedicated `*arc-globals-lock*`. That is a considered deviation from
the policy in this doc, not an oversight.

Still synchronized, and matching dang: the `(xdef table)` and
`(xdef isotable)` constructors, `*arc-fn-signatures*`, and the
socket-option tables. The one other unsynchronized table is a local
`eq` table inside `arc-heap-hist`, built after a full GC inside a
single debug call, where it cannot be shared.

(References here are by name rather than `arc0.lisp:NNN` on purpose;
that file moves often enough that line numbers in docs go stale
quickly.)

## Things this does NOT fix

The `2026-04-28-001` handoff also flagged a second issue:
`kill-coro` uses `terminate-thread`, which is async and forced —
fine at world shutdown when nothing is awake, dangerous if used to
kill a running coro. Synchronized tables don't help with that;
the cooperative analogue is still `(= c!cancel t)` plus a body
that checks the flag at each yield. Documented but not implemented.

## Current state

- `arc0.lisp`: three call sites updated, no other changes.
- `examples/coroutines.arc`: unchanged. `coros*` is just `(table)`
  and now inherits `:synchronized t` automatically.
- Test suite: 207/207.
- ~~Open question: dang's clarc choice may inform whether we keep
  the global default or move to opt-in.~~ **Resolved 2026-04-28,
  folded in 2026-08-02: clarc synchronizes every table too. Keep
  the global default.** See "What dang says" above; note the two
  caveats it raised (weak tables, and the global mutex as a
  bottleneck), each of which now has a plan doc.
