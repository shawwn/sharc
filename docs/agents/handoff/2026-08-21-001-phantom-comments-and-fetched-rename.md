---
name: Phantom story-as-comment corruption and the fetched rename
description: Item 49365443 hung the srv thread because the scraper had imported the story's own row over the top of it as a self-parented, self-kidded comment; covers how the corruption worked, the 483 records it reached, the repair and the guards in `4f99150`, and the `seen`/`fetched_at` to `fetched` migration in `580a4d3`.
type: project
---

# Handoff: phantom comments and the `fetched` rename (2026-08-21)

Continues from [2026-08-20-001-posmatch-multisubst-speedups](2026-08-20-001-posmatch-multisubst-speedups.md),
which fixed `parse-comments` parsing the story row as a comment. This session
dealt with the wreckage that bug had already written to disk, and then with a
timestamp rename that touched every scraped record.

Two commits: `4f99150` (`scrape.arc`) and `580a4d3` (`scrape.arc`, `news.arc`).
Plus three data migrations, which are the part that cannot be recovered from
the code.

## 1. Why item 49365443 would not render

Loading it drew the comment header and then hung until the 60s srv watchdog
fired. The stored record was the story with a comment written over it:

```
(type comment) (parent 49365443) (kids (49365443)) (deleted t) (by 121543)
(title "Unsloth Dynamic 3.0 GGUFs") (url "https://unsloth.ai/...") (score 316)
```

The mechanism, worth understanding because it is not obvious from either file
alone: `import-scraped-item!` imports the story first, then the comments. The
phantom row carried the **story's own id**, so
`comment-from-scraped-comment`'s `(or= (items* c!id) ...)` resolved to the
same table the story importer had just written. It flipped `type` to comment,
set `parent` to the id itself, set `deleted` (no author, hence `by` = the
"deleted" uid 121543), and then `import-scraped-comment` appended the id to
its own parent's kids, making the item its own child too.

News then walks those links with no cycle guard, in three places:
`cansee-descendant` (`news.arc:698`), `superparent` (`news.arc:2724`) and
`ancestors` (`news.arc:3268`), plus the `display-subcomments` /
`display-comment-tree` pair through `ranked-kids`. Which one spins first
depends on `cansee`, which for a deleted item is `(admin user)`; `arc/admins`
holds only `test`, so a normal user falls into the kid-walking pair, matching
the observed "header renders, nothing after".

**483 of 8606 scraped records carried such a row; 482 stored items were
corrupted.** They were also pushed onto the "deleted" user's `submitted` list
(482 of its 512 entries).

## 2. Why rescraping could never have fixed it

Two independent reasons, both worth remembering:

- `merge-comments` (`scrape.arc:507`) keeps a comment that has vanished from
  the page, marking it `deleted`. So the fixed parser stopped producing the
  row, but every stored json kept it and every re-import replayed it.
- `story-from-scraped-story` sets ten fields and wipes `kids`, but never
  touched `parent`, and it reuses whatever entry is already in `items*`. An id
  previously imported as a comment therefore kept its stale parent through any
  number of re-imports.

`4f99150` fixes both: `importable-comments` drops a comment claiming the
story's id or parenting itself (and logs it, since a silent skip is how this
went unnoticed across 483 items), `import-scraped-comment` refuses to link an
item as its own kid, and `story-from-scraped-story` wipes `parent`. That last
one is what makes a re-import repair such an item rather than merely not
worsen it.

## 3. The `fetched` rename (`580a4d3`)

Scraped records carried two timestamps for one event: `seen`, stamped in
`parse-subtext-row!` at parse time, and `fetched_at`, stamped in
`build-item-json` at write time. Measured across the 5096 records holding
both: identical in 4169, 1 to 9 seconds apart in the rest. Same event, so the
merge is lossless and `fetched_at` wins (it is what the new code writes).

The design points that came out of review, since the reasoning is not visible
in the diff:

- The stamp moved to record creation in `parse-fatitem` / `parse-listitem`.
  `parse-subtext-row!` sits inside an `aif` on the subtext row, so a page
  without one (dead or deleted item, or any markup change) produced a record
  with **no timestamp at all**; verified with a fatitem containing no subtext.
  That is why `build-item-json`'s unconditional write could then be deleted.
- Comments deliberately do **not** carry `fetched`. The fetch unit is the
  story page. The known cost: `merge-comments` keeps a vanished comment as
  `deleted`, and without a per-comment stamp there is no way to say at which
  fetch it disappeared.
- The field is `fetched`, not `imported`, because `(imported i)` already means
  "has the imported key" (`news.arc:486`) and `frontpage-rank` and
  `item-or-hn-url` depend on that. An earlier revision used `imported` for
  both and had a profile writing `p!imported` against a template declaring
  `fetched`.
- An earlier revision also had `it!imported (or s!fetched (seconds))`
  overwriting on every rescrape while every neighbouring field fell back to
  its existing value. Renaming the field to `fetched` makes the overwrite
  correct instead of needing to be sticky.

## 4. What was changed on disk (not recoverable from git)

All under `arc/`, all verified against a full APFS clone backup taken first.

**a. Phantom rows stripped from 483 stored json records.** One entry per file,
the one whose id equalled the story's. Verified byte-identical apart from that
entry, and that arc's json writer is reproduced exactly by
`json.dumps(sort_keys=True, separators=(',',':'), ensure_ascii=False)` (all
8612 files round-trip identically, which is what made a safe rewrite possible).

