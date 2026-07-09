# First-class keywords, `|` orf ssyntax, a big test push, and untangling a multi-feature branch

Date: 2026-07-09

A long, multi-threaded session on a new `untangle-features` branch. It began
as **debugging** (a load-time crash, a wiped profile, double-escaped text),
turned into a **branch review** (the working tree held ~a dozen half-landed
features; I audited them for bugs across several rounds, the user fixed as we
went), and ended with a **run of small, cleanly-separated commits** plus two
real features: **`|` (orf) ssyntax** and **keywords as a first-class type**.
Lots of new tests along the way (suite 491 -> **726**, all green).

Branch: **`untangle-features`** (cut from `main` = `f81bda3`), now **34
commits ahead** of `main`, with **10 files still carrying uncommitted work**
(the big in-flight refactor). Nothing pushed to `origin/main`; this branch is
where everything lives. My commits this session: `efad68b` (newsadmin form),
`517040c` (`|` orf ssyntax), `c7d797c` (tidy arc-type), `8164af0` (first-class
keywords). Interleaved user commits: ssyntax cleanups (`c0ab546`, `c7b9dc3`),
`3126b62` (atomic `ero`), `a56ccc6` (json-hex-digit), `5632aaa` (`clamp`),
`dc9b74c`, `869fac8`, `a786078`, plus the `downcase`/`upcase` keyword hunk the
user hand-staged into `8164af0`.

## What was accomplished

### Debugging (early session, no commits — root causes found, user fixed)
- **`Unbound variable: hpasswords*` during `(load-news)`.** Ranking
  (`gen-topstories` -> `frontpage-rank` -> `contro-factor` -> `visible-family`
  -> `cansee` -> `delayed` -> `(uvar author delay)` -> `profile`) reached
  `ensure-news-user` -> `user-exists` -> `hpasswords*`, which is only bound by
  `load-userinfo` (deferred to `asv`). Fix landed in `load-prof`: load an
  existing profile from disk *before* calling `ensure-news-user`, and **return
  `(profs* u)`** (the refactor had it returning `ensure-news-user`'s nil, so
  `(profile u)` was nil and `uvar` did `(nil 'k)`). Net: authors with a profile
  file never reach `hpasswords*`, so load stays `load-userinfo`-free.
- **Wiped `test` profile.** `init-user` on an existing user overwrote the
  on-disk profile (blank `inst` + `save-prof`). Cause was an earlier `load-prof`
  ordering bug. `submitted` was reconstructable from item authorship; karma/about
  were not.
- **`(pr nil)` printed `(nil)`.** A "filtering" `pr` (arc.arc) had dropped the
  `(car args)` return, so `pr` returned a *list*; the REPL echoed it. User later
  commented that experiment out.
- **mdtext showing `&amp;#x2F;`** — **not a live bug**: stale data written under
  the pre-escape-migration regime (commits `41b0d9a`, `d36ab4f` moved to
  escape-on-output). Re-saving an item launders it via `unmarkdown`; the current
  round-trip is idempotent.
- **Profile-footer HTML rendered as text** — `varline` (`app.arc`) `sanitize`s
  every `text-type`, but the footer fields (`email-msg*`, `resetpw-link`, the
  submissions/comments/etc. links) are `string` fields holding *trusted*
  pre-rendered HTML. This is a live regression from `d36ab4f`. **Not yet fixed**
  — recommended either reclassifying them `raw` (they'd need to emit their own
  `<tr>`) or adding an `html` field type that keeps the row but skips sanitize.

### Bugs found in the branch review (most fixed by user during the session)
- **`save-topstories`** wrote *item objects* not ids (`(retrieve 180 !id …)`
  returns elements; missing `map !id`) — the topstories file became unreadable
  `#<HASH-TABLE …>` and every start silently re-ranked. Fixed back to
  `(map !id (firstn 180 …))`.
- **`recent-items`** cutoff used `(minutes-since (* 60 minutes))` (returns
  *elapsed minutes*, ~29.7M) instead of a timestamp; stop-test never fired, so
  it scanned all items (broke spam throttling). Fixed to `(- (seconds) (* 60 minutes))`.
- **`inc` on chars** broke: refactor to `(as!num x)` returns nil for chars
  (`coerce char 'num` is nil). Fixed to `(coerce x (if (isa!num x) 'num 'int))`
  — handles chars (`'int`) and floats (`'num`).
- **fave-on-login** broken by a `"" -> nil` sweep: `fave-url` used
  `(auth-for (me) id)` (nil when logged out) and the fave op checked
  `(good-auth nil id auth)` (always nil). Fixed by restoring the `""` sentinel
  in both.
