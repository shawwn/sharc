---
name: Ellipsizing long strings in the repl and backtraces
description: How `c286d48` cuts long strings to 500 characters for display only, why three different printers each needed a different hook (sb-debug's frame printer honours neither the pprint dispatch table nor `*debug-print-variable-alist*`), and why `write`, `disp` and `ero` are deliberately untouched.
type: project
---

# Handoff: string truncation for display (2026-08-21)

One commit, `c286d48`, `arc0.lisp` only. A scraped HN comment is routinely
several kb, so one of them as a repl value or a backtrace frame argument
buries everything else on screen; the backtrace that opened this session's
work is a page of one comment's text.

## What it does

Strings are cut to 500 characters when *displayed*, with the `...` **outside**
the closing quote:

```
arc> (= s (string:n-of 1200 #\a))
"aaaa…(500 chars)…aaaa"...          ; the line is exactly 510 characters:
                                   ; prompt + " + 500 + " + ...
arc> (list 'a s 'b)
(a "aaaa…"... b)                   ; nested strings too

7: (arc::OUTER "aaaa…(500)…"...)   ; a backtrace frame
Error: cccc…(500)…...              ; the condition's own report
```

Outside the quote is the point: `"abc"...` is a truncated string, `"abc..."`
is a string that really ends in dots. Both cases were tested.

## The safety property, which is the whole design

The limit lives in `*arc-print-string-length*`, and it is **nil everywhere
except around the repl's result print and error reporting**. `write` and
`disp` are what `save-table`, `serialize` and the json paths run on; if the
limit reached them, this change would quietly corrupt the store. Verified:
`(tostring:write s)` on a 1200-character string still returns 1202 characters
inside a program.

Two knobs, following the `*arc-repl-print-length*` / `*arc-err-print-length*`
pattern already in the file: `*arc-repl-print-string-length*` and
`*arc-err-print-string-length*`, both 500.

## Three printers, three hooks

This is the part worth carrying forward, because the obvious single hook does
not exist.

1. **Arc's own printer.** `arc-write-val` prints strings via
   `print-string-truncated`. Covers strings and, through `arc-print-list`,
   strings nested in lists, which is nearly every repl value.
2. **CL's printer**, reached by `write-remaining-level` for types arc does not
   print itself (vectors, structs). A `*print-pprint-dispatch*` entry for
   `string`. It only applies when `*print-pretty*` is true, hence
   `with-truncated-strings` also binds a 1000000 right margin; checked that a
   40 element list still prints on one line.
3. **sb-debug's frame printer.** Neither hook survives it. `print-frame-call`
   prints under its own io syntax, which discards `*print-pprint-dispatch*`
   **and** `sb-debug:*debug-print-variable-alist*`. Both were tried in
   isolation first, in plain `sbcl --script` probes: the dispatch table
   demonstrably works for `write` and inside a `pprint-logical-block`, and
   demonstrably does nothing for `print-frame-call`. So `arc-report-frame`
   post-processes the text it was already capturing (it captures it anyway for
   the `:invert` readtable-case trick).

   `truncate-printed-strings` scans that text honouring `\\` and `\"`, and
   only ever cuts at an escape boundary, so it cannot split an escape in half.
   Cases covered: short strings, exact-length boundaries, several strings on
   one line, `#<stream for "name">`, embedded quotes and backslashes,
   unterminated literals (closed as `"…"...`, which the printer never emits
   anyway), and a nil limit as a no-op.

The condition's own report is cut in `arc-report-error` by
`truncate-message`. That one is raw text rather than a printed literal, so
there is no closing quote for the `...` to sit outside of; it just goes on the
end.

## Deliberately not covered

`ero` (`arc.arc:1849`) still prints in full: `(ero:tablist h)` on a table with
a 1200-character value emits all 1222 characters. It is built on `write` and
the limit is not bound there. This matters in practice because `scrape-ero`
is built on `ero` and `(scrape-ero:tablist it)` in `story-from-scraped-story`
is what floods the log with entire comment bodies during an import.

Asked and declined this session, but if it is ever wanted the shape is to
expose the special as a binder rather than to touch `write`:

```lisp
(xdef call-w/print-string-length (n f)
  (let ((*arc-print-string-length* n))
    (arc-call0 f)))
```

```arc
(mac w/print-string-length (n . body)
  `(call-w/print-string-length ,n (fn () ,@body)))
```

then wrap `ero`'s body, or just `scrape-ero`'s, leaving plain `ero` verbatim.

## Testing

`./sharc test.arc` reports **927 passed, 0 failed**. The truncation itself has
no entries in `test.arc`; it was checked with ad-hoc scripts against
`truncate-printed-strings` directly and end to end through both paths. Adding
a few cases to the suite would be cheap and is not done.

Note when testing the repl: piping to `./sharc` loads stdin as a script, with
no prompt and no value echo, so it does not exercise the repl printer at all.
Send `(repl)` as the first form to get the `arc> ` loop.
