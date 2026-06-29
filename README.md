# sharc

An Arc-to-Common-Lisp port of [Arc](http://arclanguage.org/) and the
News web app that powers [Hacker News](https://news.ycombinator.com).

<img width="751" height="540" alt="image" src="https://github.com/user-attachments/assets/85828774-02bc-4c0b-9915-082b4c66b413" />

In September 2024, Hacker News migrated from Arc-on-Racket to Arc on
[SBCL](http://www.sbcl.org/) using a compiler called *Clarc* that dang
had been developing for years. The port lets HN run on multiple cores
and was fast enough to retire pagination on long threads. See the
[announcement thread](https://news.ycombinator.com/item?id=44099006)
and Vincent Massol's
[write-up](https://lisp-journey.gitlab.io/blog/hacker-news-now-runs-on-top-of-common-lisp/).

This repository is an independent open-source Arc-on-Common-Lisp
runtime in the same spirit. It boots `arc0.lisp` (a port of Arc's
`ac.scm`) under SBCL and then loads `arc.arc` and the rest of Arc on
top of it, so News and other Arc programs run unmodified.

## Requirements

You'll need [SBCL](http://www.sbcl.org/) installed (`brew install sbcl`
on macOS, `apt install sbcl` on Debian/Ubuntu).

## Running the tests

```sh
./test.arc
```

`test.arc` is adapted from [lumen](https://github.com/sctb/lumen)'s
test suite plus extra cases added during the port. A clean run prints
something like `193 passed, 0 failed`.

## Running News

```sh
mkdir -p arc
echo "myname" > arc/admins
export ARC_RELOAD=t # reload code changes without needing to restart
./sharc news.arc # prepend with `rlwrap` for repl history
```

Then go to [http://localhost:8080](http://localhost:8080).

Click on login and create an account called `myname`. You should now
be logged in as an admin.

Set `ARC_RELOAD=t` (or run `(set autoreload*)` in the repl) to
automatically reload code changes without restarting the server.

For production deployments, instead of autoreload, you can manually
`git pull` and then run `(reload)` in the repl to ship an update.
(You could use autoreload in production, but then each request is
slightly slower since it has to check the modification times of every
arc file.)

## Email

News sends password reset emails via [Resend](https://resend.com)'s
SMTP relay. Ask Claude how to set it up for your own domain, or follow
Resend's guides: [verify a sending
domain](https://resend.com/docs/dashboard/domains/introduction),
[create an API key](https://resend.com/docs/dashboard/api-keys/introduction),
and [send with SMTP](https://resend.com/docs/send-with-smtp).

Then copy `smtp.example.json` to `smtp.json` and fill in your
`YOUR_RESEND_API_KEY` (the username is the literal string `resend`).
The optional `from-name` and `reply-to` fields set the sender's display
name and a reply address.

Optionally, use [ImprovMX](https://improvmx.com/) to forward incoming
emails to a personal gmail account, then go to gmail's gear icon (upper
right) -> See All Settings -> Accounts and Import -> Send mail as ->
"Add another email address." Point that address's SMTP server at Resend
(`smtp.resend.com`, port 587, username `resend`, your API key as the
password) so replies you send from gmail are signed for your domain.

## Customizing News

Change the variables at the top of `news.arc`.

## Importing HN's front page

There's a built-in scraper that fetches the current Hacker News front
page (and its comment trees, including flagged / dead / collapsed
comments the official API doesn't expose) and imports it into your
local News.  See [`scrape.md`](scrape.md) for the full how-to.

You'll need a Hacker News account to log in to HN with -- the scraper
needs a session to see flagged/dead content.  An ordinary user account
is fine, but **create a fresh one for this purpose** rather than using
your real account, and turn `showdead` on in its preferences (so the
HTML the scraper fetches includes dead comments).  Put the username
into `scrape.json` (copied from `scrape.example.json` on first run);
the password is read at login time from `HN_SCRAPER_PASSWORD`, the
`password` field of `scrape.json`, or an interactive prompt.

## Performance tuning

```arc
(= static-max-age* 7200)    ; browsers can cache static files for 7200 sec

(= autoreload* t)           ; reload code changes without restarting

(declare 'explicit-flush t) ; you take responsibility for flushing output
                            ; (all existing news code already does)
```

## Layout

- `arc0.lisp` — Arc runtime for Common Lisp (port of `ac.scm`)
- `boot.lisp` — script entry point loaded via `sbcl --script`; loads
  `arc0.lisp`, then either runs each given Arc file and exits, or
  drops into the Arc REPL when no files are given (analogue of
  `arc3.2/as.scm`)
- `sharc` — thin shell wrapper: `exec sbcl --script boot.lisp "$@"`
- `arc.arc`, `libs.arc`, `strings.arc`, `code.arc`, `html.arc`,
  `pprint.arc`, `srv.arc`, `app.arc`, `prompt.arc` — Arc itself,
  built on top of `arc0`
- `news.arc`, `blog.arc` — the News and Blog applications
- `scrape.arc`, `json.arc` — HN front-page scraper and JSON support
  (see [`scrape.md`](scrape.md))
- `static/` — static assets served by `srv.arc`
- `test.arc` — Arc test suite

## Development history

The port was built incrementally; each step is recorded as a
[handoff](https://news.ycombinator.com/item?id=47581897) note in
[`docs/agents/handoff/`](docs/agents/handoff/), starting with
[`2026-04-25-001-arc0-port.md`](docs/agents/handoff/2026-04-25-001-arc0-port.md).
Read those in order if you want to see how arc0 was bootstrapped, what
broke along the way, and how each fix was reasoned through.

## License

Copyright (c) Paul Graham and Robert Morris. Released under the MIT
License with Paul Graham's permission. See [copyright](copyright).

## Acknowledgements

Thanks to [Daniel Gackle aka "dang"](https://github.com/gruseom) for
coming up with the name Sharc, and for answering dozens of
[emails](mailto:hn@ycombinator.com) over many months regarding HN and
Clarc.
