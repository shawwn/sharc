---
name: on-err's scope, and calling CL macros from arc
description: Why `on-err` should keep catching `error` and not `serious-condition` (timeouts, deadlines, Ctrl-C must pass through, and the stack-exhaustion case it would seem to buy is fatal under `--script` anyway), plus the working `(#'sb-ext::with-timeout ...)` escape and its two sharp edges.
type: reference
---

# Handoff: `on-err`'s scope and the `#'` escape (2026-08-21)

No code changed. This records a question that came out of debugging the
self-referential item in
[2026-08-21-001](2026-08-21-001-phantom-comments-and-fetched-rename.md):
**should `on-err` catch `serious-condition` rather than just `error`?**

Answer: **no**, and the reasoning is worth keeping because the most obvious
argument for "yes" is wrong for a non-obvious reason.

## `on-err` today

```lisp
(xdef on-err (errfn f)                       ; arc0.lisp:1831
  (handler-case (arc-call0 f)
    (error (c) (arc-call1 errfn c))))
```

`errsafe` is built on it, and the codebase leans on it heavily, especially
across the scrape path.

## The measured condition hierarchy

All four of these are `serious-condition` and **none** are `error`, so
widening `on-err` to `serious-condition` would catch all four:

```
sb-ext:timeout                error: NIL   serious-condition: T
sb-sys:deadline-timeout                    serious-condition: T
sb-sys:interactive-interrupt  error: NIL   serious-condition: T
storage-condition             error: NIL
```

## Why not: the argument that looks strongest fails

The appealing case is stack exhaustion. A cyclic item makes
`cansee-descendant` (`news.arc:698`) recurse until the 16MB control stack is
gone, and it would be nice for `errsafe` to turn that into a failed request
instead of a dead process.

It cannot, because of how `sharc` starts SBCL. `sharc:10` uses `--script`,
which implies `--lose-on-corruption`, and under it control stack exhaustion is
a **fatal runtime abort that no handler ever sees**:

```
--- with --script (what ./sharc uses) ---
fatal error encountered in SBCL pid 47163: Control stack exhausted

--- without --script (--disable-debugger --load ... --quit) ---
handler-case storage-condition: (CAUGHT CONTROL-STACK-EXHAUSTED)
INFO: Control stack guard page reprotected
and again, still alive: CAUGHT-AGAIN
```

So the benefit is zero as long as `--script` is used, and the fix for that
case is the **invocation**, not `on-err`. Note from the second run that
recovery is repeatable: SBCL unprotects the guard page, hands you the
condition, and reprotects it after you unwind, so it survives repeated hits.

## Why not: the other three must pass through

- `sb-ext:timeout` and `sb-sys:deadline-timeout` exist precisely to unwind
  *past* ordinary error handling. The scrape path is full of `errsafe`, and
  `http-slurp-octets` (`arc0.lisp:1331`) takes explicit timeout and deadline
  arguments. If `errsafe` swallowed a timeout, an inner `errsafe` would
  silently defeat an outer `with-timeout` and the operation would carry on.
- `sb-sys:interactive-interrupt` is Ctrl-C. Catching it inside `errsafe` makes
  loops uninterruptible, which given this project's wedged-image history
  (`a20fa35`, `deadlock.txt`, `wedge-78080.txt`) is exactly backwards.

`handler-case (error ...)` is the conventional boundary for these reasons, so
the current definition is already right.

## What to do instead, if the goal is thread survival

If the real goal is "one bad item must not take down a srv thread", handle
`serious-condition` at the **thread boundary**, not inside every `errsafe`.
One place, where a full unwind is affordable and the condition can be logged,
in the spirit of the existing `call-watching-unwind` from `a20fa35`. That
leaves `errsafe`'s meaning intact everywhere else. It still cannot rescue
stack exhaustion while `--script` is in use.

## Calling CL macros from arc

`#'` reaches CL macros, not just functions. **The double colon is required**:

```arc
(#'sb-ext::with-timeout 5 'quick)     ; => quick
(#'sb-ext:with-timeout  5 'quick)     ; => The function ARC::|SB-EXT:WITH-TIMEOUT| is undefined
```

The single-colon form fails because arc's reader does not treat `:` as a
package separator, so the whole thing interns as one symbol in `ARC`. This is
now noted in CLAUDE.md.

Two sharp edges when using it for probes:

- **`on-err` will not catch the timeout.** `sb-ext:timeout` is a
  `serious-condition`, so it escapes `on-err` and kills the script. Useful
  enough for a probe (the output shows how far it got) but you cannot collect
  a per-case "timed out" result that way. Catching it properly needs
  `handler-case` with a typespec clause, and **that does not translate through
  `#'`**: the clause list is macro syntax rather than evaluated arguments, so
  arc compiles `(#'sb-ext::timeout (c) ...)` as arc code and the
  macroexpansion fails. A CL helper function would be needed.
- **A stack-exhausting loop can outrun the timer.** A non-tail-recursive cycle
  blew the 16MB stack before a 2s deadline fired, and doing that inside
  `with-timeout`'s machinery took SBCL down fatally. `with-timeout` reliably
  bounds a *spinning* loop (`superparent`'s tail call, say), not a *recursing*
  one.

This corrects
[2026-08-21-001](2026-08-21-001-phantom-comments-and-fetched-rename.md), which
says `with-timeout` "does not work because it is a macro". It does work; the
single colon was the bug.

## Reproducing

The probes were plain `sbcl --script` / `--load` runs of a few `subtypep` and
`handler-case` forms plus a `(defun deep (n) (1+ (deep (1+ n))))`, with
`--control-stack-size 16` to match `sharc`'s default (`SHARC_CONTROL_MB:-16`).
Nothing arc-specific is needed to re-derive any of it.
