# http-fetch timeouts, response headers, and a cookie jar reader

Date: 2026-07-25

Started as "what would it take for `http-fetch` to behave like curl with
cookies in scrape.arc", and turned into fixing the reasons it couldn't.
Three pieces: a Netscape cookie jar reader in Arc, unbounded reads in the
HTTP client, and exposing the response status/headers.

## cookies.arc (new, in libs.arc)

The read half of curl's jar, so `http-fetch` can be handed a `Cookie`
header. No lisp changes were needed for this part -- `http-fetch` already
took a `headers` alist.

    (whenlet c (cookie-header (read-cookie-jar jar) url)
      (http-fetch url (obj headers (list (list "Cookie" c)))))

- `url-parts` -> `(scheme host path)`. Port dropped (cookies ignore it),
  query kept on the path. **Not** named `parse-url`: `parseurl` already
  exists in srv.arc for request lines, and arc0.lisp has its own
  `parse-url`; a third meaning one hyphen away invites miscalls.
- `read-cookie-jar` -> list of cookie tables; missing file gives nil,
  matching `curl -b` rather than erroring.
- `cookies-for` filters on domain / path / secure-vs-scheme / expiry,
  longest path first (RFC 6265).
- `cookie-header` joins them.

Three things that will bite anyone editing this:

- **`slices`, not `tokens`.** `tokens` collapses runs of separators, so a
  cookie with an empty value loses a column and every field after it
  shifts. The fixture in test.arc has such a cookie for this reason.
- **`#HttpOnly_` is a cookie, not a comment.**
- **Values go out verbatim.** HN's `user` cookie is `username&token`;
  urlencoding the `&` breaks the session.

The write half (capturing `Set-Cookie`, merging, re-serializing) is not
done. `http-response` below is the piece it was blocked on.

## arc0.lisp: reads could hang forever

Measured before the change: a peer that accepts and stays quiet blocked
the thread indefinitely, and so did a peer that sent a **complete**
response and simply didn't close, because `http-slurp-octets` always read
to EOF and only applied Content-Length afterwards. There was no timeout
anywhere in the path; TCP keepalive is off by default.

Two mechanisms, because neither covers both stream types:

- `SO_RCVTIMEO` via a direct `setsockopt` alien routine (sb-bsd-sockets
  does not expose it in SBCL 2.6.3). This is what bounds the SSL path,
  where `ssl-read` calls `read(2)` itself.
- `sb-sys:wait-until-fd-usable` before every read. **This is what bounds
  the plain-socket path**: SBCL's fd-stream treats the `EAGAIN` from
  `SO_RCVTIMEO` as "would block" and waits on the fd anyway, so the
  socket option alone does nothing there. Verified directly.

Also:

- The plain path now reads via `sb-unix:unix-read` on the fd rather than
  the stream. `read-sequence` blocks until its buffer fills, which would
  defeat the early exit; we never read through the stream, so nothing is
  buffered behind us. A nil return is an error, not EOF.
- `http-slurp-octets` stops at Content-Length or the terminal chunk
  instead of waiting for a close.
- A fired timeout is distinguished from EOF via `SSL_get_error` ==
  `SSL_ERROR_SYSCALL`, in both `http-slurp-octets` and the gray stream's
  `stream-read-char`. Without that, adding the timeout would have
  converted a hang into a **silently truncated body**, which is worse.

`*http-timeout*` defaults to 60s, applied by `http-fetch`. Deliberately
**not** applied by `socket-connect`: email.arc uses it for SMTP, and a
socket-level timeout changes how those streams behave. Pass `timeout`
explicitly there if you want it. `maxtime` bounds a whole request.

Connect is still the OS's blocking `connect(2)` (~75s darwin, ~2min
linux). Bounding it needs non-blocking connect + `wait-until-fd-usable`
+ `SO_ERROR`, which wasn't worth the risk for a case that already
terminates.

## arc0.lisp: response status and headers

`arc-http-fetch` parsed the headers and threw them away, so `Set-Cookie`
was unreachable and any 3xx was an error -- which is exactly what HN's
login POST returns. Split into `arc-http-request` returning `(values
status headers body)`, with `http-fetch` (unchanged contract) and a new
`http-response` on top. Headers stay an **alist with duplicates**: a
response can carry several `Set-Cookie` lines.

## Fixed in passing

`https` on a non-443 port **with** `noverify` connected in plaintext.
`sock-opts` was built as either/or, so passing `noverify` dropped the
`ssl` key, and `arc-socket-connect` then inferred SSL from the port
alone. Now one table carries every key. Verified against a local
`openssl s_server` on 8443.

## Verification

`./sharc test.arc` -> 769 passed, 0 failed. `scrape-verify-flags.arc`
passes all four. A 962472-char chunked HN item page matches `curl`
exactly, char count and tail, so the early exit doesn't truncate.

The interesting HTTP cases need a listener and are not in test.arc (which
stays offline and fast). To re-run them, two throwaway python servers:
one that accepts and never writes (expect a timeout error), one that
sends a complete response with Content-Length and never closes (expect an
immediate body). Both hung forever before this change.

## Not done

- Cookie jar **writing** (`Set-Cookie` -> jar), now unblocked.
- Switching `curl-get` / `curl-post-form` in scrape.arc off curl. The
  login path also needs 3xx tolerance, which `http-response` now gives.
- `scrape.arc` and `scrape2.arc` are still near-duplicates, diverging
  only at `hn-login` / `ensure-login`. Any scrape change lands twice
  until that's reconciled.
