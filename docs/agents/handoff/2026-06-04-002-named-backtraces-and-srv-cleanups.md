---
name: named-backtraces-and-srv-cleanups
description: Made arc function names appear in SBCL backtraces (named lambdas with combined enclosing names, captured before thread unwind), plus small srv/app cleanups (only arity, get-user thread-local default, header* dedup, dead async op removal).
type: project
---

# Handoff: named backtraces and srv cleanups (2026-06-04)

Five commits on top of the previous handoff
(`1a633a8 arc.arc: add optional cmp to seq fns; rebuild membership ops on mem`).

## Commits

| sha | what |
|---|---|
| `09e6b95` | arc: show arc function names in backtraces (the main work) |
| `7892713` | arc.arc: accept extra args in `only` |
| `722bbb9` | app.arc: default `get-user`'s req to the thread-local |
| `82e5298` | srv.arc: derive `header*` from the text/html type-header |
| `ab0d867` | srv.arc: remove the unused async `a` op |

## Named backtraces (`09e6b95`, the big one)

Goal: when arc code errors, show the **arc** function names in the SBCL
backtrace instead of anonymous lambdas. Touches `arc1.lisp` (compiler)
and `arc0.lisp` (thread error reporting), with a test in `test.arc`.

### How names attach (`arc1.lisp`)

Each fn now compiles to `(sb-int:named-lambda NAME ...)` instead of a
bare `(lambda ...)`. The name comes from the binding site via a **name
marker**: a one-element list `(name)` pushed onto `*env*` (it's a cons,
so `lex-p`, which tests symbols with `eq`, ignores it). Two sources push
markers:

- `ac-set1` (assignment): `(= foo (fn ...))` / every `def` pushes `(foo)`
  around the fn value. `ac-fn-value-p` detects fn values.
- `ac-call`: an fn-valued argument of an immediately-applied fn is named
  after its parameter. Since `let`/`with` expand to `((fn (f) ...) val)`,
  the value in `(let f (fn ...) ...)` is named after `f`. See
  `ac-named-args`.

`ac-fn` does **not** consume the marker (an earlier draft did). It reads
`ac-fn-name`, which joins **every** marker in scope, outermost first, so
a fn nested in foo then bar is `foo--bar`, and a let value inside it is
`foo--bar--f`.

### Two non-obvious constraints (both are load-breaking if you regress)

1. **A named-lambda is illegal in operator position.** `((named-lambda
   ...) args)` won't compile (`COMPILED-PROGRAM-ERROR`), though
   `((lambda ...) args)` is fine. arc's `let`/`with`/`or=` expand to
   `((fn ...) ...)`, so `ac-call` and `ac-safe-call` now emit those
   calls under `funcall` (`(funcall (named-lambda ...) args)`), which is
   legal. SBCL still inlines `(funcall (lambda ...) ...)` like the direct
   form, so no runtime cost.

2. **arc inherits CL symbols**, so naming a lambda after one is
   dangerous: arc's `>=` *is* `cl:>=`, `car` is `cl:car`, etc. Naming a
   lambda `>=` makes SBCL apply `cl:>=`'s ftype to the body and mis-infer
   types -- e.g. it decided an `or`-gensym must be `REAL` and crashed at
   runtime with "NIL is not of type REAL". `ac-safe-name` copies a lone
   CL-symbol name into a private `:arc-fn` package (no function info
   attached); joined names (`foo--bar`) can't collide since CL has no
   `--` names. Symptom if this breaks: `./sharc test.arc` dies in
   test-numeric on `(>= 5.0 5.0)`.

### Capturing the trace before unwind (`arc0.lisp`)

`new-thread` used `handler-case`, which unwinds the stack to the thread
entry **before** running the handler, so `arc-report-error`'s
`map-backtrace` saw only `arc--new-thread`. Switched to `handler-bind` +
`(block done ... (return-from done nil))` (the pattern the REPL `arc-tl2`
already used), so the backtrace is taken with the arc frames still live.
This is why server-request errors (handled in a `new-thread` via the
`thread` macro) now show `item-page` etc.

### Known limitation (intentional)

Tail calls are still merged by SBCL, so a purely tail-called frame
(`(def bar (y) (foo y))`) does **not** appear. TCO is left intact on
purpose: arc's core iteration (`reclist`, `recstring`, recursive `afn`)
is tail-recursive and would overflow the control stack without it. The
user was offered an opt-in `(restrict-compiler-policy 'cl::debug 3)`
toggle / boot flag to disable tail-merging and chose **leave as-is**.
Names only show on non-tail frames.

### Testing the names

`(sb-kernel::%fun-name fn)` reads a fn's compiled name from arc. The
`fn-names` test in `test.arc` uses it; note that because the test bodies
run inside `test-fn-names`, the names there combine to e.g.
`test-fn-names--fn-names-simple`.

## Small cleanups

- `7892713` **`only` arity**: `(def only (x) x)` crashed under `&`
  composition (`only&>`), because `andf` passes all args to each branch:
  `(only&> 1 2)` calls `(only 1 2)`. Now `(def only (x . args) x)`.
- `722bbb9` **`get-user` thread-local**: now `(def get-user ((t req)) ...)`,
  a `(t req)` fallback param that defaults to `(the req)`. `srv.arc` calls
  `(get-user)` with no arg (the request thread already binds `(the req)`).
- `82e5298` **`header*` dedup**: `header*` is now `(type-header* 'text/html)`
  instead of a duplicate literal. This flips its status line HTTP/1.1 ->
  HTTP/1.0, matching the rest. Verified harmless: the server sends
  `Connection: close` and closes the socket after every request
  (`handle-request-thread`'s `(after ... (close i o))`), with no
  Content-Length / chunked, i.e. the 1.0 close-delimited model
  throughout. Decided **not** to move to 1.1 (would require adding
  `Connection: close` to `rdheader*` and buys nothing without keep-alive).
- `ab0d867` **dead op**: removed `defop-raw a` and the `jfnurl*` ("/a")
  binding; nothing referenced the endpoint.

## Status

`./sharc test.arc` => **354 passed, 0 failed**. `news.arc` loads clean.
Branch `main`, 5 commits ahead of `origin/main` (not pushed). No known
pre-existing failures introduced.
