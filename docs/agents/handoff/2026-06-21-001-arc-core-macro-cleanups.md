# Arc core macro cleanups + a few news/srv fixes

Date: 2026-06-21

A session of small, self-contained refactors to the arc core (`arc.arc`,
`arc1.lisp`) plus a handful of news/srv fixes. Each landed as its own
commit after review and a full `./test.arc` run. Range
`f3caa21..4e6a555` (16 commits) on `main`.

## What was accomplished

Arc core (`arc.arc` unless noted):

- **`f3caa21`** docs: CLAUDE.md note for the `(t var)` thread-local
  fallback param: `(t var)` => `(o var (the var))`, `(t local var)` =>
  `(o local (the var))`. See `examples/the.arc`.
- **`483beea`** `pair`: flattened, and the leftover odd element now has
  `f` applied (`(cons (f (car xs)) nil)`) instead of being wrapped via
  `list`. Only differs when a non-default `f` is passed.
- **`1c9a3af`** `or=` rewritten **variadic** and **unbound-safe**, plus
  new **`w/defs`** (Scheme-style internal defines: predeclares each
  `(def name ...)` in the body so they bind locally / mutually recurse).
  `or=` takes any number of place/value pairs; for a never-bound global
  it assigns instead of erroring (`(and (bound ',var) ,var)` in the
  getter); compound places go through `setforms` so subforms eval once.
  Exported **`lex`** (`lex-p`) in `arc1.lisp` so the getter tells lexical
  vars from globals. Tests added (`test.arc`, `define-test or=`).
- **`4446c90`** defcache cell init uses the new `or=`.
- **`1a7852a`** moved `check` up next to `or` (pure relocation; the
  earlier attempt to also rewrite `or` in terms of `check` was
  **rejected** — see Key decisions).
- **`ac0dc12`** `and` flattened from nested `if` into a single
  cond-style `if`. Behavior-identical.
- **`a26259e`** **`w/assign`** extracted from `w/the` for temporarily
  rebinding *any* place (save -> set -> body -> restore in an `after`,
  so it unwinds on error/thread-kill). Routes the place through
  `setforms` for single-eval. `w/the` is now `w/assign` over `(the var)`,
  unchanged. Tests added (`define-test w/assign`, incl. double-eval
  protection).
- **`ef77032`** `list` simplified to `(def list args args)` (valid
  because the SBCL host passes `&rest` as proper nil-terminated lists);
  `copylist` reimplemented as `(apply list x)`.
- **`2d3ec93`** `%scope` dedup loop collapsed to
  `(dedup:keep [isa _ 'sym] env)`. `dedup` keeps the first occurrence in
  order, so the innermost binding of a shadowed name still wins.
- **`bdb3757`** `mac` defined before `def`; `def` redefined as a real
  `(mac def ...)`. `def` now also supports **value definitions**:
  `(def name x)` with no body => `(safeset name x)`. `app.arc`'s
  `fail*` sentinel respelled `(def fail* () nil)` so it stays a nullary
  fn under the new no-body rule (a bare `(def fail* ())` would now define
  nil). `sig` is host-defined (`arc0.lisp`), so the reorder is safe.
