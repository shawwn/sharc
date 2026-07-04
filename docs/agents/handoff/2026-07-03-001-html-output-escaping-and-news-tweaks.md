# HTML output escaping (drop striptags), comment collapsing, and news tweaks

Date: 2026-07-03

A long review-and-commit session. The user staged changes one at a time
and asked "how do the staged changes look?" / "suggest a commit message"
for each, iterating until correct, then landed each as its own commit.
The dominant deliverable was a security refactor: move from
**stripping HTML at input** (`striptags`) to **escaping at output**
(new `sanitize` / `presc`), touched across many review rounds that each
caught a real bug (load-order crash, arity crash, double-escapes, a
misleading name) before it shipped. Earlier in the session: a
server-persisted comment-collapse feature and several small `news.arc`
fixes.

Session commits on `main` (parent `09a1eba` was the prior work; all
unpushed, `origin/main` is at `b2699bb`):
`d7f93c3`, `3af79ae`, `dd15eca`, `bd0ffa7`, `e6878ad`, `9fc5e91`,
`79ce0e2`, `d36ab4f`. Interleaved with four user-made commits touching
`html.arc`/`arc.arc` during the escaping work: `7f7cc34` (temquote),
`26dbc64` (line swap), `f2b2d39` (`opbool`->`opyesno`), `43f8bb5`
(simplify `start-tag`).

## What was accomplished

- **`d7f93c3`** `news.arc`: admin toggle to allow/disable clickable
  links in a story's self-text. `nolinks` predicate (off unless the
  `'links` key is set), `linkslink` admin action (`togglemem 'links`,
  re-renders `i!text` through `unmarkdown` -> `md-from-form` with the new
  flag), and the story edit form picks `mdtext` vs `mdtext2` accordingly.
- **`3af79ae`** `news.arc`: added the `collapsed` profile field, and let
  admins flag their own items (`flaglink`: `(~me i!by)` ->
  `(or (admin) (~me i!by))`).
- **`dd15eca`** `news.arc`: **server-persisted comment collapsing.**
  hn.js already sent `collapse?id=...&un=...` on the `[-]`/`[+]` toggle
  but there was no handler. Added the `collapse` newsop (login-gated,
  fire-and-forget), a `collapsed` predicate (user's explicit
  collapse/expand wins, else the admin default `'collapsed` key), and
  two profile sets `collapsed` / `uncollapsed`. Server now **renders the
  collapsed end-state on load** (mirrors hn.js `collstate`/`hidekids`):
  `coll` class + `noshow` threaded down `display-comment-tree` ->
  `display-1comment` / `display-subcomments` via a `collhidden` flag,
  `nosee` on votelinks, `noshow` on the `.comment` div, and `[N more]`
  vs `[-]` in `colllink`. `colldeflink` is the admin per-comment
  default-collapse toggle. `display-comment-body` **bypasses the shared
  comment cache when `(collapsed c)`** so per-user state never leaks via
  the cache.
- **`bd0ffa7`** `news.arc`: doc-comment fix (cache is "over a minute",
  the code is `> 60`, not "an hour").
- **`e6878ad`** `news.arc`: renamed `linklink` -> `linkslink` (the
  link-that-toggles-links; matches the `killlink`/`blastlink` family)
  and documented it.
- **`9fc5e91`** `news.arc`: allow title-only story submissions (dropped
  the "url and text can't both be blank" check; title still required).
- **`79ce0e2`** `news.arc`: show the flag link on tree-view comments for
  admins (`(unless (and (~admin) (or astree (~me))) ...)`).
- **`d36ab4f`** `app.arc` + `html.arc` + `news.arc` + `prompt.arc` +
  `test.arc`: **escape HTML on output instead of stripping tags on
  input.** Details below.

### `d36ab4f` in detail (the escaping refactor)

- New `sanitize` (`html.arc`): dispatches on type - `sym` ->
  `sym:sanitize:string`, `char` -> `eschtml-char`, `string` -> `eschtml`,
  else pass through. Works for both attribute values (syms/nums) and
  page content (strings/chars).
