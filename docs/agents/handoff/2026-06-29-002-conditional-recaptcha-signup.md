---
name: conditional-recaptcha-signup
description: Added conditional reCAPTCHA v2 on account creation (only after an IP makes 2+ accounts/day), plus the legacy-vs-Enterprise key gotcha that broke siteverify, and a couple of small unrelated fixes.
type: project
---

# Handoff: conditional reCAPTCHA on signup (2026-06-29)

Implemented HN-style conditional reCAPTCHA v2 on account creation, then
debugged why verification always failed (the key, not the code).  Plus
two small unrelated commits that were sitting in the working tree.

Commits on `main` this session (newest first):

- `5b9300f` arc: rename aif's rest param from body to args (cosmetic)
- `f328b8c` news: show [deleted] before [flagged] in pseudo-text
- `4c6b419` login: fold captcha check into bad-newacct, thread ip thread-locally
- `e807818` login: only show the captcha after a signup attempt, not on first load
- `9ec51e5` login: show "Validation required." whenever the captcha appears
- `d52cdf7` login: require reCAPTCHA after repeated signups from an IP
- `f630063` login: keep the register form focused after a failed signup

(`f630063` and the two non-login commits are independent of reCAPTCHA;
see the bottom section.)

## The reCAPTCHA feature

### recaptcha.arc (new, loaded via libs.arc after json.arc)

Self-contained because `scrape.arc` (which has the curl helpers) is NOT
loaded by the news server.

- **Config**: `recaptcha-config` merges env (`RECAPTCHA_SITE_KEY`,
  `RECAPTCHA_SECRET`, `RECAPTCHA_THRESHOLD`) over `recaptcha.json`
  (gitignored; `recaptcha.example.json` is committed).  `recaptcha-keys`
  returns the config only when both keys are present, so the whole
  feature **no-ops when unconfigured** (dev/tests need no setup).  The
  config file is re-read on every call, so **editing `recaptcha.json`
  takes effect without a server restart**.
- **Per-IP tracking**: in-memory `acct-creations*` table, ip -> list of
  unix-second creation times.  `note-acct-creation` records + prunes to
  the last `recaptcha-day*` (86400s).  `recaptcha-required` is true once
  `recent-acct-creations >= threshold` (default 2).  **In-memory, so it
  resets on restart** (accepted: at worst one extra captcha-free window
  per IP after a bounce).
- **Widget**: `recaptcha-widget` emits the api.js `<script>` + the
  `g-recaptcha` div via raw `pr` (whitepage has no `<head>`; in-body is
  fine).  The widget injects a hidden `g-recaptcha-response` field, which
  rides along with the fnid form post.
- **Verification**: `recaptcha-siteverify` shells `curl` to
  `https://www.google.com/recaptcha/api/siteverify` (GET query params;
  `urlencode` makes values shell-safe so single-quoting the URL is
  injection-proof).  `recaptcha-pass` parses the JSON (`from-json`
  yields symbol-keyed tables, `true`->`t`) and **fails closed**: missing
  token, network error, or `success:false` all => nil.  Tokens are
  single-use.
- `ip` is taken as a `(t ip)` thread-local param throughout, so call
  sites just call `(recaptcha-required)`, `(recaptcha-pass token)`, etc.

### app.arc wiring

- **`bad-newacct`** does the captcha check as its **first clause**:
  `(and (recaptcha-required) (~recaptcha-pass (arg "g-recaptcha-response")))`
  -> returns the string `"Validation required."` like any other
  validation error.  This is the single enforcement point: account
  creation only happens when `bad-newacct` returns nil.
- **`create-handler`** is a plain `(aif (bad-newacct ...) (failed-login
  'register it afterward (recaptcha-required)) (do (create-acct ...)
  (note-acct-creation) (login ...)))`.  The `validate` flag passed to
  failed-login is `(recaptcha-required)`.
- **`login-form`** gained an optional `extra` thunk rendered inside the
  fnform after the pw fields; **`login-page`** gained a trailing
  `(o validate)` and renders the widget via `(and validate
  recaptcha-widget)`.  **`failed-login`** threads `validate` (inserted
  as the 4th param, before acct/pw) into login-page.

### Behavior (matches HN, verified against the real site)