- **`4eca201`** `arc1.lisp`: `!` ssyntax builds its quote with
  `(arc-sym 'quote)` instead of CL's `'quote`. CL quote prints `QUOTE`
  (uppercase) while the reader and other ssyntax expanders use the arc
  `quote`; now `a!b` expands to the same form as `(a 'b)`. Safe because
  `ac` dispatches quote case-insensitively (`arc-sym=` = `string-equal`).

News/srv:

- **`e1da9db`** `npage` favicon link uses `gentag` (matches the adjacent
  CSS link; identical HTML minus a cosmetic trailing newline).
- **`74e1d59`** `ip` moved fully off the request object onto the
  `(the ip)` thread-local: dropped from the `request` template, no longer
  set in `respond`, and `get-user` reads it via `(ip)`. Added a matching
  `(def op () (the op))`. (`req!ip` had only one reader; verified zero
  remain.)
- **`996767f`** `(xdef repl #'arc-tl)` exposes the interactive top-level
  as `repl`; `prompt.arc`'s web-repl form-builder renamed `repl` ->
  `replform` to free the name (the `/repl` op and `replpage` unchanged).
- **`935659b`** extracted `display-comments` from `display-comment-page`
  (defaults `indent 0 / initialpar t / initialon t` match the old call
  site). Behavior unchanged.
- **`4e6a555`** `fnid-key` keys on `(the op)` instead of `req!op`. `op`
  isn't a request field (it's the thread-local), so `req!op` was always
  nil and never distinguished fnids.

## Key decisions

- **`or=` single-eval via `setforms`, not the simpler getter.** An
  earlier getter-only version spliced the place 2-3x and double-evaluated
  side-effecting subforms; the `setforms` route hoists subforms once.
  The unbound-global fix is `(and (bound ',var) ,var)` (not `(bound
  ',var)` alone, which is a boolean `t` even for a global bound to nil
  and so wouldn't reassign a nil global).
- **`w/assign`, not `w/set`.** Arc already has `set` meaning "set place(s)
  to `t`"; `w/set place val` would mislead. `assign` is the value-setting
  primitive, so `w/assign` is accurate. (`w/value` was rejected as too
  vague — it hides the restore-on-exit semantics.)
- **`w/assign` is deliberately non-atomic.** A genuinely atomic
  dynamic-bind would hold the global lock across the body; a precautionary
  `atomic-set` front half was tried and dropped (it only protected
  save+set, not the restore or body, so it gave false safety). Comment in
  `arc.arc` records this.
- **`or`-on-`check` rewrite rejected.** Folding `or` into `check` to save
  ~3 lines was declined: it couples a foundational primitive (`or`, used
  everywhere) to a convenience macro for marginal gain. Only the
  relocation of `check` was kept.

## Important context for future sessions

- **Tests**: `./test.arc` (443 passing, 0 failing as of this handoff). It
  loads `arc.arc` + `libs.arc` only; news/app code isn't exercised, so
  `app.arc`/`srv.arc`/`news.arc` regressions won't show up there — load
  `news.arc` and smoke-test the path directly.
- **Staged-only verification** was done with `git stash push
  --keep-index` then `git stash pop`. **Caution**: on a file that is both
  staged and unstaged (`MM`), the pop can conflict and leave
  `<<<<<<<`/`=======`/`>>>>>>>` markers in the working tree (an arc source
  file with a conflict marker fails to load with `Unbound variable:
  <<<<<<<`). Happened once this session and was resolved; prefer testing
  the working tree directly when a file is `MM`.
- **Known pre-existing bug, not fixed**: `fnid-key` (`srv.arc`) also reads
  `req!type`, which is always nil — the `request` template has no `type`
  field and `respond` doesn't set one, so `(when (is req!type 'get) ...)`
  never fires and GET args are never folded into the fnid key. Same root
  cause as the `req!op` bug fixed in `4e6a555`, but the request type isn't
  threaded into `respond`, so fixing it needs plumbing (there's no
  `(the type)` to swap in).
- **Uncommitted exploration is NOT in history** (left in a `git stash`,
  intentionally excluded from this handoff per request): a larger
  `arc.arc` bootstrap rework, a name-deriving `def` (`defname`, so
  `(def (tbl 'k) ...)` lambdas get readable backtrace names), `nsv-async`,
  and a `displayfn*!story` place-def. The committed `!`-quote fix
  (`4eca201`) was extracted from that line of work. If you pick it up,
  treat the stash as scratch, not a baseline.
- **Branch `main`**, clean working tree, 13+ commits ahead of
  `origin/main` (unpushed). This handoff commit is the latest.
