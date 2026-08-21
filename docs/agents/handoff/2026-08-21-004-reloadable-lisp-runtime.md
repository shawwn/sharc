---
name: Making arc0.lisp and arc1.lisp reloadable at runtime
description: `(reload-runtime)` recompiles and reloads the lisp half of the system into a live image in ~290ms; covers what already worked before any change, the three hazards that did not (SSL contexts rebuilt, struct shape changes, defconstant), and the traps found while building it.
type: project
---

# Handoff: a reloadable lisp runtime (2026-08-21)

Two commits: `b9df623` (stop reloading from redoing initialization) and
`b0dbf42` (`(reload-runtime)` itself). Goal was to make `arc0.lisp` and
`arc1.lisp` editable without restarting the image, the way the `.arc` files
already are.

## Start here: most of it already worked

Before any change, `(#'load "arc1.lisp")` in a live image already completed in
264ms and kept arc globals, user-defined arc functions, ssyntax and bracket-fn
reading, tagged types, and the ability to define new code afterwards. Measure
before scoping: the job was never "build reloading", it was "close three
gaps". Anyone extending this should re-measure the same way rather than assume
a mechanism is missing.

## The three gaps

**1. The SSL contexts were rebuilt on every reload.** `arc0.lisp` had
top-level `(try-load-ssl)` and `(when *ssl-available* (init-ssl-ctxs))`.
Measured: the context pointer moved on every reload
(`#X105008200` -> `#X13F00C400`). That is bad twice over. `init-ssl-ctxs`'s
own docstring says it runs at load time "so that no thread ever constructs one
while other threads are running", and per `a20fa35` `SSL_CTX_new` is exactly
what orphaned the method-store lock and wedged the image for nine hours; the
contexts are also never freed, so each reload leaked the old pair.

`init-runtime` now holds the initialization and is idempotent, with `:force`
for a deliberate rebuild.

**2. A struct whose shape changed cannot be applied to a live image.**
`gcell` (`arc0.lisp`) and `arc-tagged`. Instances built under the old layout
stay reachable. SBCL signals on the redefinition, which under `--script`
aborts the load part-way and leaves half the file applied.

**3. Two definitions of the `:arc` package** (arc0 without exports, arc1 with)
made every reload of either file warn about package variance.

## What was decided, and why the obvious version is wrong

**`init-runtime` is called from arc0.lisp, not from boot.lisp.** The original
plan was to move initialization up to the boot layer. The code says no: the 21
`define-alien-routine` forms are gated on `*ssl-available*`, so `try-load-ssl`
must run at load time, ahead of them; and `arc1.lisp`'s header advertises
`sbcl --load arc1.lisp`, which would come up with no SSL at all. So
`try-load-ssl` keeps its own `unless` guard and `init-runtime` is called at the
end of the load.

**The struct check reads the source rather than a version stamp.** The
original sketch was a hand-maintained stamp on each struct. Comparing the
source's `defstruct` slot lists against `sb-mop:class-slots` of the live
classes cannot go stale, and it runs *before* anything is compiled:

```
reload-runtime: refusing, struct shape changed:
  gcell: live (name value), source (name extra-slot value)
  live instances cannot be migrated; restart the image.
```

**Constants do not need a restart** (an earlier claim in this session was
wrong, and was checked): re-evaluating `defconstant` with an unchanged value
is silent, and a changed value signals the continuable `defconstant-uneql`,
which the reloader continues while naming the constant. All four constants are
referenced only inside `arc0.lisp`, so the reload recompiles every user of
them.

## Traps found while building it, all of which cost a cycle

- **A temp-directory fasl does not work.** `arc0.lisp` resolves `setup.lisp`
  against `*load-truename*`, which during the load of a fasl is *the fasl's
  own path*, so loading from `/tmp` looks for `/tmp/setup.lisp`. The fasls are
  written beside the source and deleted under `unwind-protect`.
- **`defconstant` fires at compile time.** It carries an implicit
  `eval-when (:compile-toplevel)`, so `defconstant-uneql` is signalled during
  `compile-file`, not only during `load`. The first version handled the load
  phase only and the process died on the test. It also means a changed
  constant takes hold during the compile step and survives a later compile
  failure: constants are the one thing the all-or-nothing property does not
  cover.
- **Compiling `arc1.lisp` used to load `arc0.lisp`** through its `eval-when`,
  which would redefine things during the step meant to validate them. It now
  loads arc0 only `(unless (find-package :arc))`. Consequence worth knowing:
  editing arc0 and then `(load "arc1.lisp")` by hand no longer picks arc0 up;
  `(reload-runtime)` is the supported path.
- **Testing a compile failure has to mutate the file from inside the running
  image.** Appending a bad form from the shell first just stops `./sharc` from
  booting, since the image boots out of the file being broken. The test script
  reads `arc0.lisp` into a string, writes a mutated copy, reloads, checks, and
  restores.

## How it was verified

Each property was tested by mutating `arc0.lisp` from a running image and
restoring afterwards (byte-for-byte, md5-checked at the shell as well):

- compile error: a canary function was appended next to an invalid lambda
  list; after the refused reload the canary was still undefined, so not even
  the valid half was applied.
- changed constant: reported `new value for +cl-to-unix+` and reloaded.
- changed struct: refused, listing live and source slots.
- normal path: 290ms, arc state kept, SSL context pointer unchanged across two
  reloads, no leftover fasls, repeatable, and `(reload-runtime)` works from the
  repl.

`./sharc test.arc` reports **927 passed, 0 failed**, before and after. Nothing
in `test.arc` covers the reloader itself.

## Still open

- **Reloading under a live server is untested.** SBCL swaps `fdefinition` per
  symbol atomically, so a thread mid-call finishes in the old code, but the 14
  `defmethod`s and `defclass arc-ssl-stream` update live SSL streams lazily,
  and nothing refuses to reload while srv threads are running. Item 7 of the
  original plan (refuse to reload while threads are live, or take the SSL
  region's lock) was not done.
- `arc-reload-*.fasl` can be left behind in the source directory if the image
  dies mid-reload. Nothing cleans them up on the next run.
- The struct check only knows about top-level `defstruct` forms in the two
  runtime files; anything else that changes layout (a `defclass`, say) is not
  checked.
