# Arc backtrace reporting, buffered response headers, and prompt PRG

Date: 2026-06-30

A review-and-commit session: the user staged changes one at a time and
asked "what do you think of the staged changes?" for each, then had each
land as its own commit after review. Four commits on `main`, range
`3a96241..6064950` (the parent `3a96241` was the prior handoff). Themes:
expose SBCL backtrace machinery to Arc and surface it on app errors;
introduce a per-request response-header buffer plus a unifying
`responding` macro in `srv.arc`; convert the `prompt` (app-management)
UI to Post/Redirect/Get on top of that.

## What was accomplished

- **`eb678b7`** `arc0.lisp` + `prompt.arc`: split the monolithic
  `arc-report-error` into three Lisp fns and `xdef`'d each into Arc:
  `report-frame` (prints one frame under an `:invert` readtable so
  mixed-case symbol names like `arc--CAR` print without `|...|` escapes),
  `map-backtrace` (wraps `sb-debug:map-backtrace`), and `report-backtrace`
  (the 30-frame loop, now parameterized by a `report-frame` fn and still
  stopping at `ARC-BOOT`). `arc-report-error` is now a thin
  `report-error` that prints `Error: ...` then the backtrace. Dropped the
  unused `*arc-last-err*` global. In `prompt.arc`, new `process-error`
  renders the error + full backtrace inside a `<pre>` and `run-app`'s
  `on-err` uses it instead of the old bare `"Error: " (details c)` line.
  **Note:** the `prompt.arc` half of this commit (the `process-error` /
  `run-app` change) was later superseded in the working tree by the PRG
  rework, but the `on-err process-error` wiring still stands.
- **`54fa89d`** `prompt.arc`: widened the create-app name `<input>` from
  the default size 10 to 20 (`(input "app" nil 20)`). Passing `nil` for
  `val` just omits the `value` attribute (tag-options skips nil-valued
  attrs), so it's purely a wider box.
- **`4126cdf`** `srv.arc` + `app.arc`: buffered response headers. Bind a
  per-request `(the headers)` to a fresh `(outstring)` (alongside a new
  `(the responded)` flag). `prheader` accumulates `Name: val...` into that
  buffer (`keep idfn` drops nil pieces so header parts can be optional);
  `flush-headers` dumps the buffer to the socket then repoints
  `(the headers)` at live stdout (idempotent via `errsafe:inside`). A new
  `responding` macro drives **both** response branches in `respond`: it
  sets `responded`, prints the status line (`header*` / `rdheader*`),
  flushes buffered headers, runs the body, returns nil. Extracted
  `default-loc` (the empty/`?`-prefixed location -> `/` fixup). `prcookie`
  in `app.arc` switched from a direct `prn` to `prheader`.
- **`6064950`** `prompt.arc`: Post/Redirect/Get for the app-management
  forms. Create/delete/save forms move `uform` -> `urform` (the `arform`
  redirector variant), returning a location via the new `prompt-url`
  helper, so mutations end in a fresh GET of `prompt?msg=...`. `prompt-page`
  now reads its message from `arg!msg` and renders it through `eschtml`
  (it now arrives via the query string). The create-good-name branch
  renders the editor inline with `(responding header* (prn) (edit-app it))`
  instead of redirecting; the explicit `(prn)` supplies the header/body
  blank line that `responding` does not emit. Renamed the repl page/form
  `url` arg to `whence`.

## Key decisions

- **Buffered headers fix a fragile evaluation-order trick.** Previously
  `Set-Cookie` only landed in the header section of a login *redirect*
  because `prcookie`'s `prn` ran while computing the `Location:` value's
  argument (so it printed before `"Location: "`). The new path runs the
  handler first, `prcookie` accumulates into `(the headers)`, and
  `responding` flushes that buffer right after the status line and before
  `Location:`. Explicit and order-independent.