- **`(map row:link …)`** (admin/editor lists page, news.arc ~1100/1103) errored
  because the `html.arc` keyword-args refactor turned `link` from a `def` into a
  `mac`; `row:link` = `compose` of two macros can't be a first-class value.
  Fixed to `(map [row:link _] …)` (macros expand when called directly).
- **`ensure-news-user`** created a profile for *any* goodname string reachable
  from HTTP (`/user?id=…`). User re-added the `(user-exists u)` guard.
- **scrape dev-password block** (`scrape.arc` ~771-775) — `bad-newacct` +
  `(err it)` + `set-pw` still reads as half-finished (aborts whole import on one
  bad name; `set-pw` re-saves `hpasswords*` per user, O(n^2), against the
  "flush once" comment). **Deliberately left uncommitted.**

### Features committed
- **`517040c` `arc: add | (orf) ssyntax mirroring & (andf)`.** `a|b` -> `(orf a b)`,
  parallel to `a&b` -> `(andf a b)`. `arc1.lisp`: `|` added to `ssyntax-char-p`,
  new `expand-or`, `ac-orf`, and `ac-andf`/`ac-orf` share `ac-infix`; the reader
  only treats `|` as a verbatim `|…|` segment when it *leads* the token.
  `ssyntax`/`ssexpand` xdefs moved from `arc0.lisp` to `arc1.lisp` (next to
  `ssyntax-p`). Precedence, loosest->tightest: **`&`, `|`, (`:` `~`), (`.` `!`)**.
  Added a full `ssyntax` test.
- **`8164af0` `arc: make keywords a first-class type`** (the headline). See
  Key decisions. `arc0.lisp`: `type` returns `'key`; `coerce` builds
  (`string/sym -> key`) and unbuilds (`key -> string/sym`, folding the
  reader-upcased name to lowercase); printers emit `:foo`. `arc.arc`:
  `downcase`/`upcase` pass `(sym key)` through unchanged. `srv.arc`:
  `valid-scopeval` accepts `'key`. `test.arc`: `keyword` + `sym` tests.
- **`c7d797c` `arc0: tidy arc-type`**, **`efad68b` `news: tidy newsadmin form`**
  (posint perpage/threads-perpage, autoreload toggle, spam-sites link to top).

### Tests added (all in `test.arc`, suite -> 726/0)
- Every function in `strings.arc`: `tokens`, `halve`, `positions`, `lines`,
  `slices`, `litmatch`, `endmatch`, `posmatch`, `headmatch`, `begins`, `subst`,
  `multisubst`, `findsubseq`, `blank`/`nonblank`, `trim`, `num`, `pluralize`.
- **`natsort`** — implemented in `strings.arc` (`nat<`, `nat-key`, `nat-chunks`,
  `nat-chunk<`, `natlist<`) plus tests. Digit runs compare numerically, text
  case-insensitively, with a raw-string tiebreak for a total order.
- `string-coerce` — pins the `(+ "" x)` vs `(string x)` divergence on lists.
- `ssyntax`, `keyword`, `sym` tests.

## Key decisions

- **Keywords are a distinct namespace, not "symbols starting with `:`".** In
  the host Lisp keywords live in the keyword package; the `:` is reader syntax
  selecting that namespace and is **not part of the name** (`:foo`'s name is
  `"foo"`). So `type` returns `'key` (a keyword is **not** a `sym`:
  `(isa :foo 'sym)` is nil), and `coerce`/`isa` treat it uniformly.
  `foo:` and `:foo` read to the *same* keyword; a colon **between** names
  (`foo:bar`) is still compose ssyntax.
- **Permissive on names, strict on the coerce target.** The invariant (now
  tested): *the type you ask for is the type you get, colons and all.*
  `(coerce ":foo" 'sym)` is a plain sym (not a keyword); `(coerce ":foo" 'key)`
  is a keyword. A `:` in a string never silently promotes a sym to a keyword.
  We explicitly **rejected** adding colon-detection / erroring on odd names —
  `foo:bar` proves colon-bearing symbols are first-class (that's how ssyntax
  works), so walling them off would be backwards.
- **Keywords print `:foo` and round-trip** (user caught this). Both
  `arc-disp-val` and `arc-write-val` now emit `:` + lowercased name; previously
  a keyword printed as bare uppercase `FOO`, which read back as the *sym* `foo`.
- **`key->string` folds to lowercase** so it round-trips with how it was
  written; `string->key`/`sym->key` upcase the name (reader convention). This
  makes `downcase`/`upcase` on a sym-or-key a no-op — hence the user's
  `(sym key) x` branch with the comment "symbols and keywords are always
  lowercase" (cleaner than my per-type branches).
