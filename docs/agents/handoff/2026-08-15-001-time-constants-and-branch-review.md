---
name: Time constants and the loop-macro-ordering branch review
description: Sixteen commits landing sec*/min*/hour*/day*/year* across news/srv/scrape, the app.arc reorganization, and per-item save batching in the scraper; plus the ten bugs the review caught, every one of which passed the 909-test suite, and the sandbox method that found them.
type: project
---

# Handoff: Time constants and branch review (2026-08-15)

## What was accomplished

Sixteen commits on `loop-macro-ordering`, then `main` fast-forwarded onto it
(`b7b3139..bf1d8ec`). The session was one long review loop: the user kept a
large working-tree diff across seven files, asked "is this correct?", fixed
what the review found, and asked again. Eight rounds. The final code is fine
and readable in the commits; **the value here is the bug list**, because the
same shapes will recur the next time this refactor continues.

The three threads that landed:

- **`sec*` / `min*` / `hour*` / `day*` / `year*`** defined in `arc.arc` with
  `(mac com (e) (eval e))` folding them at macroexpansion time, then applied
  across `news.arc`, `srv.arc` and `scrape.arc` in place of bare 60 / 3600 /
  86400 / 1440 literals.
- **`app.arc` reorganized** (`12de9e2`) so definitions sit next to what uses
  them, and the per-IP account-creation tracking moved out of `recaptcha.arc`.
- **Per-item save batching in the scraper** (`bf1d8ec`): `import-scraped-item!`
  now collects touched ids in a `saves` table and writes each once at the end,
  instead of re-saving a parent every time a child links itself into `kids`.

Ten defects were found and confirmed at runtime. Four were tree-breaking, and
all ten are listed below because the classes matter more than the instances.

## The bugs, by class

### 1. Definition order against macro definitions

`(def number (n) (in (type n) 'int 'num))` was hoisted from `arc.arc:1617` to
line 65. `(mac in ...)` is at line 217. The file loads form by form, so at
line 65 `in` is not yet a macro and the body compiled as a *function* call:

```
(number 3)            => invalid number of arguments: 4
(readvar 'int "42")   => invalid number of arguments: 4
```

Live callers: `app.arc`'s `num` / `int` / `posint` form-field parsers (profile
editing), `html.arc:283` and `:316`, and `arc.arc`'s `positive`. Nothing
warns; you get a runtime arity error at the call site, far from the cause.
**Moving any `def` in `arc.arc` upward is a load-order change, not a cosmetic
one.** Final placement is line 1960, below `in`.

### 2. `rev!` aliasing

`rev!` is a destructive nreverse. After `(rev! xs)` the variable `xs` still
points at the *original head cell*, which is now the list's last cell:

```arc
(forlen i (rev! positions)          ; iterates the full length
  (withs (p (ps i) ...)))           ; but positions is now a 1-element list
```

`scrape.arc`'s `parse-split` was written this way and died with
`The index 1 is too large for a list of length 1` on any page with more than
one item, i.e. the entire scraper. The safe form is what the sibling function
at `scrape.arc:418` already did: `(let ps (rev! positions) ... (ps i))`. Bind
the result; never re-read the variable you destroyed.

Every other `rev` → `rev!` conversion in the diff was checked individually and
is fine, because in each case the operand is a fresh list or is not read again.

### 3. `t` as a parameter name

`recaptcha.arc` had `(def note-acct-creation ((t ip) (o t (seconds))))`, a
parameter literally named `t` shadowing the boolean. Renaming it to `t0` on the
move to `app.arc` missed one use in the body, so it consed the symbol `t`
instead of a timestamp:

```
(note-acct-creation) then (recent-acct-creations)
  => The value T is not of type REAL
```

`recaptcha-required` calls it without `errsafe`, so once an IP had created one
account, every later signup from that IP threw. Note this is distinct from the
`(t var)` *parameter sugar* documented in `CLAUDE.md`: `(t ip)` expands to
`(o ip (the ip))` and is fine; a bare `t` as a name is the trap.

### 4. Table-style access on nil errors, it does not return nil

```
(scraped-users nil)
  => The value ARC::|story| is not of type (UNSIGNED-BYTE 45)
```

`(nil 'story)` compiles to `(elt nil 'story)`. `scrape-item!` returns nil on a
failed fetch (`scrape.arc:553`), so `scrape-item-and-users!` threw on any
network hiccup. Fixed with `whenlets`, which also covers `scrape-and-import!`
where the same shape was already latent before this branch. Relatedly,
`scraped-users` needed `(rem nil ...)` because deleted comments carry a nil
`by` (hence the `(or c!by "deleted")` in `comment-from-scraped-comment`).

### 5. Extractions that reverse a dependency

Pulling the bucket loop out of `load-items` into `load-item-buckets` also
swapped the call order in `load-news`. The dependency is real and silent:

`load-items` → `latest-items` → `each-item` → `all-item-ids` →
`cached-item-ids` → `(item-ids* bucket)`

and `cached-item-ids` (`news.arc:354`) reads the table with **no fallback** to
`(item-ids bucket)`. Measured on a sandbox with two stories on disk:

```
load-items then load-item-buckets  =>  load-items returned 0 items
load-item-buckets then load-items  =>  load-items returned 2 items
```

A cold `(nsv)` loaded nothing. Same family: `ensure-scrapedirs` was extracted
from `load-scrape` and dropped `scrape-lists-dir*` from the list, so
`save-hn-list` failed with `The path .../arc/scrape/lists/ask.<tmp>.tmp does
not exist` on a fresh install. When extracting a helper, diff the *set* of
things it does, not just the shape.

