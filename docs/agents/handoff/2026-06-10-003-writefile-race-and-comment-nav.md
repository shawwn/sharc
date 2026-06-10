---
name: writefile rename race and comment nav
description: Fixes an occasional "couldn't rename topstories.tmp (ENOENT)" by giving writefile a unique temp name per write (concurrent writers shared one file.tmp and raced on the rename). Also threads the comment "on:" marker through the tree and finishes the parent-link styling (clicky same-page anchors).
type: project
---

# Handoff: writefile rename race + comment nav (2026-06-10)

> Continues [`2026-06-10-002-static-css-cache-busting-and-comments`](2026-06-10-002-static-css-cache-busting-and-comments.md).

## Commits

| sha | what |
|---|---|
| `dfe4993` | news.arc: thread the "on:" marker through the comment tree; refine parent links |
| `fe6c9db` | arc.arc: give writefile a unique temp name to fix a rename race |

## writefile rename race (`fe6c9db`)

**Symptom:** occasional, at runtime:
`Error: couldn't rename arc/news/topstories.tmp to arc/news/topstories:
No such file or directory`, from a bg thread's `WRITEFILE -> MVFILE`.

**Cause:** `writefile` wrote to a *fixed* `"<file>.tmp"` then renamed it
into place. `topstories` is rewritten by `save-topstories`, which runs on
**every vote** (via `adjust-rank`, on per-request threads) plus the
background re-rank, so it has many concurrent writers. They all shared the
single `topstories.tmp`: writer A renames it to `topstories` (tmp now
gone), writer B's rename then hits ENOENT. Same latent bug for any hot
file (e.g. two votes on the same story both `save-item` -> same `<id>.tmp`).

**Fix:**

```arc
(def writefile (val file)
  (let tmpfile (+ file "." (rand-string 16) ".tmp")
    (after (do (w/outfile o tmpfile (write val o))
               (mvfile tmpfile file))
      (when (file-exists tmpfile)
        (rmfile tmpfile))))
  val)
```

- **Unique tmp per write** (`rand-string`) so writers never share a tmp.
  Chose `rand-string` over a counter: a bare-symbol `(++ counter*)` is
  **not** atomic (arc.arc:622 `++` is only atomic for non-symbol/table
  places, via atwiths), so a global counter would still race; `rand-string`
  needs no shared state and the collision odds are negligible.
- **`.tmp` stays the trailing extension** (`file.<rand>.tmp`, not
  `file.tmp.<rand>`) so orphans are still caught by the startup
  `rm .../*.tmp` sweep.
- **`after` cleanup** removes the tmp if the write/rename throws. Needed
  because unique names no longer self-clean by overwrite, and the server's
  watchdog actively `break-thread`s slow request threads. The `after`
  (unwind-protect) **does** fire on `break-thread` (interrupt-thread
  raising an error -> normal unwind) and `kill-thread` (terminate-thread
  also unwinds). It does **not** fire on a hard process kill (SIGKILL) --
  that's the case the startup `*.tmp` sweep backstops.

## Comment "on:" marker + parent links (`dfe4993`)

- `display-comment-tree`/`display-1comment` gained a `showon`/`initialon`
  param so the "on: <story>" marker can be enabled per render; the threads
  list passes it (`display-comment-tree c whence 0 t t`).
- Parent link: top-level (indent 0) and focused comments link to the
  parent's own page (`item?id=<parent>`); nested comments get a clicky
  same-page anchor (`whence#<parent>`).
- Extracted a `clickylink` helper (`<a class="clicky" aria-hidden="true">`,
  mirroring link/underlink) for the anchored nav links. `aria-hidden` is
  registered via a new `opbool` html attribute handler (committed earlier
  in `eaf0530`).

## Status

`./sharc test.arc` => **415 passed, 0 failed**. 9 commits ahead of
`origin/main`, unpushed. `static/news-hn.css` / `news-hn.js` remain
intentionally untracked (HN's current css/js as reference for the still-
deferred vote/collapse JS).
