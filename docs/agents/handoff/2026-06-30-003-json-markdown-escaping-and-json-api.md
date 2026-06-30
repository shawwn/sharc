# JSON pretty-printing, HTML/markdown escaping, and JSON API endpoints

Date: 2026-06-30

A review-and-commit session: the user staged changes one at a time and
asked "what do you think of the staged changes?" for each, iterating on
a few until they were correct, then had each land as its own commit.
Several review rounds caught real bugs before they were committed (see
Key decisions). Session range on `main`: `6064950..f6f4a41` (parent
`6064950` was the prior handoff's last commit). Interleaved with two
user-made commits (`44bcc3d` the prior handoff doc, `d5a8009` a
`vote-url` refactor). Themes: JSON encoder pretty-printing; consolidate
HTML entity escaping/unescaping; backslash- and `**`-escaping of
literal asterisks in markdown; read-only `item.json` / `user.json`
endpoints.

## What was accomplished

- **`854c267`** `news.arc`: `vote-url` appends a `#<id>` fragment to the
  redirect `goto` target when voting from an item page, so the post-vote
  redirect returns to the comment you voted on instead of the page top.
- **`122bb75`** `json.arc` + `test.arc`: optional pretty-printing in the
  encoder. `to-json` and `save-json` gained an optional `pretty` arg
  **before** the stream: `(to-json x pretty stream)`. `t` indents two
  spaces, an int indents that many spaces, a string is used verbatim;
  `nil` (default) stays compact. A `json-indent-step` normalizes
  `pretty` into a per-level indent string; `step`/`ind` thread through
  `json-write` / `json-write-array` / `json-write-object`;
  `json-newline` emits a line break + indent in pretty mode and is a
  no-op compact. Object separator is `": "` pretty / `":"` compact.
  Empty containers stay on one line. (Note: an empty Arc list is `nil`,
  so `(to-json nil)` is always `"null"`, never `[]`.) Added
  `json-encode-pretty` tests.
- **`c01406d`** `app.arc` + `html.arc` + `scrape.arc` + `test.arc`:
  centralized HTML escaping. New `eschtml-char` / `uneschtml-char`
  (single-char encode/decode) and a string-level `uneschtml`
  (multisubst). `eschtml` and `esc-tags` now delegate, switching from
  numeric entities (`&#60;`) to named/hex (`&lt;`, `&quot;`, `&#x27;`,
  `&#x2F;`). `markdown` escapes at **output** time (code blocks via
  `eschtml`, body chars via `eschtml-char`) instead of pre-escaping
  input with `esc-tags`; `unmarkdown` reverses via the new decoders.
  `scrape.arc` dropped its private `html-unescape` for the shared
  `uneschtml`. Added `html-escape` + `markdown-roundtrip` tests.
- **`1d75b6f`** `app.arc` + `test.arc`: backslash-escaped literal
  asterisks in markdown. `\*` -> literal `*` (consumes both, no italic
  toggle); `\` before anything else -> literal `\` (consumes one). No
  separate "escaped backslash" rule. `unmarkdown` maps a literal `*` in
  the html back to `\*` so an edited doc re-renders identically. Added
  `markdown-escape` tests.
- **`41b9ee4`** `app.arc` + `news.arc` + `test.arc`: `**` (doubled
  asterisk) renders as a single literal `*` instead of empty
  `<i></i>` - **unconditionally**, even inside italics, so `*foo***` ->
  `<i>foo*</i>` (the third `*` closes). Updated `formatdoc*` help text
  to mention `\*` and `**`. Added `markdown-escape` / `markdown-
  canonicalize` tests.
- **`f6f4a41`** `news.arc`: read-only JSON endpoints `item.json?id=` and
  `user.json?id=`. `item-api` / `user-api` build a data `obj` under
  `w/me nil` (logged-out viewer); `prjson` encodes + honors
  `?print=pretty` (case-insensitive, via `downcase arg!print`). New
  `scoreof` helper extracted from `itemscore` (pollopt-aware score),
  reused by `item-api`'s `score` field.

## Key decisions

- **`pretty` goes before `stream` in `to-json`.** Final signature is
  `(to-json x (o pretty) (o stream (stdout)))`. The header doc comment
  and the tests were realigned to this order during review (early drafts
  had them inconsistent, which crashed `T is not of type STREAM`). An
  earlier draft also defaulted `pretty` to `(~no arg!pretty)` - that
  crashed every non-request call (the suite, `save-json`) because `arg`
  dereferences `(the req)`, which is nil outside a web request. Dropped;
  the request-param toggle lives at the endpoint instead (`prjson`).
- **Two HTML-escape bugs were caught by review, not tests.**
  `uneschtml-char`'s `/` branch shipped twice-broken in drafts: first a
  typo'd literal (`&x2F;` vs `&#x2F;`), then a wrong output char (`#\"`
  instead of `#\/`). Both corrupted slashes on `unmarkdown` round-trips.
  The suite was green throughout because nothing exercised the `/`
  round-trip - which is exactly why the `html-escape` test now loops
  over every escaped char asserting `eschtml-char` -> `uneschtml-char`
  round-trips (char and consumed length).
