# Weak Hash Tables and `:synchronized`

## Original Request

> Any thoughts on this convo? What do you think Dan meant re: weak tables and
> synchronized?

Prompted by dang's reply (2026-04-28) to a question about how clarc handles
hash table thread safety:

> I set :synchronized for every table. Btw weak hashtables dont work well with
> :synchronized - I got burned by that.
>
> Eventually dropped Arc's global atomic-invoke form because it was too much of
> a bottleneck.

This doc covers the middle sentence. The third is
`2026-08-02-001-remove-global-mutex.md`; the first is settled and folded into
handoff `2026-04-28-002-synchronize-all-tables.md`.

## The claim

**`:synchronized t` does not make a weak hash table safe, because weakness is
implemented by the garbage collector, which runs outside the table's mutex.**

sharc's policy is "every table is `:synchronized t`" (the `(xdef table)` and
`(xdef isotable)` constructors in `arc0.lisp`; referenced by name rather than
line number because that file moves often). That policy is correct and dang
independently arrived at it. But it
creates a false sense of coverage: the one category of table where the rule
does not deliver what it appears to deliver is exactly the category nobody
thinks about, because the rule is applied automatically by the `(table)`
constructor.

## Why

A synchronized hash table's mutex serializes the **Lisp-level accessors**:
`gethash`, `(setf gethash)`, `remhash`, `clrhash`. Those are the operations
that take the lock.

Weak-entry removal is not one of them. When the collector determines that a
weakly-held key is otherwise unreachable, it removes the entry itself. It does
not acquire the table's mutex to do so, and it cannot be made to: GC runs with
the world stopped and cannot block on a lock some application thread might be
holding.

So the guarantee you actually buy with `:synchronized t` is *mutual exclusion
against other Lisp threads*, and nothing at all against the collector. The
invariant people assume they are buying, "between my two operations nobody
changed this table", is false for weak tables. `sb-ext:with-locked-hash-table`
around both operations does not fix it either, for the same reason: the GC is
not a participant in that lock.

This part is structural. It follows from where weakness is implemented, not
from any particular SBCL version.

> **Note for whoever is adding `call-w/locked-table`.** As of 2026-08-02 there
> is an in-flight (uncommitted) `arc0.lisp` addition exposing
> `sb-ext:with-locked-hash-table` to Arc as `call-w/locked-table`. That
> primitive is the right tool for making a multi-step update atomic against
> *other threads*, which is what it is presumably for. It is worth writing into
> its docstring that it gives **no** protection against weak-entry culling, so
> it must not be used to build a check-then-act sequence over a weak table.
> Holding the table lock is exactly the intuition this doc is warning about.

### Aggravating factor 1: rehash-on-access turns reads into writes

`eq` and `eql` tables hash on object address. A moving collector invalidates
those hashes, so SBCL marks the table as needing rehash and performs the rehash
lazily, on the next access. A nominal *read* therefore mutates the table's
internal structure.

With `:synchronized t` that rehash is at least serialized against other Lisp
threads, so this is not independently fatal. It matters because it widens the
window during which the table's internals are in flux, and that window now
overlaps with GC-driven culling that the lock does not cover.

### Aggravating factor 2: lock ordering against GC and finalizers

Weak tables travel with the finalizer and weak-pointer machinery. Post-GC
processing can run in a context that subsequently wants a table lock. Since
essentially any allocation can trigger a GC, application code holding a table
lock while allocating supplies the other half of a lock-ordering cycle. This
area has a history of reported hangs.

### Aggravating factor 3: this combination has had real bugs

Beyond the structural argument, weak plus synchronized has had genuine SBCL
bugs over the years (hangs, corrupted tables), fixed at various points.
"I got burned" reads like hitting one of those in production rather than
reasoning about it abstractly.

## Confidence

Stated plainly, because the two cases imply different mitigations:

- **High confidence** in the structural mechanism above. It is a consequence of
  the design and is not going to be fixed by upgrading SBCL.
- **Low confidence** about which specific failure dang hit, or on which SBCL
  version. If it was a since-fixed bug, today's practical risk is lower than
  the structural argument alone suggests; if it was the structural issue, no
  version will help.

**Worth asking dang directly.** It is a cheap question with a materially
different answer depending on the reply.

## Current exposure in sharc: none

```sh
grep -rn ":weakness\|make-weak-hash-table\|weak-pointer" \
  --include="*.lisp" --include="*.arc" --exclude-dir=lib .
```

returns nothing (verified 2026-08-02). Every table in sharc is a plain `(table)` or `(isotable)`,
both `:synchronized t`, neither weak. Nothing is broken today.

