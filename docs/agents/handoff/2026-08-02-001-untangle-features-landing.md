---
name: Landing the untangle-features branch
description: Overview of the 376-commit untangle-features branch (2026-07-05 to 2026-08-02) that fast-forwarded onto main; a thematic map of what changed, the breaking renames, and the open threads.
type: project
---

# Handoff: Landing `untangle-features` (2026-08-02)

## What this is

This is an **overview** doc, not a session doc. It covers the whole
`untangle-features` branch: 376 commits spanning **2026-07-05 to
2026-08-02**, which landed on `main` as a fast-forward on 2026-08-02.

Commit range: **`f81bda3..3958610`**.

The per-session detail for three sub-efforts already lives in its own
handoff and is *not* repeated here. Read those first if you are touching
the relevant area:

- `2026-07-09-001-keywords-ssyntax-orf-and-branch-review.md`
- `2026-07-25-001-http-timeouts-and-cookie-jar.md`
- `2026-07-27-001-global-cells.md` (the deepest of the three; read it
  before touching `arc0.lisp`/`arc1.lisp`)

Everything else on the branch is summarized below.

## How it landed

`main` had not moved since the branch point, so `merge-base(main,
untangle-features) == main == origin/main == f81bda3`. There was nothing
to rebase; it was a pure fast-forward:

```sh
git push origin untangle-features
git checkout main
git merge --ff-only untangle-features
git push origin main
```