- **Blast radius of the new `key` type:** every `(case (type x) … sym …)`
  with no `key` branch stops handling keywords. Only `downcase`/`upcase`
  actually **errored** (they `(err …)`) — and the tag machinery downcases
  option keys, so `news.arc` wouldn't load until those got a `(sym key)` branch.
  The rest (`sanitize` -> default, `literal` -> `t` which is *correct* since
  keywords self-evaluate, `copy`, `scrub-scopeval`) fall through safely.
  `json-write`'s fallback already matched the old sym branch, so **no json
  change was needed**.
- **`(string list)` was left as-is** (pg intent). `(string '(a b c))` -> "abc"
  (elementwise char/element coercion) is load-bearing via the `string:rev`
  idiom in the reader/server/tokenizer. Considered making `string` use the
  printed form (like `(+ "" x)`) with `as!string` for the char-list case, but
  the migration touches core reader/server code and would split `string` from
  `as!string`; documented the divergence with a test instead.
- **ssyntax precedence** deliberately puts `&`/`|` **outermost**: `a&b|c` ->
  `(andf a b|c)`, `a|b&c` -> `(andf a|b c)`. Confirmed via `ssexpand`.

## Important context for future sessions

- **Tests: 726 passed, 0 failed.** Run `./test.arc` (or
  `(load "news.arc") (load "test.arc") (run-tests)`). Runtime is
  **SBCL-based** ("sharc"): `./sharc` boots via `boot.lisp` and **reloads
  `arc0.lisp`/`arc1.lisp` from source each run**, so lisp-side edits take
  effect with no rebuild. Loading `.arc` files echoes source lines to stdout —
  grep for `" => "`/your markers when probing.
- **Branch `untangle-features` is the source of truth**, 34 ahead of `main`
  (`f81bda3`). **~10 files still hold uncommitted, intertwined refactor work**
  — do **not** sweep it into commits. Highlights of what's still unstaged:
  - `html.arc`: the **keyword-args tag system** (`key-pairs`/`pairbody`,
    `class:` keyword options, `dedup-tag-options`) and the `def->mac` conversions
    of `link`/`underlink`/`but`/`spacerow`. This is the *usage* of keywords; it
    was intentionally kept out of `8164af0`. `(isa … 'key)` there needs the
    committed keyword type. It also has `tags-if`, `floatwid`, `font`, etc.
  - `arc.arc`: the `as!`/`chars`/`edge` helper refactor, `string` single-arg
    fast path, `parse-format` flush, `inc` num/int fix, `w/the-if`, the
    commented-out filtering `pr`/`def`. (Only the `downcase`/`upcase` keyword
    hunk was committed.)
  - `news.arc` (largest, ~435 lines): item-bucket storage (`item-dir`/
    `item-path`/`item-bucket-size*`, `each-item`, `latest-items-by-type`),
    `diskvar maxid*`, the `interviews` page + `display-mark`/`key` emoji marks,
    keyword-arg `spacerow class:` call sites, and more.
  - `app.arc`, `srv.arc` (minus valid-scopeval), `scrape.arc`, `json.arc`,
    `pprint.arc`, `strings.arc` (the `as!`/`chars` conversions; natsort *is*
    uncommitted too), `test.arc` (the non-keyword new tests: strings.arc suite,
    natsort, string-coerce, the `define-test` `sym:string` tidy).
- **Known-open, do not commit yet:** (1) the **scrape dev-password block**
  (half-finished); (2) the **profile-footer sanitize regression** in
  `varline`/`user-fields` (trusted HTML escaped as text) — needs a `raw`/`html`
  field-type decision.
- **Selective-staging technique used a lot this session:** for files with mixed
  keyword + unrelated hunks I extracted specific hunks with a small Python
  script (kept the diff header + hunks matching a content marker, `git diff
  --unified=1`) and piped to `git apply --cached --unidiff-zero`. `git add -p`
  is interactive and **unavailable** in this harness. The user also hand-stages
  hunks (they staged the `downcase`/`upcase` case-branch lines directly).
- **The `keyword` predicate xdef is gone** and was **never committed** (it was
  an uncommitted addition). Use `(isa x 'key)`. Its only call sites were in the
  (still-unstaged) `html.arc` keyword-args code, already switched to
  `(isa … 'key)`.
- **Data dir** `arc/` is gitignored. Items now live in **bucketed** dirs
  (`arc/news/story/<bucket>/<id>`, bucket = `id/10000`); the on-disk data has
  already been migrated, so the *old* `load-items` (pre-bucket) can't read it —
  keep that in mind if you `git stash`/checkout older news.arc to A/B.
