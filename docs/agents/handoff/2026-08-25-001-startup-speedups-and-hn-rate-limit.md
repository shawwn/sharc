---
name: startup speedups, and getting rate-limited by HN
description: Cut (load-news) from 28s to 12s -- probe-file to unix-stat in file-exists, a duplicate stat out of read-item, a cached key set in templatize, DIRECTORY to readdir in arc-dir, and parallel reads in load-items. Also: the scraper got 403'd by HN and dang asked for a 10x slowdown (crawl delay 0.55 -> 10.0s), notify.arc landed as the alerting channel for next time, and a latent arc-car? bug surfaced as "Undefined function: TEST" during reload-runtime.
type: project
---

# Handoff: startup speedups and the HN rate limit (2026-08-25)

Covers everything after `2026-08-24-001-openssl-wedge.md`, plus the
load-path work that landed just before it and never got written up.

Measured throughout against a `cp -al` hardlink shadow of `arc/` in the
scratchpad. `writefile` is atomic-rename, so a hardlinked shadow is safe
to write to and the live server is never touched.

## 1. Startup: 27,961ms -> 12,318ms

`(load-news)` on 368,785 items across 130 buckets. Five changes, in the
order they were found:

| | before | after | |
|---|---|---|---|
| `file-exists` | 10.83us | 0.83us | 13x |
| `templatize` | 13.5us | 8.8us | |
| `arc-dir`, per 3000-file dir | 85.6ms | ~4ms | 21x on the readdir alone |
| `read-item` | two stats + an open | one stat + an open | |
| `load-items`, 15k items | 972ms | 347ms | 2.8x on 8 threads |

- **`file-exists`** was `probe-file`, which resolves the truename --
  following symlinks, consing a pathname -- for a result we discard,
  since `arc-file-exists` returns NAME itself. `sb-unix:unix-stat` gives
  the same answers (stat follows symlinks too, so a broken link is nil
  either way; directories succeed for both).
- **`read-item`** called `file-exists` after `safe-id`, which had already
  stat'd through `ok-id` -> `find-id`. One trip removed per item.
- **`templatize`** did `(assoc k fields)` -- a linear scan of all 20
  template fields for every field read back -- once per item on disk. Now
  a cached key set, keyed on the template's *name* (a symbol hashes well;
  the fields list is a cons full of closures, and see `2026-08-23-002` for
  what happens when you hash one of those). The list is kept beside the
  key set and compared by identity, so `deftem`/`addtem` install a fresh
  list and miss rather than reading a stale entry. Verified that `addtem`
  picks up a field that was dropped before it.
- **`arc-dir`** used `DIRECTORY`, which conses a pathname per entry and
  calls `truename` on each. `:resolve-symlinks nil` got 85.6ms -> 38.9ms;
  readdir got it to ~4ms. Two semantics had to be restored by hand:
  `DIRECTORY` answers nil for a missing path where `opendir` signals, and
  the files-then-subdirs-with-trailing-slash ordering is what `dirs` and
  `files` use to tell them apart. The dir test uses `sb-unix:unix-stat`,
  not `sb-posix:stat` -- the latter conses a stat instance and needs
  `ignore-errors` around it, which alone cost 11.2s vs 9.4s over the whole
  bucket walk.
- **`load-items`** reads in parallel. Registration deliberately stays on
  the calling thread: `register-item` pushes to `(the loaded-items)`,
  which is thread-local, so a worker doing it would strand everything it
  read -- exactly the bug from `2026-08-23-002`.

What is left is irreducible per-file work: open ~8.8us, parse ~17us. Only
more threads move it, and 8 is already past the knee on 8 performance
cores. `load-item-buckets` still costs 6-9s and must finish before
`load-items` can know any ids; removing the remaining per-entry stat would
mean reading `d_type` out of the dirent, which sb-posix does not expose.

### An off-by-one that was already there

