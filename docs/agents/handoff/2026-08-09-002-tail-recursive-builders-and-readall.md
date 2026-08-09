---
name: Tail-recursive list builders and readall's nil truncation
description: Review-and-commit session for 89501c0; firstn, tuples, rem and trues rewritten with accumulators to survive the 16MB control stack, readall's nil-as-eof truncation fixed, plus the two rewrites that changed behavior by accident and the differential test that caught them.
type: project
---

# Handoff: Tail-recursive builders and readall (2026-08-09)

## What was accomplished

One commit, `89501c0` on `main`: `arc.arc` only, 29 insertions, 26 deletions.
The session was a review of a staged diff that the user revised four times in
response to the review, so the interesting content is not the final code (read
the commit) but **what the intermediate versions got wrong**, since two of the
three problems were silent and neither the test suite nor reading caught them.

Two independent changes ended up in the one commit:

- **`firstn`, `tuples`, `rem`, `trues`** now build their results with an
  internal accumulator `afn` in tail position instead of `cons`-on-return.
  `keep`, `cut` and `bestn` inherit the fix, since they delegate.
- **`readall`** no longer treats a literal `nil` in the stream as end-of-input,
  and `readfile` delegates to it instead of repeating the bug.

Plus two `(whiler ... no)` loops swapped for the equivalent `whilet` in
`allchars` / `allbytes`. `whiler` with `no` as its endval loops while the value
is non-nil, so these are the same loop.

## Why the tail recursion matters here

`sharc` gives SBCL a 16MB control stack (`SHARC_CONTROL_MB:-16`), which is
small enough that ordinary list lengths blow it. This is not theoretical: while
building a test list I hit a hard runtime crash from **`range`**, which is still
non-tail-recursive, at 300000 elements. Not a Lisp backtrace, a
`Control stack exhausted` fault that kills the process.

`news.arc` reaches the fixed functions through `(firstn maxend* comments*)`
(`news.arc:3413`), `(firstn 10000 ranked-stories*)` (`news.arc:651`) and
`(firstn votewindow* _)` (`news.arc:2181`), and `rem` is used all over on
story and item lists. All four now handle 300000 elements.

**`range` and `n-of` were not touched and are still ceiling-limited.** If
anything else starts crashing at large sizes, look there first; the same
accumulator treatment applies.

## The two accidental behavior changes

Both were introduced by intermediate revisions, both were silent, and **both
passed the full 852-test suite**. This is the part worth carrying forward.

**1. `testify` added to `trues`.** One revision wrapped `trues`'s function
argument in `testify`, presumably for consistency with `rem` / `keep` / `some`.
It is wrong for this function. `rem` and `keep` are filters: they use the
predicate to decide and return the *original* elements, so testifying a
non-function argument is a pure win. `trues` returns `fx`, the *result* of
calling `f`, which makes it map-like, and `map` does not testify. So:

- Arguments testify newly admits (symbols, numbers) collect `t` for every hit,
  producing a list whose only information is its length. `(keep 'a xs)` already
  does that job and returns the actual elements.
- Lists and strings used as functions **silently stopped working**.
  `(trues '(x y z) '(0 2))` indexes and gives `(x z)`; testified it becomes an
  equality test and gives `nil`. No error.

Tables survived only by luck: this fork's `testify` (`arc.arc:233`) passes both
`fn` **and** `table` through, unlike stock arc's. So `(trues tbl keys)` kept
working, which is exactly the case one would think to spot-check.

**2. `(> n 0)` rewritten as `(< n 1)` in `firstn`.** When the `(no n)` guard was
hoisted out of the loop, the continue condition `(and (> n 0) xs)` was inverted
into a stop condition as `(or (< n 1) (no xs))`. The correct negation of
`(> n 0)` is `(<= n 0)`, not `(< n 1)`; the two agree on integers and diverge on
everything else. Old `firstn` effectively rounded a fractional count **up**, the
rewrite rounded it **down**:

```
n      old         new
1/2    (a)         nil
5/2    (a b c)     (a b)
```

This matters more in arc than it would elsewhere because `/` yields rationals:
`(/ 5 2)` is `5/2`, not `2`, so `(firstn (/ len 2) xs)` is a call someone
plausibly writes. Nothing in tree passes a non-integer (checked every call site,
including `cut`'s `(- end start)` and `bestn`'s pass-through), so no live bug.
The final version sidesteps the whole class by keeping the original
`(and (> n 0) xs)` predicate verbatim and flipping the branches, which is
better than the `(<= n 0)` that was suggested.

