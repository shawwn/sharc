# The two-level `t` model, case-insensitive symbols, and corner-case tests

Date: 2026-07-04

A semantics-and-tests session. Three threads: (1) staged the pre-existing
`isa` refactor cleanly, isolating it from unrelated working-tree changes;
(2) the bulk of the session, a deep dive into `t`/`nil`/symbol identity
that ended with a **two-level model for `t`**, a case-insensitive
`sym`/`coerce`, and ~81 new corner-case tests documenting it; (3) a small
`news.arc` site-config change. The `t` work was iterative and involved me
being wrong twice (once misreading the semantics as bugs, once over-fixing
`sym`) before landing on the model the user was steering toward.

Session commits on `main` (all at/behind `origin/main` = `d53cbb5`):
`146739e` (isa dual-purpose), `74667ba` (t/symbol semantics + tests),
`d53cbb5` (news site name). Interleaved user commit: `53f87d8` (Move
`only`). The `arc1.lisp` half of `74667ba` was written by the **user**
(the interpreter side of the model); I wrote `arc0.lisp` + `test.arc`.

## What was accomplished

- **`146739e`** `arc: make isa dual-purpose (isa!type predicates)`.
  Redefined `isa` with a rest arg: `(isa x 'type)` still works, and
  `isa!type` (= `(isa 'type)`) now returns a predicate `[is (type _) type]`.
  Collapses the common `[isa _ 'string]` idiom to point-free `isa!string`
  at call sites (`some`/`keep`/`all`/`map`). Staged **only** the
  `isa`->`isa!type` conversions across 12 files (`arc.arc`, `app.arc`,
  `code.arc`, `email.arc`, `html.arc`, `json.arc`, `news.arc`,
  `recaptcha.arc`, `scrape.arc`, `srv.arc`, `strings.arc`, `test.arc`),
  splitting mixed files hunk-by-hunk so unrelated in-progress work stayed
  out. See "Important context" for the staging technique.
- **`74667ba`** `t/nil/symbol semantics: two-level t, case-insensitive
  sym, tests`. Three files:
  - **`arc1.lisp`** (user-authored): `ac-quoted` gained a `fold-t` flag
    and only folds `t` -> the truth value at **top level** (the flag is
    passed from the `quote` case, not through the recursive `arc-imap`
    calls). `ac-qq` folds a bare `` `t `` the same way. Net effect:
    `'t`/`` `t `` are the truth value, but a `t` inside quoted **list**
    data stays a bindable symbol. Makes `(is t 't)` true and
    `(eval '(let t 5 t))` bind correctly (-> 5).
  - **`arc0.lisp`**: new `arc-str->sym` helper, wired into `arc-coerce`'s
    string->sym and char->sym sites. It case-folds to lowercase
    (`(sym "FOO")` is `'foo`, `(sym "T")` == `(sym "t")`) so runtime symbol
    construction matches the case-insensitive reader. It does **NOT**
    canonicalize `t`/`nil` to the truth/empty values: `(sym "t")` is the
    bindable symbol, the same object as the `t` in `'(t)`.
  - **`test.arc`**: ~81 new tests (suite 491 -> 572, all green). A
    `test-is` macro (one `test?` per named `define-test`, so no failure
    masks the next) drives an identity matrix, plus an `(eval ...)`
    section using a `mute`/`eval-quiet` helper (below).
- **`d53cbb5`** `news: set site name to HN Simulator`. `this-site*` ->
  "HN Simulator", `site-desc*` -> "Hacker News simulator". Staged hunk
  only.

## Key decisions

