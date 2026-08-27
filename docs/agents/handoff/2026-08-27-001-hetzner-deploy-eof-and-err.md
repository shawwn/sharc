---
name: the hetzner deploy, the eof sentinel, and err
description: 19 commits after the varforms handoff. News is live at news.ycombinator.lol on a hetzner box (see docs/deploy.md); getting there meant fixing three expired certs whose renewal was blocked by the very app being deployed, and installing a newer SBCL. In the code: reading now signals end of input with an `eof` sentinel rather than nil, `err` stopped being CL's `error` (it was silently dropping arguments and eating `~`), duplicate test names are an error, and `id`/`ident`/`same` collapsed into one primitive called `ex`.
type: project
---

# Handoff: hetzner deploy, the eof sentinel, and err (2026-08-27)

Covers `b006114..d8d13dd`, i.e. everything after
`2026-08-26-001-varforms-redact-and-layout.md`. Two unrelated halves: a
deployment, and a run of fixes in the reader and the error machinery.

The test suite went from 968 to 1032 assertions over this batch. It runs
in about 1.6 seconds, so there is no reason not to run it after every
edit.

## 1. News is live at news.ycombinator.lol

Full detail is in `docs/deploy.md`, which is the file to read first and
the one the systemd units point at. The short version:

* Code and data live in `/opt/sharc`, owned by `deploy`, on the SSD.
* `sharc.service` starts a detached tmux session named `sharc` and runs
  `DEV=1 PORT=8080 lwrap ./sharc scrape.arc` inside it. `ssh
  deploy@hetzner` then `tmux a` lands you in the repl.
  **`tmux -a` is not a thing** -- tmux has no `-a` option.
* nginx reverse-proxies `news.ycombinator.lol` to `127.0.0.1:8080`.
* Hourly restic backups to `/mnt/sdb/private/restic`, passwordless by
  request. rsnapshot's `/opt/sharc` cron is commented out, with the
  original preserved at `/root/rsnapshot.cron.bak`.

Two things worth knowing that are easy to rediscover the hard way:

**Ubuntu's SBCL is too old.** 24.04 ships 2.2.9, and `arc0.lisp`
references `sb-unix:clock-gettime`, which was not external then, so the
boot dies with a read error. Upstream 2.6.3 is installed in
`/usr/local`, leaving the distro package alone. The requirement is
undocumented in the README; a version check in `boot.lisp` would save
the next person the trouble.

**restic needs an explicit cache dir.** systemd starts services with
`HOME` unset, and restic then exits 1 with "unable to locate cache
directory". `RESTIC_CACHE_DIR` is pinned in `/etc/restic/env`; do not
remove it.

### The certificate deadlock

All three certs (`shawwn.net`, `the.shawwn.net`, `ycombinator.lol`) had
expired on 2026-08-23, taking two unrelated live sites down with them.
The cause is worth recording because it is circular:

1. certbot writes the challenge under `/var/www/html/.well-known/`
2. Let's Encrypt fetches it over http
3. the `:80` server block did a blanket `return 301` to https
4. the `:443` block proxies everything to `127.0.0.1:8080`
5. nothing was listening there, so the challenge got a **502**

Cert renewal depended on the app being up. Fixed by
`/etc/nginx/snippets/acme-challenge.conf`, included in every `:80` block
*before* the redirect, with the redirect moved into `location /`. Also
added `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh`, because
the authenticator is `webroot` and nothing was reloading nginx after a
renewal -- so even a successful renewal would have kept serving the old
cert.

### The server is running stale code

`/opt/sharc/arc0.lisp` predates the `ex` rename. Picking that up needs
`(reload)` in the repl, **not** a restart: `DEV=1` autoreloads `.arc`
files, and `(reload)` calls `(reload-runtime)`, which recompiles the lisp
half into the live image (see
`2026-08-21-004-reloadable-lisp-runtime.md`). Only a struct shape change
forces a restart, and reload-runtime refuses loudly in that case rather
than corrupting anything. The server has been
scraping independently since 2026-08-26, so **its `arc/` is its own live
datastore**.

Update the server with a pull, not a copy: `/opt/sharc` is a git checkout
tracking `origin`, and rsyncing onto it dirties tracked files so the next
pull refuses. Run git as `deploy`, since root hits `detected dubious
ownership`. `.gitignore` carries `/arc/`, so a pull cannot touch the
datastore.

```sh
sudo -u deploy git -C /opt/sharc pull
```

## 2. Reading signals eof with a sentinel, not nil

`read` and friends now let the caller pass a distinct `eof` value, so a
literal nil in a stream stays distinguishable from running out of input.
`read-table` hands that value straight back at end of input, which is
what lets `load-tables` drain on it, and `load-table` defaults it to
`(table)` so `load-pws` and `load-cookies` get an empty table rather
than nil when the file holds nothing.