## The readall fix, and what it changes on disk

`readall`'s `eof` argument defaulted to `nil`, and `nil` is a readable datum, so
the reader stopped at the first top-level `nil` in the stream:

```
(readall "(1 2) nil (3 4)")   old => ((1 2))          new => ((1 2) nil (3 4))
```

`readfile`'s `(drain (read s))` had the identical bug via the same default. The
fix is a fresh `(fn ())` closure as the sentinel, which `read` can never
produce, so no datum can collide with it.

Two consequences a future agent should not have to rediscover:

- **This changes what existing data deserializes to.** Any file with a
  top-level `nil` now reads past it rather than truncating there. Affected
  readers: `news.arc:422` (`echo-item-ids`), `app.arc:633` (the `sexpr` form
  field), `scrape.arc:889`, `code.arc`, `prompt.arc`. All move in the
  more-correct direction and none appeared to rely on nil-as-terminator, but
  this was a data-behavior change riding inside what looked like a refactor.
- **The dropped `eof` parameter fails silently, not loudly.** An earlier claim
  in the review that a stale `(readall src 'END)` would raise an arity error was
  wrong. Measured: **functions with an optional parameter silently swallow extra
  arguments in this fork**, while all-required-parameter functions are strict.

  ```
  (readall "1 2 END 3" 'END)  => (1 2 END 3)   ; sentinel ignored, no error
  (tuples '(a b) 2 'junk)     => ((a b))       ; extra arg swallowed
  (firstn 3 '(a b) 'junk)     => error         ; all-required, strict
  ```

  Nothing in tree passes an eof (all nine call sites pass one argument), so
  there is no breakage; but downstream code gets different data rather than a
  crash. If that ever matters, `(o eof (fn ()))` restores the parameter while
  keeping the fix.

## Method: differential testing against the old definitions

The suite passes on every version of this diff, correct or not, so it decided
nothing. What actually caught both bugs was pasting the **pre-change
definitions** into a scratch file under `old`-prefixed names and comparing them
against the live ones across a matrix of arguments:

```arc
(each n (list 3 10 nil 0 -1 1 1/2 5/2 2.5 100)
  (each xs (list nil '(a) '(a b c) '(a b c d e))
    (same (oldfirstn n xs) (firstn n xs) ...)))
```

The matrix has to include the argument *kinds* a function accepts, not just
sizes: functions, bracket-fns, tables, lists-as-functions, strings-as-functions,
symbols, and for `rem` the non-list branch that round-trips through `coerce`.
Every one of those was load-bearing (the table case is what made `trues` look
fine; the list case is what exposed it), and the fractional `n` values are what
exposed the `(< n 1)` slip. Final run reported `ALL EQUIVALENT`.

Two gotchas when writing these probes:

- **The arc loader resolves relative paths against `arc-dir`, not the cwd.**
  `./sharc /abs/path/to/scratch.arc` is required, and a
  `(w/outfile o "x.txt" ...)` in a probe writes into the repo root, not the
  scratch directory. One stray `x.txt` was created and removed this way.
- **Do not build test lists with `(repeat n (push (len xs) xs))`** — `len` is
  O(n), so that is O(n²) and hangs at 300000. Use a counter:
  `(with (xs nil i 0) (repeat 300000 (push (++ i) xs)) ...)`.

## Current state

`main`, one commit ahead of the previous `f949121`, **unpushed**. Working tree
has `news.arc` modified and uncommitted; it is unrelated work (a
`cached-item-ids` / `update-item-bucket` bucket index, with `save-item` writing
the bucket file on first save) and was deliberately excluded from this commit
and from this handoff. It has not been reviewed.

Suite: `./test.arc` reports **852 passed, 0 failed**.

Two things were raised in review and consciously not done, so they are still
open if anyone cares:

1. **The `(fn ())` sentinel in `readall` has no comment.** The reasoning lives
   only in `89501c0`'s message; someone reading `arc.arc` will see an odd empty
   lambda and may "simplify" it back to `nil`, silently restoring the
   truncation bug. A one-line comment is the cheapest insurance here.
2. **The commit was not split.** The stack-safety work and the reader fix are
   independent and would bisect separately, but the staged set was a single
   file with the hunks interleaved and the user asked to commit it as staged.