**b. 482 corrupted items rebuilt.** Not by re-importing everything, which
would have rewritten ~50k comment files and churned profiles, but by loading
each item (so votes, flags, ip survive), letting `story-from-scraped-story`
restore the story fields, and relinking top-level comments as kids from the
scraped record. All 482 verified: `type=story`, no `parent`, no self-kid, not
deleted, kids exactly the json's top-level comments (8250 links), and
`votes`/`flags`/`title`/`url`/`sockvotes` byte-unchanged. Four items also got
their score back (1 to 97, 46, 7, 5), having inherited a deleted comment's
score. The "deleted" profile went from 512 submitted entries to 30.

**c. `seen`/`fetched_at` merged into `fetched`** across `arc/scrape/`:

| store | files | notes |
|---|---|---|
| `item/*.json` | 8612 | 8602 rewritten; `fetched_at` wins over `seen` |
| `user/*.json` | 41655 | 41650 rewritten, 4 are literally `null`, 1 already migrated |
| `lists/*` | 14 | 47906 records renamed, 225361 items compared field by field afterwards |

The three stores needed three different mechanisms, which is the part to copy
if this comes up again: item jsons are arc-written so a json round-trip is
byte-safe; **user jsons are verbatim firebase responses** with
`,"fetched_at":<n>}` appended by `inject-fetched`, so they got a
suffix-anchored text replace only (checked first that all 41650 contain
exactly one occurrence, always at end of file); the list files are arc
`%table` serialize format and went through `load-hn-list` / `save-hn-list`.

**d. Every imported story stamped with its json's `fetched`.** 8513 items;
before the pass none had the field. Left alone: 97 scraped ids never imported,
and 2 ids (49023536, 49027014) that are comments, not stories.

## Current state

`main`, 11 commits ahead of `origin/main`, unpushed. `./sharc test.arc` reports
**927 passed, 0 failed**.

Backups, in this session's scratchpad, gone when it is cleaned:
`scrape-backup/` (full clone of `arc/scrape`, 50349 files),
`phantom-json-backup.tgz`, `news-repair-backup.tgz`.

## Open

- **The three cycle walkers are still unguarded.** Patches were written and
  verified against synthetic self-loops, a two-cycle, a dangling parent and a
  healthy tree (`seen` tables in `cansee-descendant`, `superparent`,
  `ancestors`; `kids` dropping a self-reference, which covers `ranked-kids`,
  `display-subcomments` and `comment-navs` at once), and were then reverted
  twice in the working tree, so they are deliberately not in. The import guard
  makes a new bad record unlikely, not impossible, and one is still a 60s srv
  stall. Patch saved at `news-mine.patch` in the scratchpad.
- **`parse-comments`'s `(cdr (parse-split html))` is positional.** On a comment
  permalink page HN renders the comment itself as the fatitem, so `cdr` eats a
  real comment; demonstrated with a synthetic page (2 parsed instead of 3).
  Not reachable today because every scraped id comes from `scrape-topstories!`
  or `parse-listpage`, but ids 49023536 and 49027014 show comment ids do reach
  the item scraper. The verified alternative, identical on all 354 comments of
  the test fixture and the same speed, is to pass the anchor `parse-split`
  already accepts: `(parse-split html "<tr class=\"athing comtr")`.
- **48953406** has 5 comments in its json and none in the store, most likely
  authors without profiles at import time (`import-scraped-comment` reports and
  skips those per comment). Nobody has swept for that class.
- `arc/scrape/lists-old/` (33MB) still uses `seen`; nothing reads it.
- 97 scraped ids are not imported; the 2 comment-permalink jsons are junk
  records (`story` with `by=nil title=nil`) that the importer correctly refuses.

## Notes for a future agent

- **A bounded scan beats a full one.** `arc/news/story` holds 343632 files and
  1.3GB; walking it was rejected outright, and rightly. Every question here was
  answered instead by iterating the 8606 scraped ids and looking up
  `arc/news/story/<id div 5000>/<id>`. `item-bucket-size*` is 5000
  (`news.arc:428`) and must stay constant.
- **`(load "news.arc")` alone leaves profiles unresolvable.** `profile` reads
  lazily but needs the uid tables, so a repair script wants `(load-userinfo)`
  (`app.arc:30`); it does not need `load-news`, which would pull in every item.
  Without it, `get-user-uid` throws "No such profile" on the first record.
- **Not every scraped author has a profile.** The user import is a separate
  pass, so a repair must skip a story whose author is missing rather than die.
- Arc gotchas that cost time here: `(each (o n) ...)` binds nothing, because
  `o` is the optional marker in a destructuring list; `out` is bound by
  `w/break` (`arc.arc:254`) and so is unavailable inside a nested `afn` unless
  you supply it (`accum` is the fix); `#'sb-ext:with-timeout` does not work
  because it is a macro, so bound-time probes need an external alarm or a
  separate process.
- **Always restore the mode after `mkstemp`.** It creates 0600 and the store is
  uniformly 0644; this was caught once and nearly shipped.
- When claiming a dry run, verify the disabling edit actually matched. One
  `sed` here silently failed to match its target block and the profile write
  went through during what was announced as a dry run.