- **The two-level `t` model (the crux).** There are two things spelled
  `t`: the **truth value** (top-level `t`/`'t`/`` `t ``) and the
  **bindable symbol** named `t` (`t` inside quoted list data like
  `(car '(t))`, and `(sym "t")`). They are distinct objects:
  `(is t (sym "t"))` -> nil, `(no (sym "t"))` -> nil (it's a truthy
  symbol). All bindable-symbol paths are the **same** case-insensitive
  symbol: `(is (car '(t)) (sym "t"))` -> t, `(is (sym "t") (sym "T"))`
  -> t. `nil` is **not** split: `nil` anywhere is the empty value
  (`(car '(nil))` is nil); only `(sym "nil")` mints a distinct bindable
  symbol.
- **I was wrong twice; the tests reflect the final model, not my first
  guesses.** First I read the list-vs-top-level `t` difference as a pile
  of bugs and wrote a "least-surprising" contract asserting `t` in a list
  should be the truth value. Then, told to go "case-insensitive-uniform,"
  I made `arc-str->sym` canonicalize `(sym "t")` -> truth value, which
  **broke** `(eval (list 'let (sym "t") 5 (sym "t")))` (5 -> compile
  error) by conflating the symbol with the value. The user corrected the
  premise (`'(t)` holds a bindable symbol on purpose). Final call:
  `arc-str->sym` case-folds **only**; `t`/`nil` are not canonicalized.
- **Case-insensitive-uniform for symbols.** The reader already folds
  symbol case to lowercase (`(id 'foo 'FOO)` -> t, `(coerce 'FOO 'string)`
  -> "foo"), while `sym`/`coerce` used to preserve case. Chose to make
  `sym`/`coerce` match (fold) rather than make the reader case-sensitive
  (huge blast radius). Consequence, flagged and accepted: runtime
  string->symbol now lowercases, so `(sym "userName")` -> `username`, and
  **JSON object keys fold on decode** (`json.arc` uses `(sym k)`). HN's
  API keys are all lowercase, so the scraper/importer is unaffected; only
  mixed-case JSON would fold.
- **`temquote` is still necessary (verified).** A `t` read back from disk
  is the **bindable symbol**, not the truth value (`(is (read "t") t)` ->
  nil), by design of the model. So `temquote` (converts read-time
  `t`/`T` -> t, `nil` -> nil for template field values) still does real
  work: without it `(to-json (obj deleted (read "t")))` gives
  `{"deleted":"t"}` instead of `{"deleted":true}` (the exact bug its
  comment cites). The `("t" "T") t` branch is load-bearing; the
  `"nil" nil` branch is now effectively dead for read-back values
  (`(read "nil")` already yields real nil) but harmless.
- **Deferred, not fixed: position-aware canonicalization.** The clean
  long-term fix for the remaining `t` ambiguity (fold in value position,
  keep in binding position, so quote/quasiquote/list/sym all agree) would
  live in `ac`, not in the quoter. Out of scope; the current top-level-vs-
  nested split is the pragmatic middle ground and is now the documented
  contract.

## Important context for future sessions

- **Tests: 572 passed, 0 failed.** `./test.arc` loads
  `arc.arc`+`libs.arc`+app/html/json but **not** `news.arc`/`scrape.arc`.
  The `74667ba` trio (`arc0.lisp`/`arc1.lisp`/`test.arc`) is
  self-sufficient: verified by `git stash push -- arc.arc json.arc
  news.arc scrape.arc` then `./test.arc` -> still 572/0, then
  `git stash pop`.
- **`arc-str->sym`** (`arc0.lisp`) is now the single string->symbol
  entry for `sym`/`coerce`: `(intern (string-downcase str) :arc)`. If you
  ever want `(sym "t")` to be the truth value, that is the place, but it
  would re-break bindable-`t` construction; don't, unless you also move
  canonicalization into `ac`.
- **The `mute`/`eval-quiet` test helper** (`test.arc`): `eval-quiet`
  runs `(eval form)` under `on-err` returning the sentinel `'ERROR`, and
  `mute` wraps the call in
  `` #`(cl::let ((cl::*error-output* (cl::make-broadcast-stream))) (arc::arc-call0 #,thunk)) ``
  to swallow SBCL's compile-error chatter (the illegal-`t`-param errors
  print notes to `*error-output*` even when caught). This is why the eval
  section can assert `'ERROR` outcomes with a clean suite. Note: `#,`
  splices a value into **operand** position only; it does **not** splice
  into a nested `cl::quote` (that cost me several probes).
- **Eval round-trip semantics documented in the tests:** building
  `t`-binding code with `'t` (the truth value) errors
  (`(eval (list 'let 't 5 't))` -> illegal param); building it with
  `(sym "t")` or a list-literal `t` works (-> 5). `` `(let t 5 ,'t) ``
  returns the truth value `t` (body is the value, not the binding), not 5.
- **Staging technique for mixed files** (used in `146739e`): back up the
  working file, `git checkout HEAD -- FILE`, re-apply only the wanted
  edits, `git add FILE`, then restore the full working copy from backup.
  Leaves the index with just the intended subset and the working tree
  fully intact. Used to isolate the `isa` conversions from unrelated
  in-progress changes in `arc.arc`/`news.arc`/`scrape.arc`/`json.arc`.
- **Working tree**: on `main`, level with `origin/main` (`d53cbb5`) plus
  this handoff. **Uncommitted/unstaged changes kept deliberately out of
  every commit** - do not sweep them in: `arc.arc`, `json.arc`,
  `scrape.arc`, and the non-config parts of `news.arc` still carry the
  leftover non-`isa` work from prior sessions (e.g. `pr` output filtering,
  `only`/`clamp`, `uneschtml` removals in `scrape.arc`, the item-bucket
  storage refactor in `news.arc`).
