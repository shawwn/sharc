; Hacker News scraper.
;
; Fetches the live HN front page (and page 2) so flagged / dead /
; collapsed comments (which the official Firebase API doesn't expose)
; can be recovered by parsing the HTML directly.  Items + comments
; come from the HTML; user profiles come from the Firebase API for
; speed.
;
; Usage:
;   ./sharc scrape.arc                         ; one-shot crawl
;   arc> (load "scrape.arc") (scrape!)         ; same, interactive
;   arc> (load "scrape.arc") (import-scrape!)  ; load JSON into News
;
; Output:
;   arc/scrape/cookies.txt           curl cookie jar (HN session)
;   arc/scrape/item/{id}.json        merged story + comment tree
;   arc/scrape/user/{id}.json        user profile
;   arc/scrape/last-fetch.lisp       per-id last-fetched timestamps
;
; Respects the Crawl-delay from https://news.ycombinator.com/robots.txt
; between HTML page fetches (no delay for Firebase user lookups, which
; hit a separate host that doesn't publish one).

(when (main)
  (load "news.arc"))

; ----- Config -----

(= scrape-dir*       (string arcdir* "scrape/")
   scrape-item-dir*  (string arcdir* "scrape/item/")
   scrape-user-dir*  (string arcdir* "scrape/user/")
   scrape-cookies*   (string arcdir* "scrape/cookies.txt")
   scrape-fetchlog*  (string arcdir* "scrape/last-fetch.lisp")
   scrape-user-agent*
     "hnscraper (https://news.ycombinator.com/user?id=hnscraper; contact shawnpresser@@gmail.com)"
   scrape-item-refetch-secs* (* 60 5)   ; skip items refetched within last five minutes
   scrape-user-refetch-secs* (* 60 60)  ; skip users refetched within last hour
   ; robots.txt advertises Crawl-delay: 30 for generic bots.  The
   ; hnscraper account has explicit owner authorization to run faster;
   ; the About page invites contact if it's too aggressive.  Keep this
   ; conservative; revert to 30 if HN ops asks.
   scrape-crawl-delay*  0.55
   ; max parallel curl subprocesses for the user API.  Firebase has no
   ; advertised rate limit; 10 is comfortable.
   scrape-user-concurrency* 10
   scrape-item-concurrency* 1
   scrape-hn-host*      "https://news.ycombinator.com"
   scrape-api-host*     "https://hacker-news.firebaseio.com/v0")

(or= scrape-last-fetch* (table))     ; id -> unix seconds when last fetched

(= scrape-verbose* nil)

(def scrape-verbose ()
  (or scrape-verbose* (main-thread)))

(def scrapelog args
  (if (scrape-verbose) (atomic (apply prn args))))

(def scrape-ero args
  (if (scrape-verbose) (atomic (apply ero args))))

; Curl.

(def curl-args () (list "-sS" "--connect-timeout" "20" "--max-time" "120"
                        "-A" scrape-user-agent*))

(def curl-get (url)
  (whenlet c (cookie-header (read-cookie-jar scrape-cookies*) url)
    (http-fetch url (obj headers `(("Cookie" ,c))))))
  ;(string->utf8 (apply shellsafe 'curl (+ (curl-args) (list "-b" scrape-cookies* url)))))

(def curl-get-public (url)
  (http-fetch url))
  ;(string->utf8 (apply shellsafe 'curl (+ (curl-args) (list url)))))

(def curl-post-form (url fields)
  ; fields: alist of (key value) pairs.  POST as form-urlencoded.
  ; Saves + sends cookies via scrape-cookies*.
  (apply shellsafe 'curl
         (+ (curl-args)
            (list "-c" scrape-cookies* "-b" scrape-cookies*)
            (mappend (fn ((k v))
                       (list "--data-urlencode" (+ k "=" v)))
                     fields)
            (list url))))


; ----- Scraper config (username + optional password) -----
;
; `scrape.json` is gitignored.  On first run we copy
; `scrape.example.json` (committed, username only) into place.  The
; user may add a `"password":...` field manually; if they don't, we
; prompt at first login and save it back.  Password resolution order
; is: HN_SCRAPER_PASSWORD env var > scrape.json > prompt.

(= scrape-config*  "scrape.json"
   scrape-example* "scrape.example.json")

(def load-scrape-config ()
  (unless (file-exists scrape-config*)
    (when (file-exists scrape-example*)
      (copyfile scrape-example* scrape-config*)))
  (or (and (file-exists scrape-config*) (load-json scrape-config*))
      (obj username "hnscraper")))

(def save-scrape-config (cfg)
  (save-json cfg scrape-config*))


; ----- Password prompt (no-echo on TTYs) -----

(def stdin-is-tty? ()
  ; sh's `test -t 0` returns success iff stdin is a terminal.
  (is "yes"
      (errsafe (allchars (pipe-from "test -t 0 && printf yes")))))

(def read-password-noecho ()
  ; turn echo off around (readline) so the password doesn't print.
  ; the `after` makes sure we restore echo even on Ctrl-C / errors.
  (after (do (system "stty -echo 2>/dev/null") (readline))
         (system "stty echo 2>/dev/null")
         (prn)))

(def prompt-password (user)
  (unless (stdin-is-tty?)
    (err (+ "no terminal: set HN_SCRAPER_PASSWORD in env or "
            "add \"password\" to " scrape-config*)))
  (pr "HN password for " user ": ") (flushout)
  (read-password-noecho))

(def resolve-password (cfg)
  ; returns (pw source) where source is 'env, 'config, or 'prompt.
  ; nil if no password could be obtained (and no terminal to prompt).
  (or (whenlet pw (getenv "HN_SCRAPER_PASSWORD") (list pw 'env))
      (whenlet pw cfg!password                  (list pw 'config))
      (whenlet pw (prompt-password (or cfg!username "hnscraper"))
        (and (~empty pw) (list pw 'prompt)))))


; ----- Pre-baked cookie support -----
;
; If the user supplies HN_SCRAPER_COOKIE in the environment or a
; "cookie" field in scrape.json, we skip the login dance and just
; write the cookie value into curl's Netscape jar.  Format is the
; raw "username&token" string HN's `user` cookie carries (copy it
; from your browser's devtools).

(def write-cookie-file (value)
  ; Netscape cookie jar line; tabs between fields.
  ;   #HttpOnly_news.ycombinator.com  FALSE  /  TRUE  <expiry>  user  <value>
  ; HN's own cookies expire at 2147368447 (~year 2038), so we copy that.
  (let line (apply + (intersperse #\tab
              (list "#HttpOnly_news.ycombinator.com"
                    "FALSE" "/" "TRUE" "2147368447" "user" value)))
    (dispfile (+ "# Netscape HTTP Cookie File\n" line "\n")
              scrape-cookies*)))

(def seed-cookie-from-config! (cfg)
  ; if env or cfg has a cookie value, install it into the jar.
  ; returns t if a cookie was installed.
  (whenlet c (getenv "HN_SCRAPER_COOKIE" cfg!cookie)
    (write-cookie-file c)
    t))


; ----- Login -----

(def hn-logged-in? ((o user))
  ; quick check: fetch /news, look for the user?id=<user> link.
  (let u (or user (let cfg (load-scrape-config) cfg!username) "hnscraper")
    (aif (curl-get (+ scrape-hn-host* "/news"))
         (and (posmatch (+ "user?id=" u) it) t))))

(def hn-login ((o user) (o pw))
  (with (cfg (load-scrape-config) u user p pw source nil)
    (= u (or u cfg!username (err "no username in scrape.json")))
    (unless p
      (let resolved (resolve-password cfg)
        (unless resolved (err "no password supplied"))
        (= p      (car resolved)
           source (cadr resolved))))
    (prn "login: " u)
    (curl-post-form (+ scrape-hn-host* "/login")
                    (list (list "acct" u)
                          (list "pw"   p)
                          (list "goto" "news")))
    (lets ok (hn-logged-in? u)
      (prn "  -> " (if ok "logged in" "FAILED"))
      ; only persist a prompted password if the login actually worked
      (when (and ok (is source 'prompt))
        (= cfg!password p)
        (save-scrape-config cfg)
        (prn "  password saved to " scrape-config*)))))

(def ensure-login ()
  ; Order: (1) existing valid cookie jar, (2) cookie supplied via env
  ; or scrape.json, (3) password login.
  (let cfg (load-scrape-config)
    (or (and (file-exists scrape-cookies*) (hn-logged-in? cfg!username))
        (and (seed-cookie-from-config! cfg)
             (hn-logged-in? cfg!username))
        (hn-login))))


; ----- HTML helpers -----
;
; HN's markup is generated by a single Arc template so it's regular and
; quote-stable.  We just hunt for the right substring landmarks.

(def html-attr (src start name)
  ; given src and a position just inside a tag, find `name="..."` (or
  ; name='...') and return the attribute value (HTML-undecoded).
  ; Searches within the same tag only -- stops at `>`.
  (withs (tag-end (or (posmatch ">" src start) (len src))
          pat-eq  (+ name "=")
          p       (posmatch pat-eq src start))
    (when (and p (< p tag-end))
      (withs (q     (+ p (len pat-eq))
              qchar (if (< q tag-end) (src q))
              close (if (or (is qchar #\") (is qchar #\'))
                        (posmatch (string qchar) src (+ q 1))))
        (when (and close (<= close tag-end))
          (cut src (+ q 1) close))))))

(def between (src pat-open pat-close (o start 0))
  ; find the text between pat-open and pat-close (both string patterns),
  ; starting search from `start`.  returns (text end-pos) or nil.
  (whenlet p (posmatch pat-open src start)
    (let s (+ p (len pat-open))
      (whenlet e (posmatch pat-close src s)
        (list (cut src s e) e)))))


; ----- Front page ordering -----
;
; We get the ranked story list from the HN API's /v0/topstories.json --
; one request returns up to 500 ids, which is more authoritative than
; HTML-scraping /news + /news?p=2.  Per-story HTML is still scraped (in
; parse-item-page) for the dead/flagged/collapsed comment markers that
; the API doesn't expose.

(def fetch-topstories ()
  ; returns list of story ids in HN's current top-stories order, or nil
  (errsafe:from-json (curl-get-public (+ scrape-api-host* "/topstories.json"))))


; ----- HTML helpers used by item parsing -----

(def parse-titleline! (html start rec)
  (aif (between html "<span class=\"titleline\">" "</span>" start)
       (withs (inner   (car it)
               pseudo  (cut inner 0 (posmatch "<a " inner))
               m-url   (between inner "<a href=\"" "\"" 0)
               m-title (and m-url (between inner ">" "</a>" (cadr m-url)))
               url     (and m-url (uneschtml (car m-url)))
               m-site  (and m-url (parse-sitename html)))
         (parse-pseudotext! pseudo rec)
         ; an "item?id=N" href on the title means this is an Ask/text
         ; submission with no external URL.
         (when (and url (no (begins url "item?id=")))
           (= rec!url url))
         (if m-site  (= rec!site  (uneschtml (car m-site))))
         (if m-title (= rec!title (uneschtml (car m-title)))))))

(def parse-sitename (html)
  ; this doens't work for domains so long that they're ellipsized,
  ; e.g. "yetanothermathprogrammingconsultant.blogspot.com". Parse
  ; it directly from the from?site= url instead.
  ;(between html "<span class=\"sitestr\">" "</span>")
  (between html "<a href=\"from?site=" "\">"))

(def parse-pseudotext! (html rec)
  (unless (blank html)
    (= rec!pseudo html)
    (if (posmatch "[deleted]" html) (set rec!deleted))
    (if (posmatch "[flagged]" html) (set rec!flagged))
    (if (posmatch "[dead]"    html) (set rec!dead))
    (if (posmatch "[dupe]"    html) (set rec!dupe)))
  rec)

(def parse-subtext-row! (html start rec open-pat close-pat)
  (aif (between html open-pat close-pat start)
       (let inner (car it)
         (= rec!score     (parse-subtext-score    inner)
            rec!by        (parse-subtext-author   inner)
            rec!time      (parse-subtext-age      inner)
            rec!comments  (parse-subtext-comments inner)
            rec!timestamp (parse-subtext-timestamp inner)
            rec!seen      (seconds)))))

(def parse-subtext-score (html)
  (whenlet m-score (between html "<span class=\"score\"" "</span>" 0)
    (let txt (car m-score)
      (awhen (posmatch ">" txt)
        (errsafe:int:car:tokens (cut txt (+ it 1)))))))

(def parse-subtext-author (html)
  (car:between html "<a href=\"user?id=" "\"" 0))

(def parse-subtext-age (html)
  (whenlet m-age (between html "<span class=\"age\" title=\"" "\"" 0)
    (whenlet toks (tokens (car m-age))
      (errsafe:int (last toks)))))

(def parse-subtext-timestamp (html)
  (whenlet m-timestamp (between html "><a href=\"item?id=" "</a>")
    (whenlet p (posmatch ">" (car m-timestamp))
      (cut (car m-timestamp) (+ p 1)))))

(def parse-subtext-comments (html)
  (whenlet m-comments (between html " | <a href=\"item?id=" "</a>")
    (aand (posmatch ">" (car m-comments))
          (cut (car m-comments) (+ it 1))
          (whenlet p (posmatch "&nbsp;" it)
            (errsafe:int (cut it 0 p))))))



; ----- Item / comment page parsing -----
;
;   ... <tr class="athing comtr[ coll]" id="ID">
;       <td><table border="0"><tr>
;         <td class="ind" indent="N">...
;         <td valign="top" class="votelinks[ nosee]">...
;         <td class="default">
;           <div ...><span class="comhead">
;             <a href="user?id=USER" class="hnuser">USER</a>
;             <span class="age" title="ISO UNIX">...</span>
;             [flagged]  [dead]   <-- optional inline plaintext
;             <span class="navs">...</span>
;             <a class="togg clicky" id="ID" n="DCOUNT" ...>[..]</a>
;           </span></div><br>
;           <div class="comment[ noshow]">
;             <div class="commtext c00|c5A|cDD">TEXT-INLINE-HTML</div>
;             <div class="reply">...
;           </div>
;         </td>
;       </tr></table></td>
;     </tr>

(def parse-item-page (html)
  ; Parses both the story (top fatitem) and the comment list.
  ; Returns (obj story comments) where story is a table and comments
  ; is a list of comment tables in DFS render order.
  (w/table item
    (= item!story    (parse-fatitem html)
       item!comments (parse-comments html item!story!id))))

(def parse-fatitem (html)
  ; The story page's top item lives inside <table class="fatitem"> as a
  ; <tr class="athing submission" id="N"> row followed by a subtext row.
  ; Story text (for Ask HN / text submissions) lives in <div class="toptext">.
  (lets rec (obj type 'story)
    (whenlet ft (posmatch "<table class=\"fatitem\"" html 0)
      (whenlet p (posmatch "<tr class=\"athing" html ft)
        (aif (html-attr html p "id")
             (= rec!id (errsafe:int it)))
        (parse-titleline! html p rec)
        (parse-subtext-row! html p rec "<td class=\"subtext\">" "</tr>")
        (aif (between html "<div class=\"toptext\"" "</div>" p)
             (let text (car it)
               (aif (pos #\> text)
                    (= text (cut text (+ it 1))))
               (= rec!text (uneschtml text))))))))

(def parse-split (html (o anchor "<tr class=\"athing "))
  ; Split the html into per-item chunks once, then parse each in
  ; isolation.  Without this, posmatch's O(N) scans on the full 2MB
  ; html which turns this into N*M-quadratic.
  (accum a
    (with (positions nil start 0)
      (whilet p (posmatch anchor html start)
        (push p positions)
        (= start (+ p (len anchor))))
      (let ps (rev positions)
        (forlen i ps
          (withs (p (ps i)
                  end   (or (errsafe:ps (+ i 1)) (len html))
                  inner (cut html p end))
            (a inner)))))))

(def parse-listpage (html)
  (map parse-listitem (parse-split html)))

(def parse-listitem (html (o start 0))
  (lets rec (obj type 'story)
    (let p 0 ; (posmatch "<tr class=\"athing" html start)
      (= rec!id   (parse-item-id html)
         rec!rank (parse-item-rank html))
      (parse-titleline! html p rec)
      (parse-subtext-row! html p rec "<td class=\"subtext\">" "</tr>"))))

(def parse-item-id (html)
  (awhen (html-attr html 0 "id")
    (errsafe:int it)))

(def parse-item-rank (html)
  (whenlet inner (between html "<span class=\"rank\">" ".</span>")
    (errsafe:int (car inner))))

(def parse-morelink (html)
  (whenlet inner (between html "<tr class=\"morespace" "More")
    (whenlet url (between (car inner) "a href='" "'")
      (car url))))

(def parse-hn-itemlist ((o url "newest") (o n-pages 3))
  (lets xs nil
    (repeat n-pages
      (when url
        (whenlet html (fetch-hn-url url)
          (++ xs (parse-listpage html))
          (= url (parse-morelink html)))))))

(def parse-comments (html story-id)
  ; Split the html into per-comment chunks once, then parse each in
  ; isolation.  Without this, posmatch's O(N) scans on the full 2MB
  ; html which turns this into N*M-quadratic.
  (accum a
    (with (positions nil
           start 0
           anchor "<tr class=\"athing comtr"
           indent-stack (table))
      (whilet p (posmatch anchor html start)
        (push p positions)
        (= start (+ p (len anchor))))
      (let ps (rev positions)
        (forlen i ps
          (withs (p (ps i)
                  end (or (errsafe:ps (+ i 1)) (len html))
                  row (cut html p end))
            (whenlet c (parse-comment-row row story-id indent-stack)
              (a c)
              (= (indent-stack c!indent) c!id)
              (each k (keys indent-stack [> _ c!indent])
                (wipe (indent-stack k))))))))))

(def parse-comment-row (row story-id indent-stack)
  ; `row` is the substring starting at `<tr class="athing comtr` for one
  ; comment, up to (but not including) the next comment row's start.
  (catch
    (lets rec (obj type 'comment)
      ; collapsed: class="athing comtr coll"
      (when (posmatch "comtr coll" row 0)
        (set rec!collapsed))
      ; id="..."
      (aif (html-attr row 0 "id")
           (= rec!id (errsafe:int it)))
      (unless rec!id (throw nil))
      ; indent
      (= rec!indent (or (aif (between row "<td class=\"ind\" indent=\"" "\"" 0)
                             (errsafe:int (car it)))
                         0))
      ; parent: most recent comment at indent-1, else story
      (= rec!parent (or (indent-stack (- rec!indent 1)) story-id))
      ; comhead -- look for inline flags, user, age, descendants.
      ; The comhead contains nested <span> children (.age, .navs, ...)
      ; so use the outer "</span></div>" landmark, not the first </span>.
      (let comhead (or (car (between row "<span class=\"comhead\">" "</span></div>" 0)) "")
        (aif (between comhead "<a href=\"user?id=" "\"" 0)
             (= rec!by (car it)))
        (aif (between comhead "<span class=\"age\" title=\"" "\"" 0)
             (whenlet toks (tokens (car it))
               (= rec!time (errsafe:int (last toks)))))
        (if (posmatch "[flagged]" comhead) (set rec!flagged))
        (if (posmatch "[dead]"    comhead) (set rec!dead))
        (aand (between comhead "class=\"togg clicky\"" "</a>" 0)
              (html-attr (car it) 0 "n")
              (= rec!descendants (or (errsafe:int it) 0))))
      ; body text
      (aif (between row "<div class=\"commtext " "</div>" 0)
           (let inner (car it)
             (aif (posmatch "\"" inner)
                  (= rec!color (cut inner 0 it)))
             ; strip the "c00\">" prefix
             (aif (posmatch ">" inner)
                  (= rec!text (uneschtml (trim (cut inner (+ it 1)) 'end)))))))))


; ----- HN Firebase API (users only) -----

(def fetch-user (id)
  ; returns parsed user table, or nil
  (aand (curl-get-public (fetch-user-url id))
        (from-json it)
        (check it isa!table)))

(def fetch-user-url (id)
  (+ scrape-api-host* "/user/" id ".json"))


; ----- Refetch policy & deletion-aware merge -----

(def load-fetchlog ()
  (= scrape-last-fetch*
     (or (and (file-exists scrape-fetchlog*)
              (errsafe:load-table scrape-fetchlog*))
         (table))))

(def save-fetchlog ()
  (save-table scrape-last-fetch* scrape-fetchlog*))

(def recently-fetched? (id secs)
  (let t-last (scrape-last-fetch* id)
    (and t-last (< (- (seconds) t-last) secs))))

(def recently-fetched-item? (id)
  (recently-fetched? id scrape-item-refetch-secs*))

(def recently-fetched-user? (id)
  (recently-fetched? (sym (+ "u/" id)) scrape-user-refetch-secs*))

(def merge-comments (old-comments new-comments)
  ; old-comments and new-comments are lists of tables; key by id.
  ; Comments in old but not in new are kept with deleted=t.
  ; Comments in new override old.  Returns merged list in new order
  ; followed by deleted-only entries (so order on disk roughly tracks
  ; HN render order while preserving history).
  (with (new-ids (table) merged nil)
    (each c new-comments
      (set (new-ids c!id))
      (push c merged))
    (each c old-comments
      (unless (new-ids c!id)
        (set c!deleted)
        (push c merged)))
    (rev merged)))


; ----- Item scrape orchestration -----

(or= last-fetch-time* (now))

(def scrape-delay! ()
  (withs (t0      (now)
          elapsed (- t0 last-fetch-time*)
          delay   (- scrape-crawl-delay* elapsed))
    (= last-fetch-time* t0)
    (if (> delay 0) (sleep delay))))

(def fetch-hn-url (op)
  (atomic
    (scrape-delay!)
    (curl-get (+ scrape-hn-host* "/" op))))

(def fetch-hn-item (id)
  (fetch-hn-url (+ "item?id=" id)))

(def scrape-item! (id (o force))
  (if (and (no force) (recently-fetched-item? id))
      (do (scrapelog "  skip " id " (fetched recently)")
          (push-scraped-users:load-json (+ scrape-item-dir* id ".json")))
      (do
        (scrapelog "  item " id)
        (let html (fetch-hn-item id)
          (if (no html)
              (do (scrapelog "  FAILED to fetch " id) nil)
              (push-scraped-users:scrape-html! id html))))))

(def scrape-item-and-users! (id (o force))
  (do1 (scrape-item! id force)
       (let users (scraping-users)
         (scrape-users! users)
         (each u users (pop-user-to-fetch u)))))

(def scraped-users (tem)
  (dedup (cons tem!story!by (map !by tem!comments))))

(def scrape-and-import! (id (o force))
  (lets it (scrape-item! id force)
    (let authors (scraped-users it)
      (scrape-users! authors)
      ; users first (so items have authors)
      (import-scraped-users! authors)
      (import-scraped-item! id))))

(def push-scraped-users (result)
  ; collect users from the result whether freshly scraped or cached
  (when (and result result!story)
    (push-user-to-fetch result!story!by)
    (each c result!comments
      (push-user-to-fetch c!by)))
  result)

(def scrape-html! (id (o html (fetch-hn-item id)))
  (whenlet result (scrape-html id html)
    (save-json result (scraped-item-path id))
    (= (scrape-last-fetch* id) (seconds))
    (save-fetchlog)
    result))

(def scrape-html (id (o html (fetch-hn-item id)))
  (when html
    (withs (parsed (parse-item-page html)
            path   (scraped-item-path id)
            old    (and (file-exists path) (load-json path)))
      (build-item-json parsed old))))

(def build-item-json (parsed old)
  ; parsed = (obj story story comments comments).
  ; old (or nil) = previous saved record (decoded JSON; tables with symbol keys).
  (with (story    parsed!story
         comments parsed!comments
         old-comments (and old old!comments))
    (= story!fetched_at (seconds))
    (let merged (merge-comments old-comments comments)
      (obj story story comments merged))))

; users discovered during scraping; processed at end
(or= scrape-users-to-fetch* (table))

(def push-user-to-fetch (u)
  (when u (set (scrape-users-to-fetch* u))))

(def pop-user-to-fetch (u)
  (when u (wipe (scrape-users-to-fetch* u))))

(def scraping-users ()
  (keys scrape-users-to-fetch*))

(def scraping-user (u)
  (scrape-users-to-fetch* u))

(def finished-scraping-users ()
  (= scrape-users-to-fetch* (table)))


; ----- User scrape -----
;
; We deliberately avoid parsing+reserialising the firebase response.
; from-json on a 100KB user object (long `submitted` array) is ~0.4s
; per call in pure Arc, and parsing concurrently in many threads
; thrashes the allocator/GC.  Instead, save the raw response verbatim
; and inject `fetched_at` with a tiny string surgery on the trailing
; `}`.

(def scrape-user-url (id)
  (+ scrape-api-host* "/user/" id ".json"))

(def scrape-user! (id (o force))
  (when (or force (~recently-fetched-user? id))
    (let raw (curl-get-public (scrape-user-url id))
      (when (and raw (isnt raw "null") (>= (len raw) 2))
        (dispfile (inject-fetched-at raw (seconds))
                  (+ scrape-user-dir* id ".json"))
        (= (scrape-last-fetch* (sym (+ "u/" id))) (seconds))
        t))))

(def inject-fetched-at (raw t)
  ; raw is a JSON object string (firebase response).  Insert
  ; ,"fetched_at":<t> just before the trailing `}`.  No-op if the
  ; response doesn't look like a JSON object.  We avoid `trim`
  ; because copying a 100KB string per call wrecks throughput when
  ; many threads run this concurrently; instead, scan back from the
  ; end for the closing brace.
  (let n (len raw)
    (with (i (- n 1))
      (while (and (>= i 0) (whitec (raw i))) (-- i))
      (if (and (>= i 1) (is (raw i) #\}))
          (+ (cut raw 0 i)
             (if (is (raw (- i 1)) #\{) "" ",")
             "\"fetched_at\":" (string t) "}")
          raw))))


; ----- Bounded-parallel user scrape -----
;
; Fire N curls in parallel inside a single shell (`curl ... & ... &
; wait`).  Going through Arc threads + SBCL `run-program` per-curl is
; ~15x slower than native shell job control because each `run-program`
; call has measurable per-process overhead; one wrapping shell hides
; all of that.

(def scrape-users-parallel! (users (o force) (o batch-size scrape-user-concurrency*))
  (let pending (if force users (rem recently-fetched-user? users))
    (with (total (len pending) done 0)
      (each batch (tuples pending batch-size)
        (scrape-user-batch! batch)
        (= done (+ done (len batch)))
        (when (is 0 (mod done (max 1 (* batch-size 5))))
          (scrapelog "  users " done "/" total)
          (flushout))))))

(def scrape-user-batch! (ids)
  (atomic
    (= ids (keep scraping-user ids))
    (each id ids (pop-user-to-fetch id)))
  ; build a single shell command that backgrounds one `curl` per id
  ; and waits for them all.
  (let cmd
       (apply + (intersperse " "
                  (+ (map (fn (id)
                            (+ "curl -fsS --connect-timeout 20 --max-time 60 "
                               (shellquote (+ scrape-api-host* "/user/" id ".json"))
                               " -o "
                               (shellquote (+ scrape-user-dir* id ".json.raw"))
                               " &"))
                          ids)
                     '("wait"))))
    (system cmd)
    (let now (seconds)
      (each id ids
        (let raw-path (+ scrape-user-dir* id ".json.raw")
          (when (file-exists raw-path)
            (let raw (errsafe:filechars raw-path)
              (when (and raw (>= (len raw) 2))
                (dispfile (inject-fetched-at raw now)
                          (+ scrape-user-dir* id ".json"))
                (= (scrape-last-fetch* (sym (+ "u/" id))) now)))
            (errsafe:rmfile raw-path)))))))


; ----- Top-level entry -----

(def load-scrape ((o limit 60))
  (map ensure-dir (list scrape-dir* scrape-item-dir* scrape-user-dir*))
  (load-fetchlog)
  (scrapelog "crawl-delay: " scrape-crawl-delay* "s limit=" limit)
  (ensure-login)
  ; deleted comments are assigned to user "deleted", so import
  ; "deleted" now.
  (scrape-and-import-user! "deleted")
  t)

(def scrape-and-import-user! (u (o force))
  (scrape-user! u force)
  (awhen (scraped-user u)
    (import-scraped-user! it)
    u))

(def scrape-topstories! ((o limit 60))
  ; `limit` caps how many ranked stories to fetch.  Default 60 ~= the
  ; first two HN pages.  Use a smaller value for dev/testing.
  (let ids (firstn limit (fetch-topstories))
    ; record current rank for the importer (and for forensics).
    (let front (let i 0
                 (map (fn (id) (++ i)
                        (obj page (+ 1 (trunc:/ i 30))
                             rank (+ 1 i)))
                      ids))
      (save-json front (+ scrape-dir* "front.json")))
    ids))

(def scrape! ((o force) (o limit 60))
  (load-scrape limit)
  ; `limit` caps how many ranked stories to fetch.  Default 60 ~= the
  ; first two HN pages.  Use a smaller value for dev/testing.
  (let ids (scrape-topstories! limit)
    (scrapelog "topstories: " (len ids) " ids")
    (scrape-items-and-users! ids force)))

(def scrape-items-and-users! (ids (o force))
  (scrape-items! ids force)
  (scrape-users! (scraping-users))
  (finished-scraping-users))

(def scrape-items! (ids (o force))
  (parallel scrape-item! ids scrape-item-concurrency*)
  ;(each id ids
  ;  (scrape-item! id force))
  (save-fetchlog))

(def scrape-users! ((o users (scraping-users)) (o force))
  (scrapelog "scraping up to " (len users) " users "
             "(" scrape-user-concurrency* "-way parallel)")
  (scrape-users-parallel! users force)
  (save-fetchlog)
  (scrapelog "done."))


; ----- Import scraped JSON into News -----
;
; Populates items*/profs* so the local server's front page mirrors HN.
; Items are stored under their HN ids -- this may collide with locally
; created items if any.  Guard with `(news-active?)` and the user's
; explicit call to (import-scrape!).

; Scraper username as a symbol, used as the single flagger on every
; imported `[flagged]` comment.  Set by `import-scrape!` from the
; current scrape.json so the value matches the account that fetched
; the page.  Defaults to 'hnscraper for direct callers of
; `import-scraped-comment`.
(= scrape-flagger* "hnscraper")

; Shared dev password installed on every imported user that has no
; entry in hpasswords*.  Read from scrape.json's "dev-password" field,
; defaults to "unknown".  Set this to nil/empty in scrape.json to skip
; password installation entirely.
(= scrape-dev-password* "unknown")

(def scraped-front-path () (+ scrape-dir* "front.json"))

(def scraped-item-path (id) (+ scrape-item-dir* id ".json"))

(def scraped-user-path (u) (+ scrape-user-dir* u ".json"))

(def scraped-front ()
  (aif (file-exists:scraped-front-path) (load-json it)))

(def scraped-front-ids () (map !id (scraped-front)))

(def scraped-item (id)
  (aif (file-exists:scraped-item-path id) (load-json it)))

(def scraped-user (u)
  (aif (file-exists:scraped-user-path u) (load-json it)))

(def scraped-items ()
  (map int (scraped-files scrape-item-dir*)))

(def scraped-usernames ()
  (scraped-files scrape-user-dir*))

(def scraped-files (path)
  (map trim-file-ext
       (keep [endmatch ".json" _]
             (files path))))


(def trim-file-ext (x)
  (aif (lastpos #\. x)
       (cut x 0 it)
       x))
       
(def import-scrape! ()
  (map ensure-dir (list scrape-dir* scrape-item-dir* scrape-user-dir*
                        arcdir* newsdir* storydir* profdir* votedir*))
  ; hpasswords*/admins*/cookie->user* are populated by load-userinfo,
  ; which normally only runs from (asv).  If the caller hasn't started
  ; the server yet we'd hit "Unbound variable: hpasswords*" when
  ; installing dev passwords below.
  (load-userinfo)
  (with (cfg (load-scrape-config))
    (= scrape-flagger* (or cfg!username "hnscraper"))
    (when (isa!string cfg!dev-password)
      (= scrape-dev-password* cfg!dev-password)))
  (let ranked nil
    ; users first (so items have authors)
    (import-scraped-users!)
    ; then items, walking front.json (page+rank order from the scrape)
    (each tem (import-scraped-items!)
      (push tem!story ranked))
    (let stories (rev ranked)
      (= stories* (map [item _!id] stories)
         ranked-stories* (map [item _!id] stories)))
    ;; news's load-items normally populates comments* alongside
    ;; stories*, but it only runs from (nsv) when stories* is nil --
    ;; we've just set stories*, so we have to seed comments*
    ;; ourselves or /newcomments shows an empty list.
    ;(= comments* (sort (compare > !id) (keep acomment (vals items*))))

    ; Persist the ranking so a subsequent (nsv) -> (ensure-topstories)
    ; reads our order from disk instead of calling gen-topstories (which
    ; walks down by 1 from maxid*; with HN ids in the tens of millions
    ; that's catastrophic).
    (save-topstories)
    ; import-scraped-user staged any newly-set passwords in hpasswords*
    ; without writing -- flush once now (set-pw saves per call, which
    ; would be O(n^2) over a 1000-user import).
    (save-pws)
    (scrapelog "imported " (len ranked) " stories")))

(def import-scraped-items! ((o ids (scraped-front-ids)))
  (accum a
    (each id ids
      (only&a (import-scraped-item! id)))))

(def import-scraped-item! (id)
  (aif (scraped-item id)
       (when (and it!story it!story!by)
         (import-scraped-story it!story)
         (import-scraped-comments it!comments)
         it)))

;; news.arc's gen-topstories walks `(down id maxid* 1)` calling (item
;; id) for every integer from maxid* down to 1.  With imported HN ids
;; maxid* is ~48M, so a cold (nsv) (no topstories file on disk) freezes
;; trying to do 48 million hash lookups + file probes.  Override it
;; with an items*-driven version that touches only the ids we have.
;(def gen-topstories ()
;  (let metas (keep metastory (map item (keys items*)))
;    (= ranked-stories*
;       (or (sort (compare > (memo frontpage-rank)) metas)
;           nil))))

(def get-user-uid (u id)
  (assert (profile u) "No such profile for @u on @id")
  (assert (lookup-uid u) "No such uid for @u on @id"))

(def import-scraped-story (s)
  (let it (story-from-scraped-story s)
    ; record the story under the author's submitted list (used by
    ; /submitted and /threads).
    (whenlet author (only&profile s!by)
      (unless (mem it!id author!submitted)
        (push it!id author!submitted)
        (save-prof s!by)))
    (save-item it)
    (put-item it stories*)
    (register-story it)
    it))

(def story-from-scraped-story (s)
  (lets it (or= (items* s!id) (inst 'item 'id s!id))
    (= it!by    (get-user-uid s!by s!id))
    (= it!type  (sym (or s!type it!type "story")))
    (= it!time  (or s!time  it!time  (seconds)))
    (= it!text  (or s!text  it!text))
    (= it!score (or s!score it!score 0))
    (= it!title (or s!title it!title))
    (= it!url   s!url)
    (= it!dead  s!dead)
    (= it!deleted s!deleted)
    (unless (blank it!text)
      (when (posmatch "<a href" it!text)
        (pushnew 'links it!keys)))
    (pushnew 'imported it!keys)
    (wipe it!kids)
    (scrape-ero:tablist it)))

(def import-scraped-comments (comments)
  (each c comments
    (import-scraped-comment c)))

(def import-scraped-comment (c)
  (lets it (comment-from-scraped-comment c)
    ; link this comment under its parent's kids list.  Without this
    ; an item page renders the story but no comments -- news.arc's
    ; display-subcomments walks parent!kids, not (keep [is _!parent
    ; parent-id] all-items).
    (whenlet p (and c!parent (item c!parent))
      (unless (mem it!id p!kids)
        (++ p!kids (list it!id))
        (save-item p)))
    ; record this comment under the author's submitted list so
    ; news's (comments user) -- which walks (uvar user submitted) --
    ; picks it up for /threads?id=USER.
    (let user (or c!by "deleted")
      (whenlet author (profile user)
        (unless (mem it!id author!submitted)
          (= author!submitted (cons it!id author!submitted))
          (save-prof user))))
    (save-item it)
    (put-item it comments*)
    (register-comment it (unmarkdown it!text))
    (wipe (comment-cache* it!id))))

(def comment-from-scraped-comment (c)
  (lets it (or= (items* c!id) (inst 'item 'id c!id))
    ;(when (> id maxid*) (= maxid* id))
    (= it!by     (get-user-uid (or c!by "deleted") c!id)
       it!type   'comment
       it!parent (or c!parent it!parent)
       it!time   (or c!time it!time)
       it!text   (or c!text it!text)
       it!dead   (or c!dead it!dead)
       it!deleted (or c!deleted it!deleted (no c!by))
       it!score  (scraped-comment-score c it!score)
       (mem 'flagged it!keys)         c!flagged
       (mem scrape-flagger* it!flags) c!flagged
       (mem 'collapsed it!keys)       c!collapsed)
    (wipe it!kids)
    (pushnew 'imported it!keys)))

(def scraped-comment-score (c (o curscore))
  (aif c!dead     1
       c!deleted  (or curscore 1)
       c!color    (score-from-comment-class it)
                  1))


(def import-scraped-users! ((o users (scraped-usernames)) (o force))
  (let users (if force users (filter-scraped-usernames users))
    (scrapelog "importing @(len users) users")
    (w/creating-users
      (parallel [do (= (the creating-users) t)
                    (aif (scraped-user _) (import-scraped-user! it))]
                users 50 (if (scrape-verbose) 10)))))

(def filter-scraped-usernames (users)
  (rem profile&user->uid*&hpasswords* users))

(def import-scraped-user! (u)
  (lets p (user-from-scraped-user u)
    ; Install the dev password so you can log in as imported
    ; users locally.  Only set if hpasswords* doesn't already
    ; have an entry (don't clobber a real password if one was
    ; set via the web UI later).  Skip entirely if dev-password
    ; is nil/empty.
    (awhen (aand scrape-dev-password* (check it ~empty))
      (or= (hpasswords* p!id) (password-hash it)))
    (save-prof p!id)))

(defmemo password-hash (pw) (bhash pw))

(def user-from-scraped-user (u)
  (let id (string u!id)
    (when (goodname id)
      (unless (profile id) (init-user id))
      (lets p (profs* id)
        (when u!created (= p!created u!created))
        (when u!karma   (= p!karma   u!karma))
        (when u!about   (= p!about   u!about))))))


(= scrape-hn* t scrape-delay* 0.5)

(def scrape-hn-stories ((o ids (shuffle (fetch-topstories))))
  (each id ids
    (sleep scrape-delay*)
    (when scrape-hn*
      (call-reporting {scrape-and-import! id}))))

(mac defscrape (name secs . body)
  `(defbg ,name ,secs
     (when scrape-hn*
       (let ids (fetch-topstories)
         ,@body))))

(defscrape scrape-update-frontpage
  5 (= ranked-stories* (rem nil (map item ids)))
    (save-topstories))

(defscrape scrape-new-stories
  1 (scrape-hn-stories (rem item (shuffle ids))))

(defscrape scrape-new-frontpage-stories
  2 (scrape-hn-stories (rem item (firstn 60 ids))))

(defscrape scrape-stories-p1
  3 (scrape-hn-stories (firstn 30 ids)))

(defscrape scrape-stories-p2-p3
  5 (scrape-hn-stories (cut ids 30 90)))

(defscrape scrape-remaining-stories
  7 (scrape-hn-stories (cut ids 90)))

(when (main)
  (nsv)
  (repl))
