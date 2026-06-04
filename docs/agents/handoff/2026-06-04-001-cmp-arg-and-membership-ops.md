---
name: cmp-arg-and-membership-ops
description: Threaded an optional cmp arg through the sequence fns, made mem a settable place, rebuilt pushnew/pull/togglemem on it (fixing a load-time macro recursion), reduced iso to an alias for is, and added test coverage.
type: project
---

# Handoff: optional cmp arg and membership ops rebuild (2026-06-04)

One commit on top of the previous session's work
(`80cfa84 arc.arc: use or= in thread-locals instead of explicit or/set`).

## What changed

All in `arc.arc` plus supporting edits to `CLAUDE.md`,
`scrape-verify-flags.arc`, and `test.arc`.

### Optional `cmp` on the sequence fns

`testify` gained an optional second arg `cmp` (default `is`):

```arc
(def testify (x (o cmp is))
  (if (isa x 'fn) x [cmp _ x]))
```

`some`, `all`, `mem`, `find`, `rem`, and `keep` each gained a trailing
`(o cmp is)` that is threaded into `testify` (and through `rem`'s
recursive string branch). This lets callers match with something other
than `is`, e.g. `(find 2 '(1 2 3 4) >)` => `3`.

### `mem` as a settable place; membership mutators rebuilt

Added `(defset mem (x place . args) ...)` so `mem` is now a generalized
place. The mutators are defined in terms of it:

```arc
(mac pushnew (x place . args) `(set  (mem ,x ,place ,@args)))
(mac pull    (test place . args) `(wipe (mem ,test ,place ,@args)))
```

`togglemem` flips the place with `(= (mem ...) (~mem ...))`, using
`atwith` to evaluate `x` and the args once.

### setmem no longer recurses (the bug that was caught)

`setmem` now calls `adjoin`/`rem` **directly**:

```arc
(mac setmem (test x place . args)
  (w/uniq (gt gx)
    (let (binds val setter) (setforms place)
      `(atwiths ,(+ (list gt test gx x) binds)
         (,setter (if ,gt
                      (adjoin ,gx ,val ,@args)
                      (rem ,gx ,val ,@args)))))))
```

An earlier draft of this change had `setmem` expand into
`pushnew`/`pull`, which (now that those expand into `(= (mem ...))` ->
`defset mem` -> `setmem`) formed an infinite macro-expansion loop that
exhausted the SBCL control stack at load time. Verified the fix by
loading clean and running the suite. **If you touch these macros again,
keep the rule: `setmem` is the primitive that does `adjoin`/`rem`;
everything else routes through `mem`-as-place down to `setmem`. Do not
let `setmem` expand back into `pushnew`/`pull`.**

### iso reduced to an alias for is

In this runtime `is` is already a deep (structural) compare, so the
hand-rolled recursive `iso` was redundant. It is now:

```arc
(def iso args (apply is args)) ; kept for backwards compatibility
```

(Shawn made it variadic; `is` itself takes n args.) `adjoin`'s default
test changed from `iso` to `is`, and `scrape-verify-flags.arc` switched
its one `iso` call to `is` (it only compares booleans there).

### CLAUDE.md note

Added: `` `(is x y)` does a deep compare of x and y. For object identity,
use `(id x y)`. `` This is the key fact that makes the iso removal /
`is` defaulting safe; future agents should not assume stock-Arc `is`
(shallow) semantics.

## Tests

Added `define-test` blocks in `test.arc` (inserted after the `list`
test) for: `testify`, `iso`, `some`, `all`, `find`, `mem`, `rem`,
`keep`, `adjoin`, `setmem`, `mem-place` (the `defset`), `pushnew`,
`pull`, `togglemem`. They exercise both the default and `cmp`/test-arg
paths and both the list and string branches. Each expected value was
checked against the live runtime before being asserted (e.g. `find` on
a string returns the matching char; `rem`'s string branch round-trips
through `coerce`).

## Status

`./sharc test.arc` => **350 passed, 0 failed** (was 295 before the new
tests). Branch `main`, all four files committed together. No known
pre-existing failures introduced.