- New `presc args` = `(apply pr (map sanitize args))` - "print,
  html-escaped". Replaces raw `pr` / `pr:eschtml` for user text
  everywhere: `link`, `underlink`, `clickylink` (`news.arc`), `menu`
  options, npage `<title>` (`news.arc:npage`), `titlelink`, pollopt
  title/text, the rss `title`/`link`/`comments` elements, and the
  `prompt.arc` message.
- All attribute renderers now escape: `opstring`/`opnum`/`opsym` ->
  `(sanitize it)`; `opesc` (input `value`) -> `(presc it)`.
- `readvar` (`app.arc`) drops `striptags` for `string`/`string1`/
  `text`/`doc` (stored raw now; escaped on render).
- `markdown` (`app.arc`) escapes at output via `presc` (code block
  chars, body chars) and its inline autolinker passes the **raw** url to
  `link` (which escapes) instead of pre-`eschtml`-ing.
- `varfield`/`varline` (`app.arc`): textarea/display paths sanitize;
  `mdtext`/`mdtext2` are the exception (see decisions).
- Removed `clean-url` (def + calls), `pr-escaped` (folded into `presc`
  and `opesc`), and `esc-tags` (+ its test in `test.arc`).
- Moved the `eschtml`/`eschtml-char`/`sanitize`/`presc` block **above**
  the attribute methods (load-order fix, see decisions).

## Key decisions

- **Escape on output, not strip on input.** `striptags` and `clean-url`
  only ever dealt with HTML metacharacters (`< > " ' &`), which are now
  neutralized at every render sink, so both became redundant. `striptags`
  and `clean-url` calls were removed; `clean-url` was deleted entirely.
- **`valid-url` stays - it is NOT redundant.** It is a URL *scheme
  allowlist* (`http(s)://` only) plus a length check, which output
  escaping does not address: a `javascript:`/`data:` URL inside a
  perfectly-quoted, fully-escaped `href` is still live click-to-XSS
  (verified: `(link "x" "javascript:alert(1)")` ->
  `<a href="javascript:alert(1)">`). It gates both submission (`readvar`
  url, `process-story`) and whether a stored url renders as a clickable
  link (`varline`, `app.arc:449`). Its `(~find [in _ #\< #\> #\" #\'])`
  clause is now redundant with escaping, but the scheme/length checks are
  load-bearing - left `valid-url` intact.
- **`striptags` def + one caller kept on purpose.** The item-page
  `<title>` fallback for a text-only post,
  `(or i!title (aand i!text (ellipsize (striptags it))))`, is the one
  place `striptags` does *plain-text extraction*, not XSS defense.
  `i!text` is stored as rendered markdown HTML, so dropping `striptags`
  there is safe but cosmetically ugly: the tab title would surface raw
  markup and the pipeline's `&#x2F;` slash-encoding (e.g.
  `great link <a href="http:&#x2F;&#x2F;example.com...`), possibly cut
  mid-tag by `ellipsize`. So `striptags` was **removed only where it was
  pure XSS-redundancy** (submit title, poll title/choices, add-pollopt)
  and **kept for the title fallback**.
