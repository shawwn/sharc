---
name: A script's repl outliving its load, and hot-reload for the lisp sources
description: Why ctrl-D at a script's prompt could die with "Unexpected )" (the repl runs inside `load`'s read-eval loop, which resumes reading the file at a stale offset), the `main-repl*` fix in `b250d7b`, and `a3d2201` teaching `maybe-reload` to notice arc0.lisp and arc1.lisp.
type: project
---

# Handoff: script repls and reload tracking (2026-08-21)

Two commits, continuing from
[2026-08-21-004](2026-08-21-004-reloadable-lisp-runtime.md): `b250d7b` fixes a
crash on ctrl-D, `a3d2201` finishes the hot-reload story by noticing edits to
the lisp half.

## 1. `Unexpected )` on ctrl-D (`b250d7b`)

Reported as: pressing ctrl-D to leave the prompt of `./sharc scrape.arc`
*sometimes* killed the process with

```
Unhandled SIMPLE-ERROR: Unexpected )
4: (ARC:ARC-READ-1 #<FD-STREAM for "file .../scrape.arc">)
5: (ARC:ARC-READ  #<FD-STREAM for "file .../scrape.arc"> NIL ARC::|eof2150|)
6: (ARC::|load--gf291| T)
```

**Read which stream that is.** The reader is not on stdin, it is on
`scrape.arc`, inside `load`. That is the whole diagnosis: a script ending in
`(repl)` runs the prompt *inside* `load`'s read-eval loop
(`(w/infile f file ... (whiler e (read f eof) eof (eval e)))`), so the file
stays open at a byte offset for as long as you sit at the prompt. Leaving the
repl returns into that loop, which reads on from the saved offset. If the file
changed on disk meanwhile, that offset now points into different bytes,
usually mid-form.

**Why "sometimes" is about the editor.** Truncate-and-rewrite-in-place reuses
the inode, so the open fd sees the new bytes and it breaks. Write-a-temp-file-
and-rename leaves the old inode intact, the load sees the original EOF, and it
exits cleanly. Both were reproduced; the difference is entirely the save mode.

**The error is the lucky outcome.** When the stale offset happens to land on a
form boundary, `load` just evaluates whatever is there now. In the first
reproduction a `def` and a `prn` that did not exist when the load started both
ran, silently.

The fix: a script asks for a prompt with `(main-repl)`, which only sets
`main-repl*`; `boot.lisp` starts the repl after `arc-load` has returned and the
file is closed. Applied to `news.arc`, `scrape.arc` and `blog.arc`.

`(repl)` written mid-file still opens a prompt on the spot and still has the
old hazard. That is deliberate: a breakpoint should stop where it is written.

### Reproducing it

Worth keeping, because the timing is fiddly:

```sh
printf '(prn "before")\n(repl)\n' > t.arc      # offset after (repl) is 22
( sleep 4 ) | ./sharc t.arc &                  # stdin closes after 4s = ctrl-D
sleep 2                                        # boot takes ~600ms; wait past it
python3 -c "import io; io.open('t.arc','w').write('(prn \"0123456789abcde\")\n(prn \"tail\")\n')"
```

The new content is chosen so byte 22 is a `)`. Rewriting too early (0.7s) just
makes the image load the *new* file from the start and proves nothing.

## 2. `maybe-reload` and the lisp sources (`a3d2201`)

`maybe-reload` walks `loaded-files*`, and `arc0.lisp` / `arc1.lisp` are not in
it: nothing loads them through `load`, so `notetime` never sees them, and
`file-changed` is nil for a file with no recorded time. Editing only the lisp
half reloaded nothing.

They are now tracked through the same `loaded-file-times*` table by
`note-runtime-times` / `runtime-changed`, and `maybe-reload` consults both.
They stay **out** of `loaded-files*` deliberately: `reload` walks that list
with `load`, and feeding it a `.lisp` file would be a disaster. The file list
comes from `runtime-files`, xdef'd in arc0.lisp from `*runtime-source-files*`,
so there is one list of runtime sources and it hands back full paths.

**The non-obvious bit:** `reload` notes the times *before* reloading, not
after. `reload-runtime` can refuse (a struct changed shape) or fail to
compile. If times were only recorded on success, a caller polling
`maybe-reload` from the accept thread would recompile both files on every tick
for as long as the file stayed broken. Noting first gives one attempt per
edit.

Verified by touching each file with the image running:

```
at boot:                  nil
after touching arc1.lisp: t
after note-runtime-times: nil        (does not loop)
loaded-files-changed at boot: nil
after touching arc.arc:      t       (.arc tracking unaffected)
```

## Current state

`main`, unpushed. `./sharc test.arc` reports **927 passed, 0 failed**.
`script.arc` is untracked and has been all session.

## Notes for a future agent

- **When only the lisp half changes, `maybe-reload` still does a full
  `reload`**: runtime plus every `.arc` file. That is existing `reload`
  behaviour and probably right, since compiled arc code depends on the
  compiler in arc1.lisp, but it means a one-character edit to arc0.lisp
  re-loads everything and prints a long `*** redefining ...` flood.
- **`reload` re-loads the main script too**, since it is in `loaded-files*`.
  A test script without a `(when (main) ...)` guard therefore runs twice, which
  looks like a bug in whatever you are testing until you remember why. The
  `(no reloading*)` clause in `main` exists for exactly this.
- Reloading under a live server is still untested, and nothing refuses to
  reload while srv threads are running (carried over from handoff 004).
