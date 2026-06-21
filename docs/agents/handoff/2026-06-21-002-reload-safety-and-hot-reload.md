# Reload-safe globals, restartable serve, and dev hot-reload

Date: 2026-06-21

A session building toward live code reloading on a running server, in
layers: make `serve` restartable, make a file reload not wipe in-memory
state (`or=` sweep), add `(reload)`, then auto-reload-on-save. Each
landed as its own commit after review. Range `606d94d..e092024`
(8 commits) on `main`.

## What was accomplished

- **`d0ee7bc`** `boot.lisp`: dropped the `ignore-errors` around loading
  `libs.arc`, so a broken stdlib fails loudly at boot instead of leaving
  arc half-loaded.
- **`25ccca1`** `srv.arc`: `serve` no longer blocks. It runs the accept
  loop in a background thread `serve-thread*`; re-running `serve` kills
  the prior thread and waits (originally via a `donesrv*` flag) for it to
  unwind and release the port before binding again. `blog`/`news` drop
  into `(repl)` after `bsv`/`nsv` since `serve` now returns.
- **`4f026b0`** `arc.arc`/`srv.arc`: factored thread lifecycle into
  **`start-thread`** (wraps the body so thread-locals are wiped on exit)
  and **`stop-thread`** (kill if alive, join on `(dead th)`, wipe
  thread-locals). The `thread` macro now expands to `start-thread`
  (relocated below `thread-locals*`, which it references). `serve`
  decomposed into `init-serve`/`start-serve`/`stop-serve`/`restart-serve`/
  `handle-serve` + `start-bgthreads`/`stop-bgthreads`; the `donesrv*` flag
  is gone because `stop-thread` joins on `(dead th)` (the socket closes
  during the terminate-unwind, so the port-release guarantee holds).
  `handle-request`'s worker/watchdog pair and `new-bgthread` reuse the
  helpers instead of open-coding `kill-thread`/`break-thread` + wipe.
- **`3a77532`** `blog.arc`: extracted the index body into `frontpage` and
  registered it for both `defop blog` and `defop ||` (root), so the blog
  serves at `/` as well as `/blog`.
- **`15d9ad8`** the big `or=` sweep across `app/arc/blog/html/news/`
  `prompt/srv/test`: session state, cross-module registries (`srvops*`,
  `fns*`/`fnids*`, `templates*`, `hooks*`, `savers*`, `bgthreads*`,
  `thread-locals*`, ...), admin-editable settings, and extension points
  (`toplabels*`) became `or=` so re-loading a file doesn't drop live data
  or deregister other modules. Tunable constants and derived paths stay
  `=`. Debug toggles (`breaksrv*`/`srv-noisy*`) became `or=` (persist a
  live toggle); `quitsrv*` stays `=`. **Path config unified on a single
  `arcdir*` root** (`or=`, env-overridable) that everything else
  `=`-derives from (`logdir*`, `newsdir*` family, `hpwfile*`/`oidfile*`/
  ..., `postdir*`, `appdir*`, `scrape-dir*` + subdirs). New `pathenv`
  helper in `srv.arc` reads `ARC_DATA_DIR`/`ARC_STATIC_DIR` (trailing
  slash normalized). Also fixed a latent bug: dropped
  `(= comment-kill* nil ...)` that was clobbering the `diskvar`-loaded
  value on every load.
- **`3161922`** `arc.arc`/`boot.lisp`: added **`(reload)`**. `load`
  records each file in `loaded-files*`; `reload` re-loads them all.
  `main` gained a `(no reloading*)` clause (where `reload` binds
  `reloading*` via `w/assign`) so a file's top-level `(when (main) ...)`
  effects fire once at startup but **not** on reload. `boot.lisp` loads
  the cmdline script files through arc's `load` (so they're tracked) and
  stores `main-file*` as the **raw** arg (not `truename`) to match what
  `load` writes to `script-file*`. `load`'s save/restore of `script-file*`
  also routes through `w/assign`.
- **`eeaebe3`** dev **auto-reload**: `notetime`/`loaded-file-times*`
  track each file's `modtime`; `loaded-files-changed` detects edits.
  `handle-request` calls `(if autoreload* (maybe-reload))`, with
  `autoreload*` from `(in (getenv "ARC_RELOAD") "t" "1")` (off by
  default). `maybe-reload` uses **double-checked locking** (cheap check
  outside `atomic`, re-check inside) and runs the reload through
  **`call-reporting`** (lisp helper: `handler-bind` + `arc-report-error`
  + `return-from`, so a bad save prints a full backtrace and unwinds
  *without* killing the serve thread). `reload` wraps each file load in
  **`call-quietly`** (lisp helper: muffles `style-warning` +
  `with-compilation-unit :override t`).
