; Client-side cookie jar, in the Netscape format curl reads and writes.
;
; The jar is shared with curl (scrape.arc seeds it, `curl -b` sends it),
; so it has to round-trip exactly: tab-separated fields, expiries in
; unix seconds, and a #HttpOnly_ prefix on the domain of an HttpOnly
; cookie.  A line looks like
;
;   #HttpOnly_news.ycombinator.com  FALSE  /  TRUE  2147368447  user  hnscraper&tok
;
; with fields domain, include-subdomains, path, secure, expiry, name,
; value.
;
; This is the read half -- enough to hand http-fetch a Cookie header:
;
;   (whenlet c (cookie-header (read-cookie-jar jar) url)
;     (http-fetch url (obj headers (list (list "Cookie" c)))))
;
; Capturing new cookies needs Set-Cookie off the response, which
; http-fetch doesn't expose yet.

(def url-parts (url)
  ; -> (scheme host path), or nil if url has no scheme.  the path keeps
  ; its query string; the port is dropped, since cookies ignore ports.
  ; > (url-parts "https://news.ycombinator.com/item?id=1")
  ; ("https" "news.ycombinator.com" "/item?id=1")
  (whenlet i (posmatch "://" url)
    (withs (rest  (cut url (+ i 3))
            slash (pos #\/ rest)
            host  (if slash (cut rest 0 slash) rest))
      (list (downcase (cut url 0 i))
            (downcase (or (car (tokens host #\:)) ""))
            (if slash (cut rest slash) "/")))))

(def parse-jar-line (line)
  ; one jar line -> a cookie table, or nil for comments, blank lines and
  ; malformed lines.  #HttpOnly_ prefixes the domain of an HttpOnly
  ; cookie -- it's a cookie, not a comment.
  (withs (httponly (begins line "#HttpOnly_")
          s        (if httponly (cut line (len "#HttpOnly_")) line))
    (unless (or (blank s) (begins s "#"))
      ; slices, not tokens: tokens collapses runs of separators, so a
      ; cookie with an empty value would lose its column and every
      ; field after it would shift.
      (let fs (slices s #\tab)
        (when (is (len fs) 7)
          (let (domain flag path secure expiry name value) fs
            (obj domain     (downcase (trim domain 'front [is _ #\.]))
                 ; a leading dot is the older spelling of the flag
                 subdomains (or (is (upcase flag) "TRUE") (begins domain "."))
                 path       (if (blank path) "/" path)
                 secure     (is (upcase secure) "TRUE")
                 expiry     (or (errsafe (as!int expiry)) 0)
                 name       name
                 value      value
                 httponly   httponly)))))))

(def read-cookie-jar (file)
  ; parse a jar file into a list of cookies.  a missing file gives nil,
  ; matching `curl -b` with no jar rather than erroring.
  (when (file-exists file)
    (each line (lines (filechars file))
      (whenlet c (parse-jar-line line)
        (out c)))))

(def cookie-domain-match (c host)
  ; host-only cookies must match exactly; one carrying the
  ; include-subdomains flag also matches any host under it.
  (or (is c!domain host)
      (and c!subdomains
           (withs (suffix (+ "." c!domain)
                   i      (- (len host) (len suffix)))
             (and (> i 0) (begins host suffix i))))))

(def cookie-path-match (c path)
  ; the query string isn't part of the path for matching purposes.
  (let p (aif (pos #\? path) (cut path 0 it) path)
    (or (is c!path "/")
        (is c!path p)
        (and (begins p c!path)
             ; /a matches /a/b but not /ab
             (or (is (c!path (- (len c!path) 1)) #\/)
                 (is (p (len c!path)) #\/))))))

(def cookie-sendable (c scheme host path now)
  (and (cookie-domain-match c host)
       (cookie-path-match c path)
       (or (no c!secure) (is scheme "https"))
       (or (is c!expiry 0) (> c!expiry now))))   ; 0 = session cookie

(def cookies-for (cookies url)
  ; the cookies that should be sent to url, longest path first (RFC 6265).
  (whenlet parts (url-parts url)
    (let (scheme host path) parts
      (let now (seconds)
        (sort (compare > [len _!path])
              (keep [cookie-sendable _ scheme host path now] cookies))))))

(def cookie-header (cookies url)
  ; the value for a Cookie: header, or nil when nothing matches.  values
  ; go out verbatim: HN's `user` cookie is "name&token", and urlencoding
  ; the & would break the session.
  (whenlet cs (cookies-for cookies url)
    (apply + (intersperse "; " (map [+ _!name "=" _!value] cs)))))