No merge commit, no squash. History stays linear and every commit is
individually meaningful, which matters here because the branch is mostly
a long sequence of small named refactors ("Define `lets`", "Extract
`should-ban-ip` from `maybe-ban-ip`") rather than a few large features.
`git log --oneline` over this range reads as a usable changelog; keep it
that way.

## Reading the diff

`git diff --stat f81bda3..3958610` reports **504 files, +90,939 /
-1,658**, which badly overstates the hand-written work. Almost all of the
insertions are vendored Common Lisp libraries under `lib/` plus
`wordlist.json`.

The actual authored change, by file:

| file | lines changed |
|---|---|
| `news.arc` | 1562 |
| `scrape.arc` | 904 |
| `test.arc` | 621 |
| `sitename.arc` | 326 (new) |
| `strings.arc` | 191 |
| `srv.arc` | 88 |
| plus `arc.arc`, `arc0.lisp`, `arc1.lisp`, `app.arc`, `html.arc`, `json.arc` | |
| new: `cookies.arc`, `parallel.arc`, `profiling.arc`, `memorable.arc` | |

If you are trying to understand the branch, ignore `lib/` entirely.

## Theme: arc core language

New binding and control forms, most of which are now used pervasively
and which you should reach for instead of the older idioms:

- **`lets`** (`arc.arc:134`) and **`whenlets`** (`arc.arc:765`):
  sequential `let`/`whenlet`. These are the single most common change on
  the branch; dozens of "Minor usage of `lets`" commits are mechanical
  conversions.
- **`map0`** (`arc.arc:86`), **`mapv`** (`arc.arc:510`), **`zip`**
  (`arc.arc:293`).
- **`com`** (`arc.arc:47`): evaluates its argument at compile time.
- **`defplace`** (`arc.arc:368`), **`zaptable`** (`arc.arc:703`),
  **`accumulate`** (`arc.arc:786`, extracted from `accum`).
- **`w/the-if`** (`arc.arc:1973`) for the thread-local `the` machinery.
- Multiple assignment: `(= (list a b) '(1 2))` (`37ae829`).

Sequence and collection work:

- **`cut` was rewritten and its contract narrowed.** See breaking changes
  below. `cut` is now `cut2` (`arc.arc:538`), a thin wrapper over CL
  `subseq` with `end` clamped by `(min end (len seq))`.
- **`edge`** and **`almost`** (`arc.arc:540`): `(edge xs)` is the index
  one before the end; `(almost xs)` is everything but the last element.
- **`cleave`** (`arc.arc:1389`), **`fresh`** (`arc.arc:1257`), `copy`
  gained vector support, `split` accepts a nil pos (`44c6fdf`).
- **`positions`** promoted to `arc.arc` with a `start` arg; **`lastpos`**
  added (`arc.arc:869`).
- Tables are now valid arguments to `find`, `rem`, `keep`, `pos`, etc
  (`e8f790f`), and `(testify x id)` works for fns and tables (`0f8f56b`).
- **`least`** (`arc.arc:1070`), the opposite of `most`.
- **`shuffle`** (`arc.arc:1929`), **`rand-elts`** (`arc.arc:1028`);
  `rand-elt` works on tables; `rand` accepts 0 and negatives.
- **`dedup`** now uses `isotable` and takes a `key` arg (`3783d98`).

Types, syntax, and coercion:

- **Keywords are a first-class type** (`8164af0`). Beware the interaction
  with `obj`: `(obj foo: 42)` and `(obj foo 42)` both produce *symbol*
  keys, not keywords (`3d60978`), and html ops convert keywords to
  symbols (`8bbdcfe`).
- **`|` (orf) ssyntax** mirroring `&` (andf) (`517040c`). Precedence was
  settled twice: `&` binds highest (`c7b9dc3`), and `|` splits before `&`
  (`80e0bf2`).
- **`as`** (`arc.arc:83`), a general coercion entry point.
- **`asnum`** (`arc.arc:1814`); `inc` supports decimal strings like
  `"1.2"`.
- **`clamp`** (`arc.arc:517`), **`zeropad`** (`arc.arc:1536`).
- Valid symbols now include `\(`, `\[`, `\{`, `\\` and any backslash
  escape (`ffe68be`).
- `-inf`, `inf`, `nan` added with tests (`0feca0a`).
- `isa` accepts multiple types: `(isa x 'string 'num)` (`b59c041`).
- Coercing a function by accident no longer stack-overflows (`2bbb27f`).

Threads:

- **`thread-locals` refactored so thread A can read thread B's locals**
  (`2ee33c1`), then made lock-free when the local already exists
  (`bc38bf9`).
- **`join-thread`**, **`cleanup-thread`** extracted from `start-thread`,
  **`restart-bgthreads`** (`srv.arc:767`).
- `defbg` now overrides its past behavior on redefinition (`1ec8cb8`),
  which matters for hot reload.
- **`main-thread`** (`arc.arc:1995`); `main-thread*` is protected from
  being clobbered by a server reload (`078adc4`).
- Threads default to 16mb control stacks (`68bb207`); `threadlife*`
  bumped to 60s.

## Theme: performance

Several of these were measured, not guessed:

- **`mergesort`/`merge` optimized for a ~1.7x to ~3x speedup**
  (`91992fe`); `mergesort` also short-circuits when the list is already
  sorted (`211d79e`).
- **`downcase`/`upcase` sped up by roughly 100x** (`45360a4`).
- **`>` and `<` optimized for the two-arg case** (`4809b48`); `string`
  optimized for the one-arg case (`90cba75`).
- `keys`/`vals`/`tablist` optimized via `accumulate` (`14638e7`).
- `arc-ref` extracted from `ar-apply` and refactored to use `sequencep`
  and `elt` (`517b17f`).
- Compile-time global cells (`0d6e994`), covered in its own handoff.
- **`parallel.arc`** (`parallel.arc:1`): `(parallel f seq (o n 50) (o
  noisy))`. `n` of 0 disables parallelism.
- **`profiling.arc`** added and later reworked (`c76e51a`, `5a5eb61`).
  Note the global-cells handoff flagged an unbound
  `arc-sampling-interval*` in an earlier version; `5a5eb61` is the
  follow-up, so re-check before trusting that warning.
- REPL and error output now respect `*print-length*` / `*print-level*`
  (`a7777c4`), which stops huge structures from flooding backtraces.

## Theme: runtime and infrastructure

- **HTTP layer**: read timeouts and `http-response` (`5eb3a50`),
  `reassemble-url` (`srv.arc:410`), `parse-url` (`html.arc:446`).
- **`cookies.arc`**: client-side cookie jar, with tests alongside
  `http-fetch` tests (`2f769b2`, `2e19191`).
- **Crypto**: arc `rand` is now cryptographically secure and `randb` is
  gone; `srand` and `rand64` added (`ec2e556`, `ffcb7d8`). This is why
  ironclad is vendored.
- **`memorable.arc`**: `memorable-names` and `memorable-pws`, backed by
  `wordlist.json`.
- **Env**: `readenv` added; `PORT=1234` now listens on 1234 instead of
  8080 (`00b65dd`, `e6a6b2a`). `readenv` treats `FOO=false` as nil
  (`679dd22`). `site-url*` defaults to localhost on the correct port.
- **Files/processes**: `dirs` and `files` (`arc.arc:1517`, `1523`),
  `copyfile`/`cpfile`, `dispfile` (`arc.arc:986`), `writefile` gained a
  `write` arg, `tmpname` extracted. `system` and `pipe-from` accept a
  list instead of a string (`5b0afa3`); `pipe-from` gained `wait` and
  `format` args; a crash on long `system` output was fixed (`8651123`).
- **JSON**: `as-json` (`json.arc:37`), `load-json` no longer swallows
  errors (`a3a13ce`), `'empty` serializes to `"[]"`, `save-json` uses
  `writefile`.
- **`serialize`/`deserialize`** (`arc.arc:1470`).
- `ero` is atomic so error lines do not interleave (`3126b62`).
- `string->utf8` for latin-1 to utf-8 conversion (`29390ad`).
- **`uniq` takes a name argument** (`3277aba`) and call sites were
  updated to pass one; gensym prefix default changed to `"gs"`. This
  makes macroexpansions far easier to read.

## Theme: news.arc

This is the largest block of authored change and the part most likely to
surprise you.

**uid as primary key.** The big structural change (`745c643` "Add uid
system", `7f4e93a` "use uid as primary key; rework loading"). Items now
store a numeric `by` uid rather than a username string. Consequences:

- `(by i)` (`news.arc:269`) resolves `uid->user*` and **asserts** if the
  uid is unknown, with a message naming the story and item
  (`uid-message`). A missing uid is now a loud failure, not a silent nil.
- `safe-uid` / `ok-uid` join the `safe-id` family (`news.arc:427`).
- `/user` accepts a uid (`ad3e84e`); `recent-votes-by` keys on uid.

**The accessor family.** A large number of "Use accessors" commits are
mechanical conversions to these; learn them before reading `news.arc`:

| accessor | location | meaning |
|---|---|---|
| `(my k)` | `news.arc:157` | `((profile) k)`, current user's profile field |
| `(uvar u k)` | `news.arc:156` | profile field of user `u` |
| `(by i)` | `news.arc:269` | item's author, asserting on unknown uid |
| `(author i)` | `news.arc:277` | is the current user the author |
| `(same-author i s)` | `news.arc:279` | |
| `(same-ip i s)` | `news.arc:281` | |
| `(shown i)` | `news.arc:638` | `cansee` and not hidden |
| `(stories)` | `news.arc:3175` | |
| `(votable i)` | `news.arc:2075` | extracted from `vote-for` |
| `(user-voted-for i test)` | `news.arc:1926` | |

Plus predicate accessors for `dead`, `deleted`, `announcement`,
`imported`, and `voted` (`f9885f9`).

**Note the bracket-lambda gotcha in `CLAUDE.md` applies constantly here**:
`[_!dead]` expands to a *call* of the result. Use `[_ 'dead]`.

**Item storage.** `put-item` and `pull-item` macros (`news.arc:354`) wrap
`insortnew`/`pull` with the standard `compitem`/`sameitem` comparators,
replacing open-coded sorted-insert calls. `latest-items` reworked;
`loaded-item-ids` extracted from `each-loaded-item`.

**Pagination.** `pagems` (`news.arc:866`) returns `(or (the ms) (msec))`,
a per-request timestamp threaded through the thread-local `the` system so
paginated views are consistent within a request. `paginated`
(`news.arc:1166`) is the new general lister; `listpage` was reworked on
top of it (`94b3f56`). Pages can display arbitrary things (`4f4634d`).
`maxend*` set to nil (`a075eb8`); the "More" label shows the number of
items remaining (`769cf3b`).

**Voting.** `c013041` "Track vote effects and fix `unvote-for`" is a real
bugfix, not a refactor. `votable` was extracted from `vote-for`.

**New ops.** `/show` (`8876008`), `/users` admin endpoint (`f6512d0`),
`newsopg` (`news.arc:886`). `/lists`, `/from`, `/collapse`, `/hidden`,
and the topcolors op were each simplified or reworked.

**HN visual parity.** A running theme: `sitename.arc` (new, 326 lines)
reworked to match HN with ellipsized long sitenames; `hspace` removed;
`toptext` div added; comment textarea matched to HN; dead-comment layout
fixed; `noob-days*` set to 14; admin bar reworked; kill link moved next
to blast link.

**Security/permissions.** `visible-family` no longer includes deleted
items (`050dc10`); userlinks are hidden for items the user cannot see
(`1c10295`); `good-auth` checks `arg!hmac` and `hidden-input` /
`auth-input` / `item-form` were introduced (`b8a7225`); admins bypass
title limits (`f3939b8`); profile form escaping fixed (`ac6f9e3`);
`init-user` hardened (`1f02266`).

## Theme: app.arc and accounts

- `app.arc` broadly simplified with helpers extracted (`b4ef421`).
- `user-exists` renamed to **`acct-exists`** (`app.arc:207`).
- `save-pws` extracted from `set-pw`; passwords are saved after being set
  (`7ebd3a8`, `80785d0`).
- `copy-account` (`app.arc:271`).
- `hpasswords*`, `cookie->user*`, `user->cookie*` are always initialized
  (`8ed1c96`).
- `(hook 'login)` fires after *any* successful login (`1b6cfa1`);
  favorites-on-login bug fixed (`2d8f269`).
- Usernames may start with `-` (`6011c66`); `goodchar` extracted from
  `goodname`.
- `w/args` moved to `app.arc`; `fake-req` added (`app.arc:155`) for
  driving ops without a real request.
- `op` is variadic (`b59a4c4`).

## Theme: scrape.arc

Reworked several times over the branch (`94dbd6a`, `2de827e`, `c104b34`).
Now scrapes HN *list* pages, not just items, and parses: item rank,
comment count, timestamp, `[dupe]` markers, and sitename.
`parse-split` extracted from `parse-listpage` (`scrape.arc:368`);
`parse-pseudotext!` and `parse-hn-itemlist` added. Crawl delay reworked
and tuned to `0.55`s; `scrape-refresh-secs*` set to 5 minutes. Deleted
comments import under the user `"deleted"`. Toplevel error reporting
fixed (`a9eb0fa`).

## Vendored libraries

`lib/` now contains six vendored CL libraries, pinned by commit in
`lib/MANIFEST`:

| lib | ref | why |
|---|---|---|
| ironclad | v0.61 | secure `rand`, `srand`, `rand64` |
| bordeaux-threads | master | ironclad dependency |
| alexandria | master | ironclad dependency |
| global-vars | master | ironclad dependency |
| trivial-features | master | ironclad dependency |
| trivial-garbage | master | ironclad dependency |

**To re-vendor, run `./vendor.sh`.** It clones each at the pinned ref,
strips `.git`, rewrites `MANIFEST`, and then *fails loudly* if any
gitignore rule would exclude a vendored file. Do not hand-edit `lib/`.

## Breaking changes and renames

These are the ones that will bite a future agent working from older
knowledge of the codebase:

| before | after | commit |
|---|---|---|
| `cut` accepted negative indices | **removed**; out-of-range `end` is clamped | `fdfa781`, `37a40d9`, `f04f8e5` |
| `dead` (thread predicate) | **`dead-thread`** (`arc0.lisp:1489`) | `09204a8` |
| `user-exists` | **`acct-exists`** | `00213ce` |
| `arg->item` | **removed** | `aa3035a` |
| `randb` | **removed**; `rand` is now secure | `ec2e556` |
| `*arc-direct-calls*` | **removed** | `c66ce37` |
| `reinsert-sorted` / `insortnew` arg `cmp` | **`same`** | `ba1a6a1`, `8635525` |
| items store author as username | **uid**; use `(by i)` | `7f4e93a` |
| `PORT` ignored | `PORT=1234` binds 1234 | `00b65dd` |

`cut` deserves emphasis: the negative-index removal is silent at the call
site. `(cut xs 0 -1)` used to mean "all but last" and now does not. That
is exactly what `almost` was added for.

## Verification

`./test.arc` at `3958610`: **853 passed, 0 failed.**

For context, the same suite was 779 passing at the time of the
global-cells handoff on 2026-07-27, so the branch added roughly 74 tests
in its final week, concentrated in `test.arc` (621 lines changed),
`cut` edge cases, string coercion, `http-fetch`, and `cookies.arc`.

Secrets hygiene is intact: `scrape.json`, `smtp.json`, and
`recaptcha.json` are gitignored and only the `.example.json` variants are
tracked. Confirm this stays true before any future push, since `origin`
is a public GitHub repo.

## Open threads

- **Removing the global mutex.** A full plan was written but not
  executed: `docs/agents/plans/2026-08-02-001-remove-global-mutex.md`
  (207 lines). Its key insight is that all hash tables are already
  `:synchronized t` and globals already have their own `gcell` creation
  lock, so `*arc-mutex*` is only protecting *composite invariants across
  several structures*, which is a much smaller job than the ~20 `atomic`
  call sites suggest. It also notes the world lock is taken at least four
  times per HTTP request. Start there.

- **The reranking background thread is disabled.** `da45c73` commented
  out `(defbg rerank-random 30 (rerank-random))`, now at `news.arc:605`.
  The function itself is still defined at `news.arc:607`. This was a
  deliberate temporary
  disable, not a deletion; front-page rank will not drift on its own
  until it is restored.

- **Markdown links are `rel=nofollow` "for now".** `b3e16fe` changed
  `app.arc` to emit `(tag (a href url rel 'nofollow) ...)` instead of
  `link`. The commit message says "for now", so this is a decision to
  revisit, not settled behavior.

- **`frontpage-rank` was broken into separate functions for readability**
  (`afeda8a`) but the ranking *policy* was not changed. If you are
  tuning ranking, the split is the place to start reading.

- **`profiling.arc`** was added mid-branch and reworked at `5a5eb61`.
  The global-cells handoff warns about an unbound `arc-sampling-interval*`
  in the original version; verify against current `profiling.arc` rather
  than assuming either state.