### 6. Renaming a variable but keeping the old one in a mutation

In the `saves` refactor, `(save-item p)` became `(set (saves it!id))` where it
should have been `(saves p!id)`. It usually looks fine because every comment
and the story in a batch get marked anyway, so the parent is normally saved by
coincidence. It only bites when a thread is scraped in parts and a comment's
parent is not in `it!comments`. Verified after the fix: story + two nested
comments, then clear `items*` and reread from disk, gives `kids` of `(101)` on
the story and `(102)` on the comment.

### 7. Unit drift inside a units refactor

The whole point of the constants is that they are in **seconds**, but
`item-age` is in **minutes** (`news.arc:572`, `(minutes-since i!time)`). So
every converted threshold that is compared against `item-age` needs `(/ x
min*)` at the comparison site. Two things went wrong here:

- `180` in `oversubmitting` is 180 *minutes*; it was converted to
  `(* 2 hour*)`. Should be `(* 3 hour*)`. The comment above it said "2 hour
  period" and was itself wrong, which is presumably how it happened.
- `timebase* 120` is 120 *minutes*; it briefly became `(* 2 min*)`.
  Numerically identical (both 120) but semantically two hours off. The final
  version is `(* 2 hour*)` with `news-score-div` rewritten to convert honestly:
  `(let secs (+ (* age min*) timebase*) (expt (/ secs hour*) gravity))`.
  Verified equal to the old formula at ages 0 / 30 / 120 / 1440.

Three cache timeouts also drifted (`userlist` 45→60, `topcolors` 90→300) before
being reverted to `(* 45 sec*)` and `(* 90 sec*)`. **A units refactor should
change zero values**; every constant in the final diff was checked to hold its
original number.

## Why the test suite decided nothing

`./test.arc` reported **909 passed, 0 failed** on every single broken version,
including the one where `arc.arc` would not even load. It caught none of the
ten. This is the same finding as the previous handoff
(`2026-08-09-002`), and it now has ten more data points: the suite covers
`arc.arc` primitives, not `news.arc` / `srv.arc` / `scrape.arc` behavior.

What actually worked, in order of cost:

**A paren-balance scan**, which found the `srv.arc` extra `)` instantly and
pinpointed the line. Worth keeping as a first move on any large lisp diff:

```python
# skips strings, ; comments and #\c char literals; reports final depth
# and the first line where depth goes negative
```

**A sandbox copy of the repo**, so probes never touch the user's tree or their
2.6GB `arc/` data directory:

```sh
SP=<scratchpad>/repo; mkdir -p $SP
cp *.arc *.lisp *.json sharc $SP/; cp -r lib static $SP/
mkdir -p $SP/arc && touch $SP/arc/admins     # load-admins errors without it
cd $SP && ./sharc probe.arc
```

**Runtime probes rather than reading.** Every claim in the review that
mattered was executed. Several readings that looked airtight were wrong until
tested, notably the assumption that `(nil 'story)` returns nil.

Three gotchas when writing probes against `news.arc`:

- `(leaderspage)` and anything wrapped in `newscache` calls `(arg 'perf)`, so
  it needs a request: wrap in `(w/args nil ...)`, and `(w/me "alice" ...)` for
  the admin path.
- `(profile u)` returns nil for a user with no profile on disk; use
  `(init-user u)` first, then `(= (uvar u karma) 50)` and `(save-prof u)`.
- Stub the network rather than reaching it: `(def fetch-hn-item (id) nil)` is
  enough to exercise the whole failed-fetch path.

## Two idioms this branch leans on

**`w/break` binds both `break` and `out`.** Every loop macro (`each`, `for`,
`forlen`, `repeat`, `whilet`, `while`, `loop`) now expands through it and
returns its accumulated `out` list, whether it finishes or breaks. That is what
makes all the `(accum a ... (a x))` → `(... (out x))` conversions in this diff
work, and why a function whose last form is an `each` now returns a list where
it used to return nil. Nested loops shadow `out`, so an `out` in a body always
belongs to the innermost enclosing loop.

**`only&f` is `(andf only f)`** with `(def only (x . args) x)`, so
`(only&save-item (item id))` means "call `save-item` if `(item id)` is
non-nil", and the argument is evaluated once, not twice.

## Current state

`main` at `bf1d8ec`, **50 commits ahead of `origin/main`, unpushed**.
`loop-macro-ordering` points at the same commit. Suite: 909 passed, 0 failed.

Working tree has `arc.arc` modified: nine lines, a commented-out `point2` /
`catch2` pair using `#'block` / `#'return-from` as an alternative to the `ccc`
based `point`. Deliberately left uncommitted.

Two things raised in review and consciously not done:

1. **`news.arc:3329` calls `(update-avg u)` in the leaders page**, where it
   used to read the cached `(uvar u avg)`. `update-avg` recomputes
   `comment-score` *and* calls `save-prof`, and `newscache` bypasses its cache
   whenever `(me)` is set, so every admin view of `/leaders` recomputes and
   rewrites up to `nleaders*` (now 100) profiles. Confirmed it is a write:
   after an admin render, a user with no comments had `avg` set to nil and her
   profile rewritten. The `defbg update-avg` thread already maintains this
   field incrementally.
2. **`ensure-uid` re-enters `maxuid-lock*`.** `w/lock-or` takes the lock, then
   `new-user-id` takes it again. Verified not to deadlock (locks are reentrant
   here) and structurally identical to the pre-branch code, so this is noted
   rather than filed.
