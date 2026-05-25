---
name: setmem-and-topcolor-threshold
description: Added setmem macro to arc.arc for conditional list membership (pushnew/pull), rewrote togglemem in terms of it, and dropped topcolor-threshold* to 0.
type: project
---

# Handoff: setmem macro and topcolor threshold (2026-05-25)

Two small commits on top of the previous session's handoff doc commit
(`bf7dd50`).

## Commits

| sha | what |
|---|---|
| `dc7a8dc` | Drop `topcolor-threshold*` to 0 |
| `cb8fb93` | arc.arc: add `setmem` macro; rewrite `togglemem` in terms of it |

## setmem macro (arc.arc)

`(setmem test x place)` conditionally sets membership of `x` in
`place`: if `test` is true, `(pushnew x place)`; if false,
`(pull x place)`. Uses `setforms` for generalized place support.

`togglemem` was rewritten as a one-liner delegating to `setmem`:

```arc
(mac togglemem (x place . args)
  (w/uniq gx
    `(let ,gx ,x
       (setmem (~mem ,gx ,place) ,gx ,place ,@args))))
```

### Naming discussion

The user considered `setmem`, `putmem`, and other alternatives.
`setmem` was chosen for its pairing with the existing `togglemem`
(`set`/`toggle` are both state-operation verbs).

## topcolor-threshold* (news.arc)

Dropped from 250 to 0 so the custom top-bar color option appears in
user profiles regardless of karma.