The old `latest-items` loaded one item *past* its limit: `each-item` calls
`(item id)` and only then does the body test `n` and `break`. So a 15,000
limit produced 15,001 registered items (306 stories + 14,695 comments).
The parallel version loads exactly n. If you are diffing old against new
loader state, that one item is expected.

## 2. `arc-car?` called an undefined function

`reload-runtime` printed `Undefined function: TEST`. Pre-existing, and a
real bug rather than noise -- `arc0.lisp:451`:

```lisp
-           (test (car l) k)
+           (funcall test (car l) k)
```

`test` is a keyword parameter holding a function; that line called it as a
global function name. It never fired because the branch needs `k` supplied
*and* not a function, and every call site in `ac` passes either nothing or
`#'ssyntax-p`. Now exercised directly in both `arc-car?` and `arc-caar?`.

Related: **`reload-runtime` muffles warnings during `compile-file` but not
notes**, so compiler notes print on every reload where warnings do not.
The readdir `arc-dir` emits a SAP-to-pointer note (`sb-posix:dirent-name`
takes an alien `dirent*` and sbcl cannot fold the coercion); muffled
locally rather than restructured, since cost 20 per entry is ~7ms across
the whole item store.

## 3. HN rate-limited the scraper

The scraper started getting `HTTP 403 from https://news.ycombinator.com/news`
in a loop from `scrape-frontlog`. dang asked for a slowdown, and
`scrape-crawl-delay*` went **0.55 -> 5.0 -> 10.0 seconds** (`be3b671`,
`5edf245`). Treat 10s as a floor to negotiate up from, not a default to
tune down.

Worth knowing for next time: nothing stopped scraping when the 403s
started. `call-reporting` caught each one, printed a backtrace, and the
bgthread went straight back to fetching -- so the process kept hammering
an endpoint that was already refusing it.

## 4. notify.arc

`47db655`. Out-of-band alerting so the next one of these does not need
somebody watching the terminal. `notify.json` (gitignored;
`notify.example.json` is committed) with two independent channels:

- **`sms`** -- an iMessage handle, best written E.164. Goes out via
  `osascript` to Messages.app. **iMessage, not carrier SMS**: if the
  number is not on iMessage this silently does nothing, since green-bubble
  fallback needs Text Message Forwarding from an iPhone on the same Apple
  ID *and* the AppleScript asking for `service "SMS"` specifically. The
  first send raises a macOS Automation permission prompt; if that is
  dismissed it fails silently forever after, so send one by hand while
  watching before relying on it.
- **`email`** -- through `email.arc` and the existing `smtp.json`.

Blank channel = silent no-op, so `notify!` is safe to call from anywhere
including a fresh checkout. `notify-async!` runs it off the calling thread,
which matters because the places worth alerting from tend to be holding a
lock.

## 5. Not done: the ban detector

Designed but not built. Recording it so it does not get re-derived:

- **One choke point.** Every HN request goes through `fetch-hn-url`,
  already serialized under `scrape-lock*`. One hook there catches all of
  it.
- **Catch the warning, not the ban.** HN soft-limits first, with a 503
  whose body says it is *"not able to serve your requests this quickly"*.
  `arc-http-fetch` signals on any non-2xx and throws the body away, so
  `fetch-hn-url` never sees it -- only the 403 that follows. Going through
  `http-response` (`arc0.lisp:1710`) keeps status and body both, and that
  503 is the signal that lets you slow down *before* being banned.
- **A free differential.** The scraper already talks to two hosts:
  `news.ycombinator.com` for HTML and `hacker-news.firebaseio.com` for the
  API. Firebase answering while HN refuses means blocked; both failing
  means the network. That is the same ambiguity that made the
  `getaddrinfo` backtrace in `2026-08-24-001` hard to read.
- **Halt, do not just alert.** `scrape-hn*` is checked by both `defscrape`
  and `scrape-hn-stories`, so wiping it stops the crawl without killing
  threads. Latch the alert so it fires once per transition, then probe
  every few minutes and restore `scrape-hn*` on a 200.
