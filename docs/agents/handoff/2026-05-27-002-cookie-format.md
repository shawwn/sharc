---
name: cookie-format
description: Changed cookie format to match HN (user&token value, SameSite=Lax, Secure, HttpOnly flags).
type: project
---

# Handoff: cookie format matching HN (2026-05-27)

Updated the session cookie format and attributes to match HN's
current behavior.

## Changes (app.arc)

### Cookie value format

Old: bare random token (e.g. `9LE6jqtX`)
New: `username&randstring32` (e.g. `alice&Zb03ZzbLoKVk62WT2CjvTOEwagto05M8`)

The full `user&token` string is the key in `cookie->user*`. This
means an attacker who predicts the PRNG state still can't forge a
valid cookie without knowing the username.

### Cookie attributes

Added `Path=/; SameSite=Lax; Secure; HttpOnly` to the Set-Cookie
header, matching HN.

### Token generation

`new-user-cookie` uses `(rand-string 32)` (from /dev/urandom) for
the token part, matching HN's 32-character tokens.

### Login behavior

`login-handler` only logs out the current user if logging in as a
different user. Re-logging in as the same user reuses the existing
cookie (matching HN behavior).

`good-login` reuses an existing cookie if one exists
(`(unless (user->cookie* user) (cook-user user))`), matching HN.

### Migration

Old `arc/cooks` files with symbol keys from the previous format
will not work. Delete `arc/cooks` (and `arc/hpw` since those are
SHA-1 hashes from before the bcrypt change) to start fresh.
