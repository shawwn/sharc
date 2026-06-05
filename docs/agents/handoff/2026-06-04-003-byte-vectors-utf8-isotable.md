---
name: byte-vectors-utf8-isotable
description: Added byte-vector support (ar-apply/type/coerce), utf-8 conversion primitives, a utf-8 fix for urlencode/urldecode, an isotable (deep-structural-keyed hash table via arc-is2 + psxhash), scope reflection, and thread-local req defaults; widened fnids to 22 chars.
type: project
---

# Handoff: byte vectors, utf-8, isotable (2026-06-04)

Six commits on top of the previous handoff
(`52c67be docs: add handoff for named backtraces and srv cleanups`).

## Commits

| sha | what |
|---|---|
| `fa7d044` | arc: add `scope`, a reflective view of the lexical environment |
| `feec05f` | srv.arc: widen fnids from 10 to 22 chars to match HN |
| `126af16` | arc: byte-vector support and utf-8 urlencode/urldecode |
| `37782b9` | srv.arc: default reassemble-args' req to the thread-local |
| `0bcacb1` | srv.arc: urlencode keys and values in reassemble-args |
| `06187ef` | arc0.lisp: add isotable, a deep-structural-keyed table |

## Byte vectors (`126af16`)

The runtime now treats `(unsigned-byte 8)` vectors as a usable Arc type:

- `ar-apply` indexes any vector: `(v i)` => `(aref v i)`.
- `arc-type` returns `vector` for them.
- `arc-coerce` converts both ways: `(coerce bytevec 'cons)` => list of ints
  in [0..255]; `(coerce list-of-ints 'vector)` => an `(unsigned-byte 8)`
  vector; `(coerce nil 'vector)` => empty byte vector.
- `arc-is2` already compares vectors elementwise (so `is`/`iso` work on
  byte vectors), and the byte vector round-trips: `(coerce (coerce bv
  'cons) 'vector)` is `is` bv.

Note `coerce` deliberately does NOT do string<->bytes (no place to pass
an external-format); use the utf-8 primitives for that.

## utf-8 primitives (`126af16`)

In arc0.lisp:

- `(utf8-encode s)` / `(utf8-decode b)` -- string <-> utf-8 byte vector.
- `(string->bytes s [ef])` / `(bytes->string b [ef])` -- same but with an
  optional external-format (default `:utf-8`; e.g. `(string->bytes "é"
  :latin-1)` => `#(233)`).  Pass the format as a CL keyword (`:latin-1`),
  not an arc quote, or sb-ext errors with "Undefined external-format".

These wrap `sb-ext:string-to-octets` / `sb-ext:octets-to-string`.

## urlencode/urldecode utf-8 fix (`126af16`)

The old versions worked per-character, so they mangled multibyte text:
`(urldecode "x%ce%bbx")` gave `"xÎ»x"` and `urlencode` emitted the bogus
`"%3bb"` for λ.  Now they operate on utf-8 *bytes*: encode the string to
its bytes, %-escape non-unreserved bytes; decode by gathering bytes into
a vector and `utf8-decode`-ing.  So `λ <-> %ce%bb`.

`reassemble-args` (`0bcacb1`) now url-encodes both key and value -- it is
the inverse of parseargs (which decodes), so reassembling raw values
without re-encoding would corrupt the query string (a value containing
`&`/`=` would split into bogus params).

## isotable (`06187ef`)

`(isotable)` is like `(table)` but built with a custom SBCL hash-table
test so keys are compared by *deep structure* instead of `equal`:

```lisp
(make-hash-table :test #'arc-is2 :hash-function #'sb-impl::psxhash ...)
```

So distinct-but-equal tables, vectors, and conses are the *same* key,
whereas a regular `equal` table compares those by identity.

Why this design (investigated at length):

- A regular Arc `(table)` uses `:test #'equal`, and **`equal` does not
  look inside hash-tables, arrays, or structs** -- for those it degrades
  to `eq` (identity).  So a table used as an `equal` key only matches the
  exact same object.  This is the gotcha that started the thread.
- Switching the global default to `equalp` was rejected: `equalp` is
  case-insensitive for strings/chars (would collapse case-distinct
  usernames, cookies, fnids) and ~3x slower on string keys.
- The hash-function correctness rule: equal keys must hash the same; the
  converse isn't required.  `sb-impl::psxhash` (equalp's hasher) recurses
  into tables/vectors/conses, so it agrees with `arc-is2`.  Its
  case-insensitivity for strings only adds harmless bucket collisions --
  `arc-is2` is still the test, so `"Foo"` and `"foo"` stay distinct keys.
  Plain `sxhash` would NOT work: it hashes tables/vectors by identity, so
  equal-content keys would land in different buckets and lookups miss.

Caveats: a custom-test table is slower than `equal`, so use `isotable`
only where content keys are needed (it is NOT the default); and mutating
a key after insertion changes its hash and orphans the entry.

`isotable` is currently **unused** -- a `fnkeys*` experiment (deduping
fnids by args-table content) was the motivation but was removed.  It's
available for that when wanted.

## Other

- `scope` (`fa7d044`, arc.arc + arc1.lisp): referencing the bare symbol
  `scope` (or `scope%`) compiles to `(%scope env)`, returning
  `(name getter setter)` triples for every distinct in-scope lexical, for
  debugging.  `ac-set1` was also reordered to allow assigning a
  lexically-bound `t`/`nil` (lex-p checked before the rebind guards).
- `reassemble-args`/`get-user` (`37782b9` and earlier) take a `(t req)`
  thread-local fallback param defaulting to `(the req)`, so callers can
  omit the arg.
- fnids widened 10 -> 22 chars (`feec05f`) to match HN.

## Status

`./sharc test.arc` => **405 passed, 0 failed**.  Tests added: `byte-
vectors`, `utf8`, `urlencode`, `table`, `isotable`.  `news.arc` loads
clean.  Branch `main`, working tree clean, 6 commits ahead of
`origin/main` (not pushed before this doc).