- Initial login/create form (a GET): **no captcha, no "Validation
  required."**, even for an over-threshold IP.  This was the key
  correction (`e807818`): an earlier version wrongly showed the captcha
  on first render.  HN only shows the validation page as the *response*
  to a create-account POST.
- A create-account POST from an over-threshold IP that hasn't passed a
  captcha bounces back to a page that prints "Validation required."
  (via `pagemessage`, from bad-newacct's return) and shows the widget.
- Threshold default 2 means the 3rd signup from an IP triggers it.

## The key gotcha (cost most of the debugging time)

Verification **always failed** with a real solved token.  Root cause was
NOT the code: Google's legacy siteverify returned

    "error-codes": ["Migrate your key to continue using reCAPTCHA: ..."]

instead of the normal `invalid-input-response`, for **any** token.  The
first set of keys the user supplied (`6Lf6-2oU...`) were registered on
Google's new reCAPTCHA platform (Cloud / Enterprise), and the legacy
`www.google.com/recaptcha/api/siteverify` endpoint refuses to validate
tokens for such keys (POST and GET both fail identically; the widget
even shows a "reCAPTCHA is changing its terms of service" nudge).

**Resolution**: user chose to get a **legacy** key (no code change) over
switching to the Enterprise `createAssessment` API.  New keys
(`6LeXDD0t...`) were created via the classic admin
(`https://www.google.com/recaptcha/admin/create`, v2 "I'm not a robot"
Checkbox) and dropped into `recaptcha.json`.

**Litmus test for any reCAPTCHA secret** (the fast way to tell a working
legacy key from a migrated one), no browser needed:

    curl -sS -X POST https://www.google.com/recaptcha/api/siteverify \
      --data-urlencode "secret=THE_SECRET" --data-urlencode "response=test"

- Good (legacy works): `"error-codes": ["invalid-input-response"]`
- Broken (migrated):   `"error-codes": ["Migrate your key ..."]`

The new secret passes the litmus test and the full code path was
re-verified.  **Still unverified end-to-end: a genuine solved-checkbox
token** (needs a browser).  The blocker is gone, so it should pass; the
user was going to confirm with a real signup.  If the **success** path
still fails, check that the new site key's allowed domains include
`localhost` / `127.0.0.1` for local testing (and `ycombinator.lol` for
prod) -- it's a different key from the first, with its own domain list.

## Config / files

- `recaptcha.json` (gitignored) currently holds the working legacy keys
  + `"threshold": 2`.  `recaptcha.example.json` (committed) documents
  the shape.  `.gitignore` ignores `/recaptcha.json`.
- To force the captcha on for testing without making accounts:
  `RECAPTCHA_THRESHOLD=0 ./sharc` (every create-account POST then
  bounces to the validation page; the initial form stays clean).

## How to run / test

- Server: `./sharc`, then `(load "news.arc")`, `(nsv)` ->
  http://localhost:8080.  The top "login" link shows the create form.
- Logic-only (no browser): load `strings.arc`/`json.arc`/`recaptcha.arc`,
  wrap calls in `(w/the ip "1.2.3.4" ...)` since ip is a thread-local;
  `note-acct-creation` x2 then `(recaptcha-required)` => `t`.
- No automated test covers any of this (`./test.arc` doesn't exercise
  srv/app/news).

## Unrelated small commits (were loose in the working tree)

These kept showing up as "staged changes" between reCAPTCHA steps and
were each reviewed and committed on their own:

- `f630063` **login: keep the register form focused after a failed
  signup** -- create-handler re-renders with `'register` instead of the
  page's original `switch` (usually `'both`), so a failed signup shows
  only the Create Account form.
- `f328b8c` **news: [deleted] before [flagged] in pseudo-text** -- match
  `cansee`'s precedence (it tests `i!deleted` first), so a
  deleted-and-flagged item reads `[deleted]`.
- `5b9300f` **arc: rename aif's rest param body -> args** -- purely
  cosmetic; aif's tail is a cond-style then/elseif/else chain, not a
  body.  Behavior verified identical across clause counts.

## Branch status

All commits are on `main`.  Working tree clean.  (This session is the
one that pushes; prior sessions left `origin/main` behind.)