- **Asymmetric flush timing is intentional.** In the redirector branch
  `responding` runs *after* `(f str req)`, so handler-set headers are
  fully buffered then flushed (no body to interleave). In the
  non-redirector branch `responding` flushes *before* `(f str req)`, so
  body-set headers degrade to direct writes gated by `defop`'s leading
  `(prn)` blank line - i.e. the pre-existing "emit your headers before the
  blank line" contract (see comment near `srv.arc:214`). No regression;
  `defop` was deliberately **not** changed.
- **`responding` does not emit the header/body blank line.** Callers that
  render a page through it must `(prn)` themselves - that's why the
  create-good-name branch is `(responding header* (prn) (edit-app it))`.
  The redirect uses of `responding` inside `respond` emit their own
  trailing `(prn)`.
- **A nil location now emits no redirect at all.** `default-loc` returns
  nil for a nil location, so the redirector branch's `whenlet` skips
  emission entirely (this is the hook that lets a handler render its own
  response and return nil, backed by the `(the responded)` flag). An empty
  *string* still maps to `/` as before; only a literal `nil` return
  changed behavior (was: `Location: /`). Low risk - flagged, not a known
  break.
- **PRG over inline rendering** for create/delete/save avoids the browser
  resubmit-on-reload warning and gives clean shareable URLs. The one case
  that still renders inline (create -> editor) does so on purpose to keep
  the new app's editor on screen without a round-trip.
- **Commits split deliberately**, each judged on its own staged diff. The
  `srv.arc` header-buffer commit (`4126cdf`) added `responding` whose
  page-rendering use only appears in the later `prompt.arc` commit
  (`6064950`); `responding` is not dead in between because `respond`
  itself uses it for both branches.

## Important context for future sessions

- **Header emission contract** (`srv.arc`): set response headers with
  `(prheader "Name" parts...)`, not raw `prn`. They buffer into
  `(the headers)` and are flushed by `responding`. For a normal `defop`
  page that wants a custom header, emit it *before* the body's first blank
  line (defop emits that blank line automatically as its first form), or
  the header lands in the body. Redirector handlers can set headers
  anywhere in their body - they're buffered until `responding` flushes.
- **`responding` macro** (`srv.arc`): `(responding header* ...body...)`
  sets `(the responded)`, prints `header*`, flushes buffered headers, runs
  the body, returns nil. It does **not** print the blank line; add `(prn)`
  if rendering a page. Use it (returning nil) inside a redirector handler
  to serve a page directly instead of a 302.
- **`default-loc`** (`srv.arc`): central place for the
  empty/`?`-prefixed-location -> `/` redirect fixup. Returns nil for nil.
- **Arc-level backtrace API**: `(report-error c)`, `(report-backtrace)`,
  `(report-frame frame)`, `(map-backtrace fn)` are now `xdef`'d. `prompt`'s
  `run-app` renders them in a `<pre>` on app error. Backtrace is capped at
  30 frames and stops at `ARC-BOOT`.
- **Minor inconsistency** (`prompt.arc`): `prompt-url` tests `empty`,
  `prompt-page` tests `blank` on the same message string. Harmless,
  untouched.
- **Working tree**: `main`, ahead of `origin/main` (these 4 commits
  unpushed). **Uncommitted/unstaged: `blog.arc` and `news.arc`** are
  modified and were intentionally left out of every commit this session -
  do not sweep them in. (`news.arc` was modified throughout; `blog.arc`
  appeared modified by the final commit.)
- **Tests**: `./test.arc` loads `arc.arc` + `libs.arc` only and does not
  exercise `srv`/`app`/`prompt`, so none of these changes are covered.
  Smoke-test by running a server and hitting `/prompt` (create/delete/save
  an app, watch for the redirect and the `?msg=` flash), `/repl`, a login
  (verify the `Set-Cookie` header on the redirect), and an app that throws
  (verify the backtrace `<pre>`).
