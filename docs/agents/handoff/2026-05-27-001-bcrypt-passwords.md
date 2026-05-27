---
name: bcrypt-passwords
description: Replaced SHA-1 password hashing with pure CL bcrypt implementation, matching HN's $2b$10$ format. Password length now 8-72 chars.
type: project
---

# Handoff: bcrypt password hashing (2026-05-27)

Replaced the unsalted SHA-1 password hashing with bcrypt, matching
HN's format as described by kogir in 2014
(https://news.ycombinator.com/item?id=8604586).

## Files changed

- **bcrypt.lisp** (new): Pure CL bcrypt implementation. No external
  deps, works on any SBCL platform including Windows. Produces
  `$2b$10$...` hashes compatible with OpenBSD/Python/Ruby bcrypt.
- **boot.lisp**: Loads bcrypt.lisp.
- **app.arc**: `set-pw` uses `bhash` (bcrypt cost 10). `good-login`
  uses `bcheckpw`. Password validation changed from min 4 to 8-72
  characters.
- **news.arc**: `try-resetpw` validation updated to 8-72 characters.

## bcrypt.lisp implementation

- Eksblowfish key schedule with configurable cost (default 10).
- Blowfish F function: `((S0[a] + S1[b]) XOR S2[c]) + S3[d]`.
- bcrypt-specific base64 alphabet: `./A-Za-z0-9`.
- Output is 23 bytes (not 24; last byte is dropped per the standard).
- Null-terminated key, capped at 72 bytes.
- Random salt from /dev/urandom, fallback to CL `random`.
- Constant-time comparison in `checkpw`.
- Cross-verified against Python's bcrypt library in both directions.

## Arc API

```arc
(bhash pw)           ; hash password, returns "$2b$10$..." string
(bcheckpw pw hash)   ; verify password against hash, returns t/nil
```

## Key decisions

- No legacy SHA-1 fallback: user explicitly said not to support it.
  Existing SHA-1 hashes in `arc/hpw` will need to be re-hashed (users
  must reset passwords).
- Pure CL, no FFI: libcrypto doesn't include bcrypt. A pure
  implementation avoids platform deps and works on Windows.
- Cost 10: matches HN's original setting from kogir's comment.
- Password length 8-72 matches HN's current validation message:
  "Passwords should be between 8 and 72 characters long."

## Verification

Tested against Python `bcrypt` library:
- Python-generated hashes verify correctly with our `checkpw`.
- Our generated hashes verify correctly with Python's `checkpw`.
- Known test vector from OpenBSD (`$2b$06$DCq7YPn5Rq63x1Lad4cll.`)
  produces matching output.
