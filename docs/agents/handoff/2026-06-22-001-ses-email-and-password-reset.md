---
name: ses-email-and-password-reset
description: Added email.arc (an SMTP/SES mailer) and wired News's email-based password-reset flow on top of it, plus README docs and inbound forwarding setup.
type: project
---

# Handoff: SES email + password reset (2026-06-22)

Added a from-scratch SMTP client (`email.arc`) that sends through
Amazon SES, then built News's forgot-password flow on top of it.
Landed as a single commit `df1c379` on `main`.

## What was built

### email.arc (new, loaded via libs.arc)

A generic SMTP-AUTH mailer; nothing SES-specific beyond the default
host, so it works against any SMTP-AUTH server.

- **`send-email` (to subject body . opts)** -- the public entry point.
  `to` may be a single address string or a list. Opts (plist):
  `from`, `from-name`, `reply-to`, `headers` (alist of extra header
  pairs). Each opt overrides the `ses.json` default. Returns `t` or
  errors.
- **`base64-encode`** -- standard RFC 4648 base64 (the codebase had
  only bcrypt's nonstandard-alphabet base64). Built with arithmetic
  since there are no bit ops at the arc level. Verified against the
  canonical `f`/`fo`/`foo`/... test vectors.
- **`ses-config`** -- merges env overrides over `ses.json` over
  defaults. Keys: host, port (default 465), tls, user, pass, from,
  from-name, reply-to. Env names: `SES_SMTP_HOST/PORT/USER/PASS/TLS`,
  `SES_FROM`, `SES_FROM_NAME`, `SES_REPLY_TO`. Env wins so secrets can
  stay out of the file.
- **Transport**: uses the existing `socket-connect` (see the
  http-client handoff) for implicit TLS. **Gotcha:** `socket-connect`
  only auto-enables SSL for port 443, so for SES on **465** we pass
  `(obj ssl t)` explicitly. `tls` resolves to on for 465/443, off
  otherwise; `SES_SMTP_TLS=0` forces plaintext (used for local
  testing against a fake plaintext server on a non-TLS port).
- **SMTP conversation**: greeting -> EHLO -> AUTH LOGIN (base64
  user/pass) -> MAIL FROM -> RCPT TO (per recipient) -> DATA ->
  body + CRLF "." CRLF -> QUIT. Multiline replies handled (reads until
  the 4th char of a line is a space, not `-`).
- **Message building**: `email-message` emits From/To/Reply-To/
  Subject/Date/MIME headers + extra headers + body. `email-date` is a
  hand-rolled RFC 822 UTC date (weekday computed from the epoch day
  count, since `timedate` doesn't return day-of-week). `smtp-lines`
  normalizes line endings to CRLF and dot-stuffs leading-dot lines.
- **Display name / envelope split**: `email-addr` extracts the bare
  address from a `"Name <a@b>"` string. The full From (with display
  name) goes in the `From:` header; the bare address is used for the
  SMTP envelope (`MAIL FROM`) and EHLO. So a `from` of
  `"HN Simulator <hn@ycombinator.lol>"` works, as does a bare address
  plus a separate `from-name`.

### News password-reset flow (news.arc)

- New: `forgot` op + `forgot-user`, `changepw-email`,
  `changepw-page`, `try-changepw`, `forgot-url`, and a `login-form`
  hook that adds a "Forgot your password?" link (prefilled with the
  typed username).
- `changepw-email` calls `send-email` with just `to/subject/body`;
  from/from-name/reply-to come from `ses.json`.
- Converted the existing in-session `resetpw` form from `uform` to
  `urform` (Post/Redirect/Get): `try-resetpw` now returns redirect
  URLs (`flink` on error, `"news"` on success) instead of rendering
  inline. Matches the redirector convention from the login-rework
  handoff (`2026-06-21-003`).
- `newspage`'s `whence` arg is now optional (`(o whence "news")`) so
  the reset handlers can redirect to it.

### app.arc

- `(hook 'login-form afterward)` -> `(hook 'login-form afterward acct pw)`
  so the new `login-form` hook receives the username to prefill the
  forgot link.

### Config / docs

- `ses.example.json` (new) documents the fields. `ses.json` is
  gitignored.
- README gets an `## Email` section (SES verify/credentials/production
  doc links, ses.json fields, ImprovMX inbound forwarding + gmail
  "Send as" via SES) and an `## Acknowledgements` section crediting
  dang for the "Sharc" name.
- `site-url*` -> `http://localhost:8080` (no trailing slash) and
  `site-email*` -> `hn@@ycombinator.lol`. Because `site-url*` lost its
  trailing slash, the RSS `comurl` now inserts a `/` between it and
  `item-url` (which has no leading slash; `flink` does, so the
  reset-email link stays well-formed).

## AWS / DNS setup done this session (external, not in the repo)

Domain is **ycombinator.lol**, region **us-east-1**.

- SES domain identity `ycombinator.lol` verified (Easy DKIM, 3 CNAMEs,
  published to Route 53).
- Custom MAIL FROM `mail.ycombinator.lol` (MX + SPF) for SPF
  alignment. Note: MAIL FROM is the envelope/Return-Path, NOT the
  visible From.
- SES SMTP credentials created (username is an `AKIA...`-style string;
  password is SES-derived, not the raw IAM secret).
- Inbound `hn@ycombinator.lol`: free **ImprovMX** forwarding (root MX
  -> ImprovMX, SPF TXT) to shawnpresser@gmail.com. SES is send-only;
  it does not receive.
- Gmail "Send mail as" `hn@ycombinator.lol` routed through SES SMTP
  (email-smtp.us-east-1.amazonaws.com:587, TLS) so replies sent from
  gmail are DKIM-aligned.
- **Production access requested but NOT yet granted.** AWS replied to
  the support case asking for use-case detail (a reply was drafted).
  Until granted, SES is sandboxed: can only send TO verified
  identities (any address @a verified domain counts, so `hn@` and
  shawnpresser@gmail.com both work). General sending unlocks on
  approval.

## Key decisions / things to know

- **Display name shows the site, not "hn".** Set via `ses.json`
  `from` (`"HN Simulator <hn@ycombinator.lol>"`) or `from-name`. Real
  HN sends `From: Hacker News <...>`.
- **Threading was intentionally skipped.** Gmail did NOT collapse the
  SES password-reset emails despite identical Subject + consistent
  From (tested directly). Reliable collapsing needs a `References`
  header (a stable per-user token like `<pwreset-USER@domain>`); HN's
  rootless header has none only because it's the thread root. Decided
  it's overkill for password resets. `send-email`'s `headers` opt is
  in place if this is ever wanted.
- **`@` in arc string literals** still needs doubling under atstrings
  (e.g. typing an address at the REPL: `dest@@example.com`). This only
  affects hand-typed literals, never runtime values from forms/config.
  README is markdown, so its `@`s are fine as-is.
- **site-url* is localhost.** This is baked into reset-email links and
  RSS URLs. Fine for local dev; a real deployment must override it or
  reset emails will link to localhost.

## Testing

- base64 verified against RFC 4648 vectors.
- Full SMTP conversation exercised end-to-end against a local fake
  plaintext SMTP server (Python, port 2525, `SES_SMTP_TLS=0`):
  EHLO/AUTH/MAIL/RCPT/DATA/dot-termination/QUIT, display-name From vs
  bare envelope, Reply-To, and extra headers all confirmed.
- Real sends to the verified shawnpresser@gmail.com via SES succeeded
  (display name "HN Simulator" and Reply-To confirmed in Gmail).
- `news.arc` loads cleanly; all reset/forgot functions bind.
- The standard `./test.arc` suite does not exercise srv/app/news, so
  none of this is covered there; smoke-test by running a server and
  hitting `/forgot`.

## Possible follow-ups

- Retry/queue + bounce/complaint handling for scale (SES throttles
  rather than failing hard; quota auto-raises). Not needed for launch.
- Per-user `References` header if email threading is ever wanted.
- `static/dmca.html` is untracked and was deliberately left out of
  these commits.