- **`**` is an unconditional literal asterisk.** The first draft guarded
  it with `(no ital)`, which made `*foo***` wrongly render
  `<i>foo</i>*`. The spec cases (`*foo***` -> `<i>foo*</i>`,
  `*foo**bar*` -> `<i>foo*bar</i>`) require `**` to be a literal `*`
  even while italics are open, with a later single `*` doing the close.
  Guard removed. Trailing-lone-`*` producing a dangling `<i>` is a
  pre-existing wart of this markdown impl, unchanged.
- **Markdown round-trips are HTML-stable, not source-stable.** The
  meaningful invariant is `markdown(unmarkdown(html)) == html` (the
  edit-and-resubmit flow): `mdtext` fields are stored as rendered html
  (`md-from-form`) and the edit form redisplays `unmarkdown` of that
  (app.arc:402). So submitting normalizes `**`/`***` into backslash-
  escaped forms (e.g. `**foo\*` -> stored `*foo*` -> edit shows
  `\*foo\*`). `markdown-canonicalize` pins these. `unmarkdown` does
  **not** always recover the original source (e.g. a non-delimiter `*`
  becomes `\*`), and that's accepted.
- **JSON endpoints render as a logged-out viewer (`w/me nil`).**
  Deliberate: `cansee` / `cansee-score` / `visible-family` /
  `cansee:item` all default their user to `(the me)`, so wrapping in
  `w/me nil` gates the payload to what a logged-out user may see.
  `obj` drops nil-valued keys, so empty fields (`url`, `dead`, `kids`,
  ...) are simply absent from the JSON; a missing/invalid id yields
  `null` (the `whenlet` returns nil).
- **`prjson` keeps `arg!print` inside request context.** `arg` reads
  `(the req)`, so it's only safe inside a handler; `item-api`/`user-api`
  do the data gathering (and `w/me nil`) and `prjson` does encode +
  toggle, only ever called from the `responding` handler.
- **`responding` does not emit the header/body blank line** (carried
  over from the prior session): both `.json` handlers use
  `(responding type-header*!json (prn) (prjson:..-api id))` - the `(prn)`
  is the mandatory blank line before the JSON body, mirroring the
  static-file path in `srv.arc`.

## Important context for future sessions

- **Escaping API** (`html.arc`): `eschtml` / `esc-tags` (string ->
  escaped, named/hex entities), `eschtml-char` (one char), `uneschtml`
  (string, multisubst), `uneschtml-char` (one char, returns
  `(list char next-index)`). `markdown`/`unmarkdown` are the main
  consumers. Entity format changed from numeric to named - if any
  external consumer string-matched `&#60;` etc., note the change.
- **Markdown escaping** (`app.arc`): `\*` and `**` both yield a literal
  `*`; `\` before non-`*` is a literal backslash; `unmarkdown` escapes
  literal `*` back to `\*`. Pretty/escape behavior is pinned by
  `markdown-escape` / `markdown-canonicalize` / `markdown-roundtrip` in
  `test.arc`.
- **JSON endpoints** (`news.arc`): `item.json?id=N` and `user.json?id=N`,
  both accept `?print=pretty`. Builders are `item-api` / `user-api`
  (pure, return an `obj`); `prjson` encodes. To extend a payload, edit
  the `obj` in the `-api` fn. Keys are emitted sorted (json-key-order),
  so field order in the `obj` is cosmetic.
- **Verifying the endpoints manually**: `./sharc <file>` does **not**
  load `news.arc` (only core + app/html). To exercise them, a script
  must `(load "news.arc")` (safe: `(nsv)`/`(repl)` only run under
  `(when (main) ...)`), set `(= maxid* 100000)` (else `safe-item`'s
  `ok-id` range check fails), bind `(= (the req) (inst 'request 'args
  (list (list "id" "1") (list "print" "pretty"))))`, then call
  `(pr-json:item-api "1")` inside `tostring`. Sample data lives under
  `arc/news/story/<id>` and `arc/news/profile/<name>` (e.g. story `1`
  by "test"; profile "alice").
- **Tests**: `./test.arc` loads `arc.arc` + `libs.arc` + app/html/json
  (markdown/json/html tests run) but **not** `news.arc`, so the JSON
  endpoints have **no automated coverage** - verified manually this
  session. Full suite at session end: **492 passed, 0 failed**.
- **Working tree**: `main`, ahead of `origin/main` (this session's
  commits unpushed). **Uncommitted/unstaged: `blog.arc` and `news.arc`**
  are modified and were intentionally kept out of every commit - do not
  sweep them in. `news.arc` carries extra working-tree edits beyond the
  committed `f6f4a41` (it showed as `MM` - staged + unstaged - when the
  endpoints were committed).
