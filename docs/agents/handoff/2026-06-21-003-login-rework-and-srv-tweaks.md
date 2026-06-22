# Login-form acct/pw rework, redirector fixes, and srv tweaks

Date: 2026-06-21

A review-and-commit session: the user staged changes one at a time and
asked "what do you think of the staged changes?" for each, then had each
land as its own commit after review. Two standalone `news` bug fixes, a
five-commit login-form rework (rename form fields `u`/`p` -> `acct`/`pw`,
add input attributes, redirect the admin form, prefill on failed login),
and a `srv` content-type addition. Range `afbb46e..93b6098` (8 commits)
on `main`.

## What was accomplished

- **`59cd6c9`** `news.arc`: fixed the `vote` op's logged-out branch. `vote`
  is a redirector (`newsopr` -> `defopr`), so every branch must return a
  URL. The `(no user)` branch called `login-page` directly (renders HTML
  inline), which is wrong in a redirector. Wrapped it in `flink` so it
  returns a proper fnid URL like the sibling branches.
- **`01b25bd`** `news.arc`: the `submitted` op now guards on
  `(only&profile id)` (= `(and id (profile id))`, short-circuiting so
  `(profile nil)` isn't called) and shows "No such user." up front for a
  missing or unknown id, instead of relying on `submitted-page`'s internal
  profile check. Unifies the old "No user specified." message into one.
- **`8546d4d`** `app.arc`: made `(me)` a plain predicate. `(me other)` now
  tests `(is (the me) other)` instead of doubling as the matched username,
  and takes a rest arg (`args`) so a nil argument is a real equality test
  rather than being conflated with "no argument". `(me nil)` returns t
  when logged out (the current user *is* nil) - that's the intended,
  consistent semantics. All callers that pass an arg use it in boolean
  context, so dropping the username-return duality breaks nothing.
- **`efcf7d4`** `html.arc`: generalized HTML bool attributes. `opbool` now
  switches on `(downcase:string val)`, emitting `="true"` for `true`/`t`
  and `="false"` for `false` (was: `="true"` for any truthy value); new
  `oponoff` handles `on`/`off` attributes. Registered `spellcheck` +
  `autofocus` (opbool) and `autocorrect` + `autocapitalize` (oponoff), and
  rewrote `tabindex`/`aria-hidden` as bare keys. The lone existing opbool
  caller (`aria-hidden t`) is unaffected.
- **`ec07f2e`** `html.arc` + `app.arc`: `inputs` macro now takes one
  parenthesized list per field `(name label len text . options)` (instead
  of a flat `tuples`-of-4 list) and splices the trailing `options` into the
  generated `<input>`. Textarea branch simplified
  `(let gt text (if gt (pr gt)))` -> `(aif text (pr it))`. `pwfields` (the
  sole `inputs` caller) adopts the list form, renames fields `u`/`p` ->
  `acct`/`pw`, and sets `autocorrect/spellcheck/autocapitalize off` +
  `autofocus` on the login field.
- **`0d8107b`** `app.arc`: converted the admin create-server-account form
  from `uform` to `urform` (Post/Redirect/Get). `urform` -> `arform`
  (posts to `/r`, a `defopr` redirector) so the handler's return value is
  the redirect location: `"admin"` on success, `flink` pages for the error
  cases, instead of rendering inline. Reads the renamed `arg!acct`/`arg!pw`.
- **`598850a`** `app.arc`: finished the rename and added prefill.
  `login-handler`/`create-handler` now read `arg!acct`/`arg!pw` (no
  `arg!u`/`arg!p` reads remain in the login/admin flow). Threaded
  `acct`/`pw` as optional params (defaulting to `arg!acct`/`arg!pw`)
  through `login-page` -> `login-form` -> `pwfields`, and through
  `failed-login`, so a failed login re-fills both fields - **including
  across the `flink` redirect** that otherwise drops the POST body (the
  `(o acct arg!acct)` default captures the live value at call time and the
  flink closure carries it into the later GET). Minor: handlers bind args
  once via `with`; `login` groups its assignments.
- **`93b6098`** `srv.arc`: serve `.json` static files as
  `application/json`. Added a `json` entry to `type-header*` **and** a
  matching `"json" 'json` case to `static-filetype` (both are needed - the
  table entry alone is inert without the extension->filetype case). Also
  grouped `js` next to the other `text/*` types (cosmetic; table-population
  order is irrelevant).

## Key decisions

- **`(me nil)` returning t when logged out is correct, not a bug.** Under
  the predicate reading `(me x)` == `(is (the me) x)`; logged out, the
  current user is nil, so `(me nil)` is true. The switch from `(o other)`
  to `args` is what makes nil-arg a real equality test (the old form
  conflated "no arg" with "nil arg"). Reviewed all arg-passing callers:
  every one uses the result in boolean context.
- **Redirector branches must return URLs.** Both the `vote` fix and the
  admin-form conversion hinge on this: ops defined via `defopr`/`defopr-raw`
  (`/r`, `/y`) treat the handler's return value as the redirect Location,
  so branches use `flink` (returns a `/x?fnid=...` URL) or a bare op name
  string (e.g. `"admin"`, `"mismatch"`). Non-redirecting `aform`/`uform`
  (`/x`) instead render the handler's printed output inline.
- **Prefill-across-redirect via optional-param capture.** `failed-login`'s
  redirect branch returns `(flink {login-page ... acct pw})`; the flink
  thunk runs *later* during a GET with no form body. Capturing `acct`/`pw`
  through the `(o acct arg!acct)` defaults at `failed-login` entry (still
  inside the POST) bakes the live values into the closure. Writing
  `arg!acct` *inside* the thunk would read nil at GET time. The inline
  branch needs no explicit pass - its default reads the live POST arg.
  Password is threaded too (lives in the server-side fnid closure, not the
  URL, but does render into the HTML `value` - matches the prior inline
  behavior; flagged as a conscious choice, not changed).
- **Commits were deliberately split** even when an intermediate commit left
  the app briefly inconsistent. After `ec07f2e` (pwfields emits `acct`/`pw`)
  but before `598850a` (handlers read `arg!acct`/`arg!pw`), regular login
  was momentarily broken; the user explicitly chose to judge each staged
  commit on its own and land the handler half separately. The admin-form
  half was its own commit (`0d8107b`) too.

## Important context for future sessions

- **`me` semantics changed** (`app.arc`): `(me)` returns the current user;
  `(me x)` is now a boolean predicate, *not* the matched username. If any
  future code wants the username-on-match behavior, it's gone - use `(me)`
  and compare yourself.
- **Login form field names are `acct`/`pw`** (not `u`/`p`). Any new login/
  account form or handler must use `arg!acct`/`arg!pw`. Note `arg!u` is
  still a URL field in `news.arc:1785` and `arg!p` is the pagination arg
  (`news.arc:864`/`880`/`896`) - those are unrelated and unchanged. The
  rename to `acct`/`pw` was partly to avoid that collision.
- **`inputs` macro is now list-per-field**: `(inputs (name label len text
  . options) ...)`. `pwfields` is the only caller. The first element is
  quoted as the HTML field `name`; the `text`/value and `options` are
  evaluated. Pass extra attributes (e.g. `autofocus`, `spellcheck`) as the
  trailing `options`.
- **`opbool` no longer emits for arbitrary truthy values** - only
  `true`/`t`/`false` (and `oponoff`: `on`/`t`/`off`); everything else
  emits nothing. If you add a bool attribute, pass `t`/`'false`/`'off`
  etc., not arbitrary strings.
- **JSON serving is static-file only.** `.json` files under `staticdir*`
  now get `application/json`. There's no JSON *op* helper yet; an op that
  wants to emit JSON would set its own header (`type-header* 'json`) via
  the custom-header mechanism (see comment near `srv.arc:214`).
- **Branch `main`**, clean working tree, ahead of `origin/main` (unpushed).
  This handoff commit is the latest. Tests: `./test.arc` loads `arc.arc` +
  `libs.arc` only and does **not** exercise `srv/app/news`, so none of
  these changes are covered by it - smoke-test by running a server and
  hitting `/login`, `/admin`, a `.json` static file, and a logged-out vote.
