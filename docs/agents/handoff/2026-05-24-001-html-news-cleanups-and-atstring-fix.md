---
name: html-news-cleanups-and-atstring-fix
description: A multi-commit session of small HN-fidelity cleanups across html.arc / news.arc / app.arc / arc0.lisp, plus a real reader fix in arc1.lisp so atstrings tolerate unescaped quotes inside `@(...)` and `\X` escapes inside the @-body. Ends with a test for the regression.
type: project
---

# Handoff: html/news cleanups and atstring reader fix (2026-05-24)

This was a series of small, incremental commits driven by the user
diffing the rendered news pages against live HN. Each commit is a
self-contained tweak; the only substantial piece of new machinery is
the arc-reader change so atstrings can contain unescaped quotes inside
`@(...)`.

## Commits in chronological order

| sha | what |
|---|---|
| `4b1c293` | html.arc: `opmeth` falls back to common HTML attrs for any tag |
| `0fb751e` | html.arc: replace `link`'s color param with `id`; mark self in `userlink` |
| `ac94b68` | extract `formatdoc-link`; show it next to comment reply textarea |
| `aa039f0` | news.arc: enlarge comment reply textarea to 8x80 to match HN |
| `1cc12e1` | news.arc: put page title before site name in `<title>` |
| `f7c3c63` | html.arc: skip `opsym` attribute when value is nil |
| `4270bf7` | html.arc: quote `opnum`/`opsym` attribute values |
| `a35ba82` | html.arc: quote `opcolor` attribute value |
| `6f278cd` | arc0.lisp: lowercase radix-formatted int->string coercion |
| `fbb105d` | news.arc: simplify byline; time becomes the permalink |
| `2baaabb` | arc1.lisp: don't terminate string at unescaped quote inside `@(...)` |
| `caf822a` | news.arc: populate `noob-comment-msg*` with HN's welcome blurb |
| `1287e44` | app.arc: split case-insensitive username clash from exact-match check |
| `d542f3b` | news.arc: show story text even when a url is present |
| `69500dd` | arc1.lisp: process `\X` escapes in `@(...)` outside nested strings |

## The substantive change: atstrings in arc1.lisp

The HN noob-comment prompt has the shape

```arc
(= noob-comment-msg*
   "If you haven't already, would you mind reading about HN's
 @(tostring:underlink
    "approach to comments"
    "https://news.ycombinator.com/newswelcome.html")
 and ...")
```

That has unescaped `"` characters inside the outer string, sitting
inside the `@(...)` form. The original `arc-read-string` in
`arc1.lisp` (line ~129) treated the first unescaped `"` as the string
terminator, so the string above truncated at `@(tostring:underlink `
and the truncated tail then crashed `codestring`'s `arc-read` with
"Unexpected EOF in list".

### `2baaabb` -- `arc-copy-balanced-paren`

Added a helper that, on encountering `@(` inside `arc-read-string`,
scans the parenthesised expression in a balanced way and treats inner
`"..."` strings as opaque so their quotes don't terminate the outer
string. The captured text (including the `@` and parens) is appended
to the outer string buffer, and `codestring` later parses it back via
`arc-read`.

Implementation skeleton:

```lisp
;; arc-read-string: when we see #\@ and the next char is #\(
;; -> call arc-copy-balanced-paren which copies the whole `(...)`
;;    verbatim into buf, tracking depth and skipping inner strings.
```

Gated on `*arc-atstrings*` so behavior is consistent with the
evaluator's `ac-string` path.

### `69500dd` -- followup fix for `\X` escapes

The first version of `arc-copy-balanced-paren` preserved backslashes
verbatim. That broke the classic escaped-quote style:

```arc
"@(foo \"bar\")"
```