- **`mdtext`/`mdtext2` pull in opposite directions.** In `varline`
  (read-only display, e.g. another user's profile "about") they are
  printed **raw** - they are already-escaped markdown HTML; sanitizing
  would double-escape and show literal `<i>` tags. In `varfield` (the
  edit textarea) the value is `(sanitize:unmarkdown val)` - `unmarkdown`
  reverses the markdown escaping back to source text, which **must** be
  re-escaped or a stored `</textarea><script>` breaks out of the edit
  box (a real stored-XSS-against-editors vector this fixes).
- **Load-order gotcha (caused a crash).** The attribute methods
  (`opstring`/`opnum`/`opsym`/`opesc`) call `sanitize`->`eschtml`, and
  they are evaluated at **load time** via `precomputable-tagopt` (literal
  attribute values are pre-rendered when a tag macro expands). So the
  escape helpers must be defined *above* the attribute methods, or the
  first `(gentag ... type 'submit ...)` in `html.arc` crashes with
  `Unbound variable: eschtml`. The `eschtml`/`sanitize`/`presc` block was
  moved up accordingly. Do not "tidy" it back down.
- **Naming: `presc`.** `html` (the first draft) was rejected as
  misleading (reads as "emit raw HTML" but it *escapes*) and it collides
  with the `html` tag + common local var. `prt` was taken (`arc.arc`:
  print non-nil items). `esc`/`safe`/`text` are also taken. Settled on
  `presc` ("print escaped").
- **Bugs caught by review during the refactor** (all fixed before the
  commit): (1) an arity crash - `(apply prs:sanitize val)` spread a list
  into the 1-arg `sanitize`; fixed to `(apply prs (map sanitize val))`.
  (2) double-escapes from wrapping `sanitize` around values that a sink
  already escapes (`opesc`, `link`, npage title `(eschtml site)` at the
  "from" page); all removed. (3) `menu` printed option text raw - now
  `(presc i)` (options are static today, but this is the "user-inserted
  menu choices" hole).

## Important context for future sessions

- **Escaping API** (`html.arc`): `sanitize` (any -> escaped, type
  dispatch), `presc` (print escaped, variadic), `eschtml`/`eschtml-char`
  (string/char -> escaped, named+hex entities `&lt;`/`&quot;`/`&#x27;`/
  `&#x2F;`), `uneschtml`/`uneschtml-char` (decode). **Gone:**
  `pr-escaped`, `esc-tags`, `clean-url`. Attribute methods:
  `opstring`/`opnum`/`opsym` -> `sanitize`; `opesc` (input value) ->
  `presc`; `opcolor`/`opyesno`/`oponoff`/`opsel`/`opcheck` unchanged.
- **`valid-url` is the URL scheme gate** (`html.arc`). Do not remove it
  or weaken the `http(s)://` prefix check; it is the only thing blocking
  `javascript:`/`data:` link XSS.
- **Raw-but-safe render sinks (invariants to preserve):** `(pr user)`
  (usernames, `user-name`) is safe only because `goodname` restricts
  names to `[alphadig - _]`; `(pr c!text)` / `(row "" s!text)` (comment
  and story bodies) are safe only because the value is always
  `md-from-form` output (markdown HTML that escapes what it does not
  whitelist). A future feature that (a) relaxes `goodname`, (b) writes
  raw user text into a `text`/`mdtext` field bypassing `md-from-form`
  (import/API/migration), or (c) adds a `choice`/dropdown field with
  user-supplied options, would need its own escaping. `menu` options now
  escape via `presc`, so dropdowns are covered.
- **Tests**: full suite is **491 passed, 0 failed** (was 492; the one
  `esc-tags` test was removed with the function). `./test.arc` loads
  `arc.arc`+`libs.arc`+app/html/json but **not** `news.arc`, so the
  collapse feature and JSON endpoints have no automated coverage
  (verified manually). To verify the staged/committed snapshot in
  isolation: `git stash push --keep-index`, load+test, `git stash pop`.
- **Comment collapse** (`dd15eca`, `news.arc`): per-user state in the
  profile `collapsed`/`uncollapsed` sets; admin default via the
  `'collapsed` item key (`colldeflink`). `(collapsed c)` is the single
  source of truth; the cache is bypassed whenever it is true. hn.js
  drives the client toggle and calls the `collapse` newsop.
- **Working tree**: on `main`, ahead of `origin/main` by this session's
  commits plus this handoff. **Large uncommitted/unstaged changes kept
  deliberately out of every commit - do not sweep them in.** `news.arc`
  carries an in-progress **item-bucket storage refactor** (`item-dir`/
  `item-path`, `diskvar maxid*` at `news/max-id`, `latest-items` over
  `item-buckets`, bucketed `arc/news/story/<bucket>/<id>` paths,
  `ensure-dir` on save) - it showed as `MM` (staged escaping hunks +
  unstaged bucket hunks) throughout. Also modified but uncommitted:
  `README.md`, `arc.arc`, `arc1.lisp`, `json.arc`, `scrape.arc`,
  `srv.arc`.