This matters because **`save-table` writes an empty table as `(tablist
h)` = nil**, so nil is a legitimate payload rather than a marker. Two
intermediate versions of `read-table` got this wrong in instructive
ways:

* returning an empty table at eof made `load-tables` loop forever,
  observed as heap exhaustion at 10.7 GB
* using `whenlet` conflated a nil payload with eof, silently truncating
  `load-tables` (3 tables in the file, 1 returned) and turning
  `load-table` into nil for callers that expect a table

`drain` accumulates with `out` instead of `push`/`rev!`. `whiler`
compares against endval with `ex` rather than `is`, because eof is
itself a function and plain `(testify eof)` hands back eof to be
*called* as the predicate. `readall` takes an optional count.

## 3. err is no longer CL's error

`(xdef err #'error)` meant Arc's `err` was CL's `error`, which reads its
first string as a **format control**. Two consequences, both live bugs:

* extra arguments were silently dropped, so `(copy (fn () 1))` reported
  `Can't copy ` with no mention of what
* a literal `~` was read as a directive. Since `~` is complement in Arc
  and `assert` echoes the failing expression, `(assert (~acct-exists
  new))` produced an unhandled `FORMAT-ERROR` rather than an assertion
  message -- and it escaped `on-err`, because the format runs lazily
  while the condition is being printed, inside the handler.

`err` now writes the message, then `": "`, then the value arguments
separated by spaces. The message is displayed and the values are
written, so a string value keeps its quotes and nil and t show up
instead of vanishing. **Call sites therefore no longer punctuate or
interpolate their own messages**; the `@`-interpolating and
`string`-concatenating ones were converted. The string builder is split
out as `arc-error-string`, exported as `errstr`, for callers that want
the text without signalling.

Values print under the limits already used for backtrace frames
(`*arc-err-print-string-length*`, `-length`, `-level`), so one oversized
argument cannot bury the message. Those three defvars had to move above
`err`: they were defined below it and were undefined at that point.
Note `*arc-err-print-string-length*` is now 120 and is **shared with
`arc-report-frame`**, so backtrace frames truncate at 120 too.

## 4. id, ident and same collapsed into ex

Three names for one function, and `id` is also one of the most common
parameter names here (item ids, user ids, fnids), so the global was
constantly shadowed. All three are gone; the primitive is `ex`, short
for `exactly`, and the underlying `arc-same` is `arc-exactly`.

**The parameters named `same`** in `testify`, `some`, `all`, `mem`,
`find`, `rem`, `keep`, `reinsert-sorted` and `insortnew` deliberately
keep their name. They hold the equality predicate rather than referring
to the global, and calling them `ex` would reintroduce the exact
shadowing this rename exists to avoid.

Also left alone: `id` as an html attribute in `html.arc` (the
`(id align valign) opsym` line reads like a call but is a `case` clause),
and the many parameters and destructuring binds named `id`.

The rename initially missed two `#'arc-same` references in `&key`
defaults at `arc0.lisp:460,466`, which do not match a search for
`(arc-same ` call syntax. That broke the boot outright with
`The function ARC::ARC-SAME is undefined` from `arc-car?`, which runs on
every macro expansion. If you rename a Lisp-level function here, grep
for `#'name` as well as `(name `.

## 5. Smaller things

**A NaN error on Linux x86-64.** x86-64 Linux enables the `:invalid` FP
trap by default and macOS/ARM does not, so `(= nan nan)` signalled there
instead of returning nil, killing `test-literals`. `arc-exactly` masks
the trap for the float case only, leaving integer comparison on the fast
path. `anan` is `(no (is x x))`, so it depends on this returning nil.
The commented-out `set-floating-point-modes` at `arc0.lisp:207` was the
author's earlier attempt; it "doesn't seem to work" because FP modes are
per-thread.

**Duplicate test names are now an error.** `tests*` is keyed by symbol
and symbol case is folded, so two tests sharing a name silently
clobbered each other and one vanished from the count. `define-test`
asserts before defining the test function, so a duplicate does not
clobber the existing one on its way to erroring.

## Known loose ends

* `arc.arc:1422` still has `(err "Can't make a fresh @(type x)")`, the
  last `@` interpolation in an err message. It works; it is just the odd
  one out now.
* `load-tables-file` in the test suite is an end-to-end check whose
  failure mode for a sentinel mismatch is a hang and heap exhaustion,
  not a clean assertion failure. `read-table-eof` is the fast legible
  one; read that first if both go red.
* The README documents no minimum SBCL version, and the failure when it
  is too old is an opaque reader error during boot.