**But the footgun moved closer during the `untangle-features` branch.**
`trivial-garbage` is now vendored (`lib/trivial-garbage`, an ironclad
dependency), so `tg:make-weak-hash-table` is live in the image alongside
`sb-ext:make-hash-table :weakness`. Before that branch, reaching for a weak
table required adding a dependency, which is a natural review checkpoint.
Now it is one call away.

## Where this would actually bite

The tempting candidates, all caches that grow with usage:

| table | why someone would weaken it |
|---|---|
| `items*` (`news.arc`) | items loaded from disk accumulate without bound |
| comment cache (`should-cache-comment` / `uncache-comment`) | rendered comment bodies are large |
| `profs*` | profile cache, one entry per user ever seen |
| fnid tables (`dead-fnids`) | currently timeout-expiry; weakness looks like a simplification |

`items*` is the real risk. "Make it weak so memory does not grow unboundedly"
is the obvious instinct, and it is the one that breaks.

### A concrete failure for this codebase

Suppose `items*` becomes weak-valued while `stories*` and `comments*` stay as
they are, plain lists of ids. The implicit invariant is that every id in
`stories*` has a live entry in `items*`.

Nothing maintains that invariant once the table is weak. The collector culls
any item whose only remaining reference was the table itself. A subsequent
render walks `stories*`, misses in `items*`, and now, post-`untangle-features`,
lands in `(by i)` at `news.arc:269`, which **asserts** on an unresolvable uid.

The failure is timing-dependent, load-dependent, and disappears under a
debugger that keeps extra references alive. It is exactly the class of bug the
synchronize-everything policy was adopted to prevent, reintroduced through the
gap in that policy.

## Rules, if a weak table is ever genuinely needed

1. **Do not rely on `:synchronized` for atomicity.** Treat any weak-table read
   as "may miss at any time, including immediately after a successful write."
2. **No check-then-act across a weak table.** Any invariant spanning two
   operations is unenforceable.
3. **Never let a weak table be the sole guarantor of an invariant held
   elsewhere.** The `items*` / `stories*` example above is the general shape:
   if a strong structure names entries in a weak one, the pairing is broken by
   construction.
4. **Iterate only while accepting that entries may vanish mid-iteration.**
5. **If you still need it**, put the weak table behind your own mutex, ignore
   its `:synchronized` flag entirely, and re-validate after every read. The
   mutex buys ordering against other threads; only re-validation handles the
   collector.

## Recommendation: prefer explicit eviction

Default to **no weak tables in sharc**. Two reasons specific to this codebase:

- Every cache here is bounded by something already under your control (item
  count, comment count, user count), so weakness solves a problem that is not
  actually pressing.
- **The established pattern is already the right one.** The comment cache uses
  explicit eviction via `uncache-comment` (`news.arc:2926`). Explicit eviction
  is reproducible and debuggable; GC-timed eviction is neither. When a bounded
  cache misbehaves you can log it; when a weak cache misbehaves you get a
  Heisenbug that changes under instrumentation.

If unbounded growth becomes a measured problem, add an LRU with a size cap
before considering weakness.

## Detection

Add to the review checklist, and consider wiring into CI:

```sh
if grep -rn ":weakness\|make-weak-hash-table\|weak-pointer" \
     --include="*.lisp" --include="*.arc" --exclude-dir=lib .; then
  echo "ERROR: weak table introduced; see docs/agents/plans/2026-08-02-002-weak-tables-and-synchronized.md" >&2
  exit 1
fi
```

Use `--exclude-dir=lib`, not a `grep -v` on the path. On this setup `grep -r`
emits paths without a `./` prefix, so the obvious `| grep -v "^./lib/"` filter
silently matches nothing and the check passes while reporting every vendored
hit. The exclusion is necessary because `trivial-garbage` legitimately defines
weak structures internally
(`lib/trivial-garbage/trivial-garbage.lisp:106`, `225`) and `bordeaux-threads`
calls `make-weak-hash-table` (`lib/bordeaux-threads/apiv2/api-threads.lisp:27`).

## Open questions

1. **Which failure did dang hit**, structural or a specific SBCL bug, and on
   what version? Determines whether the risk is permanent or historical.
2. **Does clarc use weak tables anywhere now?** If dang got burned and removed
   them, that is a stronger signal than the warning alone.
3. Does the answer interact with removing the global mutex
   (`2026-08-02-001`)? Probably not directly, but any design that replaces the
   world lock with finer-grained caching should not reach for weakness as part
   of the fix.