The outer reader used to process `\"` to `"` before `codestring` ever
saw it. With the new helper bypassing the outer reader's escape pass,
`codestring` was handed `(foo \"bar\")` literally and `arc-read`
choked on the bare `\` outside any string context.

Fix: in the outer @-form body, process `\X` the same way
`arc-read-string` would (translating `\n`/`\t`/`\r` and stripping the
backslash for other chars). Only inside a nested `"..."` do we
preserve backslashes, so `arc-read` can apply its own string-escape
handling later.

Both styles now work:

```arc
"@(len "abc")"      ; bare inner quotes
"@(len \"abc\")"    ; classic escaped style
```

Tests added in `test.arc` under `(define-test atstrings ...)`.

## Decision: ruled out wrapping `@(...)` in `(tostring ...)`

User asked whether `ac-string` should auto-wrap each `@(...)` body in
`(tostring ...)` so `@(underlink ...)` (which prints to stdout) would
work without the `tostring:` ssyntax prefix.

We explored three options:

1. **Bare `(tostring expr)`** -- captures stdout. Breaks every
   existing usage that relies on the *return value* being
   concatenated: `@(num it 1 t t)`, `@(hexrep border-color*)`,
   `@(len users)`, `@(if flag 'un)`.
2. **`(tostring (pr expr))`** -- captures both, but breaks
   side-effecting calls whose return value is junk. `tag` returns
   the closing-tag string as its value (`</a>`), so wrapping
   `underlink` produces a doubled `</a>`.
3. **Fallback (`out` if non-empty, else return value)** -- robust for
   both styles but adds an Arc-side helper and per-call gensyms.

User chose **leave as-is**: keep writing `@(tostring:underlink ...)`
when capture is wanted. The `ac-string` change was reverted; only the
reader fix (which the user does want) was kept.

`noob-comment-msg*` therefore still uses the `tostring:underlink`
form -- see news.arc around line 1966.

## Smaller pieces worth knowing

- `opmeth` (html.arc) is now a `def` (not a macro). If `(attribute
  ...)` hasn't registered a handler for a `(tag, opt)` pair, common
  HTML attribute names (`id`, `class`, `style`, `src`, `width`,
  `height`, `color`, etc.) get a default handler. Means most tags
  accept these attributes without explicit registration.
- `link`'s third optional argument is `id` now, not `color`. Was used
  by exactly one caller (`app.arc:323` for a grey help link); that
  caller was rewritten when `formatdoc-link` was extracted (`ac94b68`)
  before the rename (`0fb751e`).
- `userlink` (news.arc) passes `id 'me` to `link` when the user is the
  current viewer, so `<a id="me">` tags the current user's own
  username (useful for css targeting).
- `byline` no longer prints `"by "` for non-admins, drops the
  `itemscore` for non-admins, and turns the item-age text into the
  permalink. The separate `(def permalink ...)` was removed; its call
  site in the comment header (around news.arc:2089) was removed too.
- `formatdoc-link` was extracted from the inline `tag (a href ...)`
  in `app.arc` (`ac94b68`) and is now reused under the comment-reply
  textarea (news.arc near the `tarform`).
- `username-taken` (app.arc) is back to a plain `hpasswords*` lookup.
  Case-insensitive collisions are now reported separately by
  `username-conflicts` with its own "case-insensitive collision" hint.
- Story body text (`display-item-text` in news.arc) now renders even
  when a URL is present (HN does this).
- `<title>` (news.arc `fulltop`) puts the page title before the site
  name.
- HTML attributes from `opsym` / `opnum` / `opcolor` are now properly
  quoted (`key="value"` not `key=value`); `opsym` also skips nil.
- `arc0.lisp`'s int->string `coerce` with a radix now lowercases the
  output (so `(coerce 255 'string 16)` gives `"ff"`, not `"FF"`).
  Touches one line in `arc0.lisp`.

## State of the working tree at end of session

Branch `main`, ahead of `origin/main`. `news.arc` has unstaged
in-progress changes the user is iterating on (commented-out
`editor-changetime*` / `user-changetime*` gates in `canedit` /
`own-changeable-item`, an `md` binding in the story/poll fieldfns
that picks `mdtext` for editors vs `mdtext2` otherwise, and a
commented-out `pushnew 'locked i!keys` in the save callback). None
of these are mine -- they were already in the working tree when the
session began and should be left for the user.

## Test status

`./test.arc` runs 295 tests; all pass after `69500dd`. The new
atstring tests in `(define-test atstrings ...)` will fail-by-crash
(EOF in list at boot, because tests in this file evaluate at
load-time) if `arc-copy-balanced-paren`'s escape handling is removed,
which makes the regression visible.
