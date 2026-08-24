---
name: the OpenSSL wedge, found and fixed
description: The recurring "image wedges forever" bug was an SSL_CTX built per connection. SSL_CTX_new reaches ossl_method_construct, which holds the method store's write lock across construct-and-insert; a thread leaving that region by a non-local exit orphaned the lock and every later HTTPS connection blocked on it forever. Fixed in a20fa35 by building one context per verification mode at load time and never freeing it. Written up now because the commit message was the only record, and its absence sent a later session chasing the wrong lock.
type: project
---

# Handoff: the OpenSSL wedge (fixed in a20fa35, 2026-08-19)

This is a write-up of a fix that already landed. It exists because the
commit message was the only record of it, and `docs/agents/handoff/` is
what a fresh agent actually reads -- with nothing here, a later session
looking at a scraper backtrace re-derived a plausible-but-wrong theory
about `w/lock` and had to be corrected. See the dead ends at the bottom.

## What it looked like

The image stops doing anything that needs the network and never recovers.
From the wedged image in the commit message: **six scrape threads parked
on one pthread rwlock (`0x60000258c750`) for nine hours**, EBIT set with
no live owner, while the bgthreads that never touch SSL kept cycling
normally. That last detail is the tell -- it is not a general hang, only
everything downstream of an HTTPS connection.

## The mechanism

An `SSL_CTX` was being created per connection, in the connect path:

```
SSL_CTX_new -> ssl_load_ciphers -> evp_generic_fetch -> ossl_method_construct
```

`ossl_method_construct` takes the method store's **write lock and holds it
across the whole construct-and-insert region**. A thread that leaves that
region by a non-local exit orphans the lock. Nothing ever releases it, so
every later HTTPS connection in the process blocks on it forever.

It left no trace, which is why it went unexplained for so long: the arc
callers of this path wrap themselves in `errsafe`, which discards the
condition without printing it. The event that wedged the image was
invisible.

## The fix

Build **one context per verification mode, at load time, and never free
it**. Holding it for the process lifetime keeps the providers activated
and the method store warm, so the construct path runs exactly once -- at
load, single-threaded, before any bgthread exists. `SSL_new` on a shared
context is thread safe and does not re-enter the construct path.

Three supporting pieces landed with it:

- **`call-watching-unwind`** (`arc0.lisp:1086`, used at `:1356`) reports any
  condition that unwinds out of the SSL region, so the invisible event
  becomes visible. A refused handshake is signalled *outside* the watch,
  so the only thing it reports is a condition we did not raise ourselves.
- **`without-interrupts` around the short, non-blocking SSL setup calls** --
  deliberately **not** around `ssl-connect`, which blocks on the network.
  Deferring interrupts there would make the thread unkillable, which is a
  worse failure than the one being fixed.
- **`bgmonitor`** (`srv.arc:879`) notices several bgthreads stalled mid-pass
  at once and captures the state. It counts threads rather than timing one,
  so a legitimately slow pass does not trip it. Default `bgstall-action*`
  is `'hold` (`srv.arc:858`): while the trigger was still unknown, a wedged
  image was the only artifact worth having. Set it to `'abort` to get
  `abort-image` (`arc0.lisp:2161`), which is `sb-ext:exit :abort t` --
  a plain exit unwinds and runs exit hooks, so it would block on the very
  threads that are stuck.

## Telling the artifacts apart

The repo has three wedge-ish artifacts and they are **not the same incident**:

- **This one** -- six threads on a pthread rwlock, no live owner, only
  SSL-touching threads affected.
- **`deadlock.txt`** -- a `rank-lock*` convoy: `scrape-stories-p1` holds it
  while `scrape-stories-p2-p3` and `scrape-remaining-stories` wait. Related
  repro in `c8ec174`. A plausible contributor is that
  `import-scraped-comments` does an O(n) `merge-item-lists` under
  `rank-lock*` -- 91ms at 127k comments, the same lock every page render
  takes through `add-item` (see `2026-08-23-002`).
- **`wedge-78080.txt`** -- lldb output with the main thread in `__select`.

## Dead ends (do not re-derive these)

A scraper backtrace showing `getaddrinfo` failing inside a locked table
looks like it implicates arc's locks. It does not:

- **`w/lock` bodies are interruptible.** Arc locks *are* hash tables
  (`make-lock` builds one) and `w/lock` goes through
  `call-w/locked-table` -> `sb-ext:with-locked-hash-table`, so a backtrace
  shows a `WITHOUT-INTERRUPTS-BODY-` frame. That is only SBCL's outer
  wrapper in `call-with-recursive-lock`; the body runs under
  `with-local-interrupts`. Measured: a thread sitting inside `w/lock` was
  killed by `stop-thread` in ~1s, its body never completed, and the lock
  was cleanly reacquirable afterwards.
- **`fetch-hn-url` holding `scrape-lock*` across the whole fetch is
  deliberate.** That lock plus `scrape-delay!` is what enforces
  `scrape-crawl-delay*` against HN. Scrape throughput is one request at a
  time by design; several bgthreads queued behind it is expected, not a
  wedge.
- A `getaddrinfo` EAI_NONAME on `news.ycombinator.com` is a transient
  resolver failure (network change, VPN, mDNSResponder, wake-from-sleep).
  `call-reporting` catches it, the bgthread continues, and the item is
  retried next pass.

  It is tempting to read such a backtrace as the wedge trigger, since it
  is an error unwinding out of an HTTPS connect in a scrape thread. It is
  not, and this was checked rather than assumed: **no revision of
  `tcp-connect` has ever touched OpenSSL** -- it is `get-host-by-name`,
  `make-instance inet-socket`, `socket-connect`, `set-socket-timeout`, in
  every commit including `a20fa35^`. In the pre-fix `arc-socket-connect`
  the SSL region came strictly after it (`tcp-connect` at body line 15,
  `(ssl-ctx-new (tls-client-method))` at line 22, inside `(if ssl-p ...)`,
  unreachable until a socket exists). A name-resolution failure unwinds
  before the method store lock is ever taken.

## Still open: what unwound out of SSL_CTX_new

The mechanism is established; the trigger is not. The fix's own shape is
the best clue -- it added `without-interrupts` around the short SSL setup
calls and deliberately not around `ssl-connect` -- which points at an
**interrupt** rather than a signalled condition: a thread terminated while
inside `SSL_CTX_new`, e.g. `srv.arc`'s watchdog calling `stop-thread` on a
request thread past `threadlife*`. An error would orphan the lock just as
well, but the interrupt path is the one the fix hardened. A saved lldb
dump from a real wedge would settle it by showing which thread was where.
