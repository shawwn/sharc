---
name: remove-dot-syntax-and-show-item-year
description: Redefined `only` to identity, swept `foo.x`/`gray.220` to `&`/`!` syntax, added ar-safe-apply non-function-call diagnostics, and reworked news item score/byline/age display (absolute date past one year).
type: project
---

# Handoff: remove dot syntax & show item year (2026-06-03)

Covers everything since commit `16b98e5`
("srv.arc: simplify abusive-ip check using table default").

## 1. `only` is now the identity function (arc.arc)

`only` used to wrap a function so it became a no-op on `nil`
arguments:

```
(def only (f)
  (fn args (if (car args) (apply f args))))
```

It is now just:

```
(def only (x) x)
```

This is the key change that motivated the syntax sweep below. With
`only` as identity, `only.foo` (= `(only foo)`) returns `foo`
unchanged, and `(only.foo args)` would call `foo` directly. But the
old call sites relied on `only.foo` being a *callable wrapper*, so
they were all rewritten to use `&`/`!` ssyntax (see #2) which
expresses the intended "call foo, guarding on nil" behavior through
arc's compose/sym-application syntax rather than through `only`.

## 2. Dot-syntax sweep -> `&` and `!` (news.arc)

Replaced `foo.bar` (compose) with `foo&bar`, and indexed-access
dot forms with `!`. Examples from the diff:

- `(only.profile id)` -> `(only&profile id)`
- `(only.avg ...)`, `(only.pr text)`, `(only.urldecode ...)`,
  `(only.comments-active i)`, `(only.num ...)`, `(only.> ...)`,
  `(only.round ...)`, `(only.med ...)` all -> `only&...`
- `gray.220` -> `gray!220`
- `_.1.3` -> `_!1!3`, `_.3` -> `_!3`

This matches the project convention (see CLAUDE.md): prefer `!`
syntax over `(foo 'bar)`, and `&` for composition. Commit `cd9b04c`.

## 3. `ar-safe-apply` diagnostics (arc0.lisp, arc1.lisp)

Added tooling to diagnose "function call on non-function" crashes
(calling `nil`, a number, or a symbol as if it were a function).
Commit `75b65d4`.

- **arc0.lisp**: `ar-safe-apply (expr fn args)` errors with a clear
  message (`"Function call on non-function: ~S ~S"`) including the
  offending expression when `fn` is nil/symbol/number; otherwise it
  falls through to `ar-apply`. Also `arc-safe-apply (expr fn &rest args)`.
- **arc1.lisp**: added `ac-safe-call`, which compiles a call through
  `ar-safe-apply` (passing the quoted source expr for diagnostics),
  handling macros and `fn` forms like `ac-call` does.
- The wiring in `ac` is **commented out** by default:
  ```
  ;((consp s) (ac-safe-call (car s) (cdr s)))
  ((consp s) (ac-call (car s) (cdr s)))
  ```
  Uncomment the `ac-safe-call` line to turn on the diagnostics when
  hunting a bad call; leave it off in normal use (it adds overhead to
  every call site).

## 4. News item display changes (news.arc)

### Score + byline visibility (commits af5d7d6, 966494f)

New predicate gates whether the item score is shown:

```
(def cansee-score (i)
  (or (isnt i!type 'comment)   ; non-comments: always
      (me i!by)                ; your own comment
      (admin)))                ; admins see all
```

`itemline` now prints the score and a `" by "` separator when
`cansee-score` is true, then the byline:

```
(def itemline (i)
  (when (cansee i)
    (when (cansee-score i)
      (itemscore i)
      (pr " by "))
    (byline i)))
```

The `" by "` text was **moved out of `byline`** (it used to be
`(when (admin) (pr " by "))` at the top of `byline`) and into
`itemline`, so it renders alongside the score under the new rule.

The `or` clauses in `cansee-score` are ordered cheapest-first
(type check before user/admin lookups).

### Absolute date past one year (commit bc52365)

`text-age` now renders items older than one year (>= 525600
minutes) as an absolute date instead of "N days ago":

```
(if (>= a 525600)
    (let (s m h D M Y) (timedate (- (seconds) (* a 60)))
      (let M (case M 1 "Jan" 2 "Feb" 3 "March" ... 12 "Dec"
                   (err "Bad month number"))
        (pr "on " M " " D ", " Y)))     ; e.g. "on June 3, 2026"
    (>= a 1440) ... "day ago"
    (>= a   60) ... "hour ago"
                ... "minute ago")
```

Note the month abbreviations are inconsistent on purpose-ish: short
forms for most months but full words for "March", "April", "May",
"June", "July" (matching HN's own rendering).

## 5. CLAUDE.md (commit 83f31ea)

Added the instruction: *"Don't delete files under `arc/`. e.g.
`arc/news/story/1`"* (these are live data files).

## Context for future sessions

- Branch: `main`, all changes committed and clean as of this handoff.
- The `ac-safe-call` diagnostic path is intentionally dormant
  (commented out in arc1.lisp). Don't ship it enabled.
- Since `only` is now identity, treat any remaining `only.foo`
  occurrences as bugs to convert to `only&foo` / `only!foo`.
