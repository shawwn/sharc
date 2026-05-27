---
name: env-to-special-var
description: Replaced the env parameter threaded through the Arc compiler with a *env* special variable, matching the design in sparc/ac.scm.
type: project
---

# Handoff: env parameter to *env* special variable (2026-05-26)

Refactored the Arc compiler in `arc1.lisp` to replace the `env`
parameter passed through ~23 functions with a single `(defvar *env* nil)`
special variable, matching the design in `~/sparc/ac.scm` (which uses
a Scheme parameter `env*`).

## Commits

| sha | what |
|---|---|
| `27e2f67` | arc1.lisp: replace env parameter with *env* special variable |
| `debea19` | CLAUDE.md: preserve comments and docstrings during refactoring |

## What changed (arc1.lisp)

- Added `(defvar *env* nil)` at the top of the compiler section.
- Removed the `env` parameter from all compiler functions: `ac`,
  `ac-string`, `foreign-cl-call-p`, `ac-qq`, `ac-qq1`, `ac-qs`,
  `ac-if`, `ac-fn`, `ac-complex-fn`, `ac-complex-args`,
  `ac-complex-opt`, `ac-table-args`, `ac-table-args-loop`,
  `ac-table-lookup`, `ac-table-slot`, `ac-body`, `ac-body*`,
  `ac-set`, `ac-setn`, `ac-set1`, `ac-var-ref`, `lex-p`, `ac-call`,
  `ac-mac-call`, `ac-andf`.
- `lex-p` now reads `*env*` directly instead of taking an env arg.
- `ac-fn` introduces a new scope via `(let ((*env* *env*)) ...)` and
  uses `setf` to extend `*env*` with the arglist before compiling the
  body (equivalent to Scheme's `parameterize`).
- `ac-complex-fn` and `ac-complex-args` similarly extend `*env*` via
  `setf` within the scope created by `ac-fn`.
- Lambdas like `(lambda (x) (ac x env))` simplified to `#'ac` or
  `(mapcar #'ac ...)` where applicable.
- `arc-eval` no longer passes `nil` to `ac`.

## Key decisions

- The CL equivalent of Scheme's `(parameterize ((env* (env*))) ...)`
  is `(let ((*env* *env*)) ...)` which rebinds the special variable
  for the dynamic extent. Only `ac-fn` creates this scope; inner
  helpers like `ac-complex-fn` and `ac-complex-args` mutate `*env*`
  within that scope via `setf`.
- All 295 tests pass after the refactor.

## Lessons / CLAUDE.md update

During the refactor, informative comments and docstrings were
accidentally stripped. The user added a rule to CLAUDE.md:

> Don't strip informative comments or docstrings when refactoring code
> unless explicitly asked to.

This is also saved as a feedback memory for future sessions.
