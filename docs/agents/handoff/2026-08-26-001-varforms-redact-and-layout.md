---
name: varforms, the redact field, and table colspans
description: 27 commits after the startup-speedups handoff. `defplace` now takes any number of args (so `me`/`ip`/`op`/`redact` are settable places), `vars-form` stopped clobbering fields that share storage, a per-user `redact` profile flag replaces a user's comments with "[redacted]", listing tables collapsed to a fixed 2-column layout matching HN's, expunging the newest item rewinds `minid*`, and /users got much faster. Also: a numbering bug the colspan plumbing introduced in `display-page`, found and fixed on the way out.
type: project
---

# Handoff: varforms, redact, and table layout (2026-08-26)

Covers `0749cf1..456f0f9`, i.e. everything after
`2026-08-25-001-startup-speedups-and-hn-rate-limit.md`. All of it is
front-end and app-layer work; nothing in this batch touches the loader or
the scraper's rate limiting.

## 1. `defplace` for any arity, and `me`/`ip`/`op`

`defplace` (`arc.arc:533`) used to hardcode one argument:

```arc
(mac defplace (name place)
  `(defset ,name args
     (list (list)
           (apply ,place args)
           `(fn (val) (= ,(apply ,place args) val)))))
```

The old version bound the single arg to a `uniq` and wrapped it in the
setter's let-list. The new one passes the args straight through and emits
an empty binding list, so the place expression is re-evaluated on both the
read and the write. That is fine for the places we define with it (all are
`(the ...)` or `(uvar ...)` lookups), but it does mean **`defplace` no
longer protects against a side-effecting argument expression** -- don't
use it for something like `(defplace foo (fn (x) ...))` called as
`(= (foo (pop xs)) v)`.

That unlocked zero-arg places, so `me`, `ip` and `op` became settable
(`app.arc:236`). `me` and `op` also got simpler: `(if (no args) (the me)
(caris args (the me)))` instead of the let-then-test form.

Related, in `arc1.lisp`: `uniq` now coerces a non-symbol, non-string
argument to `gs` rather than formatting whatever it was into the name.
`(uniq 5)` used to produce a symbol named `51234`.

## 2. `vars-form` no longer overwrites equal values

`app.arc:694`. The submit handler now skips a field whose newly-read value
`is` the value the form was generated with:

```arc
(unless (in newval fail* val)
  (f name newval))
```

**Why this matters:** two varform fields can be backed by the same
storage. The user profile now has both a `sexpr keys` field (admin-only,
the raw keys list) and a `yesno redact` field that is really
`(mem 'redact (uvar u keys))`. Without this check, whichever field is
processed second writes its stale snapshot back over the first one's
effect, so toggling redact and saving would immediately undo itself.

`vars-form` was then refactored for clarity (`a3bfab4`): `modifiable` is
computed once with `(some !4 fields)` instead of `(all [no (_ 4)] fields)`
being recomputed in two places, and the body reads `(req-args)` rather
than reaching into `(the req)` by hand.

Two smaller varform fixes in the same pass:

- `sexpr` fields are `trim`med, so `'(foo bar)` renders as `"foo bar"` in
  the text input instead of `"foo bar "`. That trailing space was enough
  to make a round-trip look like an edit.
- `needcols` (`app.arc:617`) was extracted because `needrows` was being
  passed `formwid*` even for `doc` fields, which are laid out at
  `bigformwid*`. Row counts for docs were wrong before.

## 3. The `redact` profile field

`c89e41f`. A per-user flag: when set, that user's comments render as
`[redacted]` to everybody except the author and admins.

```arc
(def redact ((t u me)) (check-key 'redact u))
(defplace redact (fn (u) `(mem 'redact (uvar ,u keys))))
(def redacted (i) (redact:by i))
```

Stored as a key in the user's `keys` list, not as its own profile field --
which is why `vars-form` needed the fix above. The profile row is
`(yesno redact ... ,u ,u)`: **visible and modifiable by the user
themselves**, not admin-only. `saveuser`'s field setter special-cases the
name so `(= (redact user) val)` runs instead of `(= (prof 'redact) val)`.

Display side:

- `pseudo-text` checks `redacted` before `deleted`, so redaction wins.
- `itemline` prints a ` [redacted] ` marker, but only for the author or an
  admin -- the point is to tell the people who *can* still read it that
  nobody else can.
- `display-comment` gates the body on
  `(or (~cansee c) (and (redacted c) (~author c) (~admin)))`.

Note that this covers *comment* rendering. Stories by a redacted user are
not currently masked.

## 4. Listing tables are now a fixed 2 columns

`bba7d03`, and then four follow-up commits fixing the pages it broke.

The old markup varied its column count depending on whether the listing
was numbered: `(td colspan (if number 2 1))`, `(tr (if n (td)) (td) ...)`,
and `display-item-number` emitting no `<td>` at all when `i` was nil. Now
the rank cell is always emitted (`(only&pr i ".")` prints nothing when
there is no number) and spanning cells always say `colspan 2`. This is
what HN's own markup does.

The pages that then needed adjusting, in the order they were found:

- `delete-confirm-page`: `(td colspan (if (acomment i) 1 2))` -- a comment
  being deleted has no rank cell of its own to span past.
- item page comment form: went `(row "" ...)` -> `(row "" "" ...)` ->
  back -> finally the explicit `(tr (tag (td colspan (if (acomment i) 1
  2))) (td (comment-form i here)))`. The `row` macro could not express the
  conditional span.
- `addcomment-page`: stayed at `(row "" ...)`.
- `display-item-text`: dropped its `spacerow 2`; the comment form's
  leading spacer went 10 -> 6.

`row` itself now expands via `` `(td ,_) `` rather than `(list 'td _)`,
purely for readability.

### The colspan argument, briefly mis-forwarded

`display-page` gained a `colspan` parameter (`2e9d857`) so `/users` can
pass `0` and skip the spanning cell entirely. The recursive `morelink`
call forwarded it into the wrong slot, and `456f0f9` fixed it:

```arc
-  number moreurl (+ numstart perpage* colspan)
+  number moreurl (+ numstart perpage*) colspan
```

`colspan` was being *added into `numstart`* rather than passed as the next
positional arg, so the More link's page numbered two too high (page 2 of
`/submitted` started at 33, not 31) and `colspan` never reached the
recursive call at all. `/users` never showed it, because it supplies a
`moreurl` and `morelink` therefore skips the fnid branch entirely -- worth
remembering when testing anything in `display-page`'s More path.

## 5. Item ids rewind on expunge

`b810824`. `expunge` now calls `rewind-item-id`:

```arc
(def rewind-item-id (id)
  (w/lock minid-lock*
    (when (is minid* id)
      (++ minid*)
      (todisk minid*))))
```

`minid*` counts *down* (user-generated items get negative ids), so
expunging the most recently created item releases its id for reuse. The
`(is minid* id)` guard means this only fires for the newest item; expunging
anything older leaves a hole, as before. Takes the same lock as
`new-item-id`.

## 6. /users made fast again

`d0866c5`. `w/loading-items` moved out of `submissions` and into
`user-comments`.

`submissions` is called by `/users` (via `userlist`), by `/submitted`, and
by `comments`. Wrapping it meant `/users` paid to load every item every
listed user had ever posted. The original reason for the wrapper was cold-
start `/threads`, and `/threads` goes through `user-comments`, so moving it
one level down keeps that win and drops the cost everywhere else.
`display-user` also `flushout`s per row now, so the page streams.

## 7. Odds and ends

- `scrape-user-batch!` no longer takes `scrape-lock*` (`86638ef`). It only
  needed it around the `keep`/`pop-user-to-fetch` bookkeeping, and holding
  it there serialized user scraping against the HTML crawl for no reason.
  Note this is a lock *removal* in a file that is otherwise carefully
  serialized -- see `2026-08-25-001` §5 for why `fetch-hn-url` still is.
- `stalled-bgthreads` uses `out`/`since` instead of `accum`/`(- (seconds)
  since)`; `bgtick` uses `(= (bgticks* id) ...)` instead of `sref`.
- `text-date` destructures `timedate` forward instead of `rev`ing it, and
  builds its string with `+` instead of `tostring`.
- `user-fields` and `redact` take `((t user me))`, so they default to the
  current user -- mainly for repl use.
- The profile's `topcolor` row reads `(hexrep:main-color user)` instead of
  `(or (p 'topcolor) (hexrep site-color*))`.

## Working tree state

Not committed, and deliberately left alone:

- `news.arc`: `ranklink` is commented out in `display-story`'s subline.
  Looks like an in-progress experiment, not a finished change.
- `script.arc`: untracked scratch buffer for poking at
  `parse-fatitem`/`parse-comments` against a saved `foo.html` for HN item
  49378957. Not part of the build.
