# Submit/poll form rework, ranked json kids, duplicate-comment suppression

Date: 2026-06-30

Another review-and-commit session in the same style as `2026-06-30-004`:
the user staged changes one at a time, asked "what do you think of the
staged changes?" for each, iterated until correct, then landed each as
its own commit (`commit (don't add anything)`). Four `news.arc` commits.
Session range on `main`: `f22bee6..3796a1e` (parent `f22bee6` was the
prior tip / the 004 handoff commit).

## What was accomplished

- **`828b95e`** `news.arc`: reworked the story submit flow.
  - Simplified the submit form to always show title / url / text rows;
    dropped the `showtext` plumbing and the `prefer-url*` field-ordering
    branch. `prefer-url*` is now removed.
  - Renamed form fields from terse `t`/`u`/`x` to readable
    `title`/`url`/`text` (both the `input`/`textarea` names and the
    `arg!` reads), and gave the optional params proper `(o ... "")`
    defaults. `submit-page` / `submit-login-warning` / `process-story` /
    `submitlink` signatures all updated in lockstep.
  - New HN-style behavior: when a submission has **both** a url and body
    text, the story is created from the url and the text is posted as a
    separate top-level comment (`septext` branch in `process-story`:
    `withs (septext (and (~blank url) (~blank text)) s (create-story ...)
    c (if septext (create-comment s text)))`, then `(when c (submit-item c))`).
  - **Markdown is now applied exactly once per path.** `submit-page`
    passes raw `arg!text` through; `create-story` does its own
    `(only&md-from-form text t)` for the story body, and `create-comment`
    does its own `md-from-form` on the split-off comment. (See Key
    decisions - the first staged version double-processed the comment.)
- **`89671d9`** `news.arc`: renamed the new-poll form fields from
  `t`/`x`/`o` to `title`/`text`/`choices` (input names + `arg!` reads),
  matching the submit form. Cosmetic, behavior-preserving.
- **`27b6889`** `news.arc`: the json api's `kids` field now returns
  visible child ids in **ranked (display) order** instead of raw
  insertion order. Changed `(keep cansee:item i!kids)` to
  `(map !id (keep cansee (ranked-kids i)))` - routes through the same
  `ranked-kids` helper the rendered comment pages already use.
- **`3796a1e`** `news.arc`: duplicate-comment suppression. If the current
  user already posted an identical, visible comment under the same
  parent, `process-comment` links to the existing one instead of creating
  a duplicate. Switched the `if` chain to `aif` so the dup match binds to
  `it`; added clause `(find-duplicate-comment parent (normalize-text text))`
  -> `(string whence "#" it!id)`. New helpers:
  - `normalize-text` = `(unmarkdown (md-from-form text))`.
  - `find-duplicate-comment` = `catch`/`throw` loop over `parent!kids`,
    throwing the first `i` where
    `(and (cansee i) (me i!by) (is (unmarkdown i!text) text))`.

## Key decisions

- **Submit markdown double-processing was caught and fixed during
  review.** The first staged version of `828b95e` had `submit-page` pass
  `(md-from-form arg!text t)` into `process-story`, then the `septext`
  branch handed that already-HTML text to `create-comment`, which calls
  `md-from-form` **again** - and `md-from-form`/`markdown` runs
  `eschtml-char` on every char, so the second pass would escape the first
  pass's tags and render raw `&lt;p&gt;`/mangled links. Root cause: the
  two creators have different contracts (`create-story` historically
  stored pre-processed text; `create-comment` processes raw text itself,
  matching how `process-comment` calls it). Fix landed: pass raw text
  everywhere and move processing into `create-story` via
  `(only&md-from-form text t)` (preserves `nolinks=t` for story bodies).
  `create-story` has a single caller (`process-story`), so changing its
  contract was safe.
- **`find-duplicate-comment` scope: own + visible + same parent only.**
  `(me i!by)` (arg form of `me`, app.arc:41, = `(is (the me) i!by)`)
  restricts to the submitter's own comments; `(cansee i)` was added in a
  later review round so a deleted prior comment isn't linked back to;
  only direct `parent!kids` are checked. This is double-submit protection,
  not global dedup.
- **Normalization is symmetric.** Incoming raw text -> `md-from-form` ->
  `unmarkdown`; stored `i!text` (already `md-from-form`'d at creation) ->
  `unmarkdown`. Both sides become the same round-tripped plaintext, so
  formatting-equivalent submissions match.
- **`aif` multi-clause binds `it` per clause** (arc.arc:704 recurses via
  `(aif ,@(cdr args))`), so `it` in the dup branch is the found item, not
  the result of an earlier test. Verified before approving the `if`->`aif`
  switch.
- **json `kids` ordering reuses `ranked-kids`** (news.arc:2296,
  `(ranked-siblings:kids i)`), the established display-order helper
  (callers at ~2316/2549/2672). Any nil-item-in-`kids` edge case is
  pre-existing and shared with those callers; no new risk.

## Important context for future sessions

- **Working tree**: `main`, ahead of `origin/main` (this session's four
  commits unpushed). **Uncommitted/unstaged: `news.arc`** was
  intentionally kept out of every commit - do not sweep it in. The
  remaining working-tree edit is local site config only:
  `this-site*` "My Forum" -> "HN Simulator" and `site-desc*` ->
  "HN simulator." near `news.arc:9-20`.
- **Submit flow** (`news.arc` ~1838-1915): `submit-page` always renders
  title/url/text. A url+text submission splits into story + top-level
  comment. The split-off comment does **not** go through
  `comment-ban-test` / `bad-user` kill checks (only the story gets
  `story-ban-test` + ignored-kill); flagged in review as a minor
  inconsistency but left as-is.
- **Comment dedup** (`process-comment`, `find-duplicate-comment`,
  `normalize-text` near `news.arc:2498`): only direct children of the
  parent are scanned, so this catches accidental re-submits, not edits or
  cross-thread duplicates.
- Helpers confirmed present this session: `me` arg form (app.arc:41),
  `aif` multi-clause (arc.arc:704), `catch`/`throw` (arc.arc:1601,
  `catch` = `(point throw ...)`), `unmarkdown` (app.arc:694),
  `only&...` ssyntax (calls fn only when arg is non-nil; widely used).