- **`e092024`** `arc0.lisp`: trimmed the obsolete `(arc:arc-tl)`
  interrupt-recovery hint from the repl greeting (`arc-tl2` already
  returns to the prompt after an interrupt).

## Key decisions

- **`=` vs `or=` rule that emerged.** `or=` iff something *outside the
  source file* sets the value: live session state, cross-module
  registries, admin-editable knobs (`caching*`/`perpage*`/
  `threads-perpage*` via /newsadmin, verified against the form),
  extension points other files append to (`toplabels*` via `pushnew`/
  `push`), and debug toggles you flip live. `=` iff the source owns it:
  plain constants and `arcdir*`-derived paths. `logo-url*` was pulled
  back to `=` to match its site-config block (`this-site*`,
  `favicon-url*`, ...).
- **Single `arcdir*` injection point, derived paths are `=`.** A test
  harness overrides one root and all data/log/static paths follow.
  `=` (not `or=`) on the derived vars is correct because they're computed
  from `arcdir*` and should track it on reload. `arcdir*` itself is `or=`
  so a value set *before first load* (via `ARC_DATA_DIR`) wins.
- **Reload alone does NOT give clean test isolation** (ruled out). Setting
  `arcdir*` then `(reload)` recomputes path strings but `or=` state tables
  survive and `fromdisk`'s `(unless (bound var))` guard means nothing
  re-reads from the new dir; `load-news`'s `(unless stories* ...)` skips.
  You get prod data in RAM with temp paths and misrouted saves. The
  working approach is **set the root before first boot** (the
  `ARC_DATA_DIR` env hook), which leaves everything unbound so it loads
  fresh from temp.
- **`main` kept pure via `reloading*`, not a one-shot wipe.** An earlier
  version had `(main)` wipe `main-file*` on first true call — rejected as
  a side-effecting "predicate" (a second `(when (main) ...)` would
  silently not fire). The `reloading*` flag keeps `main` pure and
  idempotent; the reload-suppression lives in `reload`. `reloading*` must
  be `or=` so re-loading `arc.arc` mid-reload doesn't reset it to nil.
- **`ARC_RELOAD` parsing uses an explicit allowlist** `(in ... "t" "1")`,
  not `saferead`. `saferead` would read the env as arc code, where `0`
  (truthy in arc!), `false`, and `no` (non-nil symbols) all enable —
  surprising off-values. The allowlist makes only `t`/`1` enable.
- **`call-quietly` / `call-reporting` are lisp-level** because the
  needed tools (`with-compilation-unit`, `handler-bind` on
  `style-warning`, `muffle-warning`, `arc-report-error`) are SBCL
  constructs. The SBCL recompile chatter on reload only appeared on
  *request threads*, not the repl/boot, because `make-thread` (in
  `new-thread`) gives a bare dynamic env that doesn't inherit the main
  thread's enclosing compilation unit; `call-quietly` re-establishes it.

## Important context for future sessions

- **Tests**: `./test.arc` loads `arc.arc` + `libs.arc` only — it does
  **not** exercise `srv.arc`/`app.arc`/`news.arc`, so the serve/reload
  changes here aren't covered by it. Smoke-test by running a server and
  hitting it; for auto-reload, launch with `ARC_RELOAD=t` and edit a
  loaded file.
- **Auto-reload is dev-only and off by default.** `autoreload*` is `=`
  (bundled with `quitsrv*`), so it's re-read from `ARC_RELOAD` on every
  reload; a manual `(= autoreload* t)` at the repl gets reset on the next
  reload it triggers (env is the source of truth). Make it `or=` if you
  want a sticky runtime toggle.
- **`*** redefining ...` spam remains on every reload.** `call-quietly`
  muffles the SBCL style-warnings but not `safeset`'s `disp` to
  `*error-output*`. Left as-is (cosmetic). To silence: bind
  `*error-output*` to a sink inside `call-quietly`, or gate the `safeset`
  message on `reloading*` — the latter has a load-order trap: `safeset`
  runs (line ~53) long before `reloading*` is declared (~1487), and an
  unbound global *errors* in this arc (`arc-global-ref`, not nil), so
  you'd have to seed `reloading*` near the top with a `bound`-guard.
- **`reload` re-loads every tracked file, not just the changed one** —
  deliberate, since cross-file macro deps make a partial reload unsafe.
  `notetime` refreshes all modtimes during reload, so no reload loop.
- **`libs.arc` is intentionally loaded via the lisp `arc-load`** (not
  arc's `load`), so it's *not* in `loaded-files*`; its sub-files are
  (loaded via arc's `load` in libs.arc's `map`), so `(reload)` hits each
  once. `arc.arc` is seeded via `(notetime "arc.arc")` since the
  bootstrap loads it before arc's `load` exists.
- **Branch `main`**, clean working tree, well ahead of `origin/main`
  (unpushed). This handoff commit is the latest.
