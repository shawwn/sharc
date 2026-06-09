; HTTP Server.

; To improve performance with static files, set static-max-age*.

(= arcdir* "arc/" logdir* "arc/logs/" staticdir* "static/")

(= quitsrv* nil breaksrv* nil) 

(def serve ((o port 8080))
  (wipe quitsrv*)
  (ensure-srvdirs)
  (map [apply new-bgthread _] pending-bgthreads*)
  (w/socket s port
    ; (setuid 2) ; XXX switch from root to pg
    (prn "ready to serve port " port)
    (flushout)
    (= currsock* s)
    (until quitsrv*
      (handle-request s breaksrv*)))
  (prn "quit server"))

(def serve1 ((o port 8080))
  (w/socket s port (handle-request s t)))

(def ensure-srvdirs ()
  (map ensure-dir (list arcdir* logdir* staticdir*)))

(= srv-noisy* nil)

; http requests currently capped at 2 meg by socket-accept

; should threads process requests one at a time? no, then
; a browser that's slow consuming the data could hang the
; whole server.

; wait for a connection from a browser and start a thread
; to handle it. also arrange to kill that thread if it
; has not completed in threadlife* seconds.

(= threadlife* 30  requests* 0  requests/ip* (table)  
   throttle-ips* (table)  ignore-ips* (table)  spurned* (table))

(def handle-request (s breaksrv)
  (if breaksrv
      (handle-request-1 s)
      (errsafe (handle-request-1 s))))

(def handle-request-1 (s)
  (let (i o ip) (socket-accept s)
    (if (and (or (ignore-ips* ip) (abusive-ip ip))
             (++ (spurned* ip 0)))
        (force-close i o)
        (do (++ requests*)
            (++ (requests/ip* ip 0))
            (with (th1 nil th2 nil)
              (= th1 (thread
                       (after (handle-request-thread i o ip)
                              (close i o)
                              (kill-thread th2))))
              (= th2 (thread
                       (sleep threadlife*)
                       (unless (dead th1)
                         (prn "srv thread took too long for " ip))
                       (break-thread th1)
                       (force-close i o))))))))

; Returns true if ip has made req-limit* requests in less than
; req-window* seconds.  If an ip is throttled, only 1 request is 
; allowed per req-window* seconds.  If an ip makes req-limit* 
; requests in less than dos-window* seconds, it is a treated as a DoS
; attack and put in ignore-ips* (for this server invocation).

; To adjust this while running, adjust the req-window* time, not 
; req-limit*, because algorithm doesn't enforce decreases in the latter.

(= req-times* (table) req-limit* 30 req-window* 10 dos-window* 2)

(def abusive-ip (ip)
  (and (> (requests/ip* ip 0) 250)
       (let now (seconds)
         (do1 (if (req-times* ip)
                  (and (>= (qlen (req-times* ip)) 
                           (if (throttle-ips* ip) 1 req-limit*))
                       (let dt (- now (deq (req-times* ip)))
                         (if (< dt dos-window*) (set (ignore-ips* ip)))
                         (< dt req-window*)))
                  (do (= (req-times* ip) (queue))
                      nil))
              (enq now (req-times* ip))))))

(def handle-request-thread (i o ip)
  (with (nls 0 lines nil line nil responded nil t0 (msec))
    (after
      (whilet c (unless responded (readc i))
        (if srv-noisy* (pr c))
        (if (is c #\newline)
            (if (is (++ nls) 2) 
                (let (type op args n cooks) (parseheader (rev lines))
                  (let t1 (msec)
                    (case type
                      get  (respond o op args cooks ip)
                      post (handle-post i o op args n cooks ip)
                           (respond-err o "Unknown request: " (car lines)))
                    (log-request type op args cooks ip t0 t1)
                    (set responded)))
                (do (push (string (rev line)) lines)
                    (wipe line)))
            (unless (is c #\return)
              (push c line)
              (= nls 0))))
      (close i o)))
  (harvest-fnids))

(def log-request (type op args cooks ip t0 t1)
  (with (parsetime (- t1 t0) respondtime (- (msec) t1))
    (srvlog 'srv ip 
                 (num parsetime 3 t t t)
                 (num respondtime 3 t t t)
                 (if (> (+ parsetime respondtime) 1000) "***" "")
                 type
                 op
                 (let arg1 (car args)
                   (if (caris arg1 "fnid") "" arg1))
                 cooks)))

; Could ignore return chars (which come from textarea fields) here by
; (unless (is c #\return) (push c line))

(def handle-post (i o op args n cooks ip)
  (if srv-noisy* (pr "Post Contents: "))
  (if (no n)
      (respond-err o "Post request without Content-Length.")
      (let line nil
        (whilet c (and (> n 0) (readc i))
          (if srv-noisy* (pr c))
          (-- n)
          (push c line)) 
        (if srv-noisy* (pr "\n\n"))
        (respond o op (+ (parseargs (string (rev line))) args) cooks ip))))

(= type-header* (table))

(def gen-type-header (ctype)
  (+ "HTTP/1.0 200 OK
Content-Type: " ctype "
Connection: close"))

(each (k v) '((gif       "image/gif")
              (jpg       "image/jpeg")
              (png       "image/png")
              (text/html "text/html; charset=utf-8"))
  (= (type-header* k) (gen-type-header v)))

(= header*   (type-header* 'text/html)
   rdheader* "HTTP/1.0 302 Moved")

(= srvops* (table) redirector* (table) optimes* (table) opcounts* (table))

(def save-optime (name elapsed)
  ; this is the place to put a/b testing
  ; toggle a flag and push elapsed into one of two lists
  (++ (opcounts* name 0))
  (unless (optimes* name) (= (optimes* name) (queue)))
  (enq-limit elapsed (optimes* name) 1000))

; For ops that want to add their own headers.  They must thus remember 
; to prn a blank line before anything meant to be part of the page.

(mac defop-raw (name parms . body)
  (w/uniq t1
    `(= (srvops* ',name) 
        (fn ,parms 
          (let ,t1 (msec)
            (do1 (do ,@body)
                 (save-optime ',name (- (msec) ,t1))))))))

(mac defopr-raw (name parms . body)
  `(= (redirector* ',name) t
      (srvops* ',name)     (fn ,parms ,@body)))

; body has access to the request via (the req). Use arg!key to
; pull request args, (the me) for the logged-in user, (the ip)
; for the source ip.

(mac defop (name . body)
  (w/uniq (gs gr)
    `(do (wipe (redirector* ',name))
         (defop-raw ,name (,gs ,gr)
           (w/stdout ,gs (prn) ,@body)))))

; Defines op as a redirector.  Its retval is new location.

(mac defopr (name . body)
  (w/uniq (gs gr)
    `(do (set (redirector* ',name))
         (defop-raw ,name (,gs ,gr)
           ,@body))))

;(mac testop (name . args) `((srvops* ',name) ,@args))

(deftem request
  args  nil
  cooks nil
  ip    nil)

(= unknown-msg* "Unknown." max-age* (table) static-max-age* nil)

(def respond (str op args cooks ip)
  (w/stdout str
    (iflet f (srvops* op)
           (let req (inst 'request 'args args 'cooks cooks 'ip ip)
             ;; Bind per-request thread-locals once, here, so every
             ;; helper down the call stack can reach them via (the me)
             ;; / (the ip) / (the req) without explicit threading.
             ;; Each request runs on its own thread (see handle-
             ;; request-thread) so these are naturally isolated.
             (= (the req) req
                (the ip)  ip
                (the me)  (errsafe (get-user)))
             (if (redirector* op)
                 (do (prn rdheader*)
                     (prn "Location: " (f str req))
                     (prn))
                 (do (prn header*)
                     (awhen (max-age* op)
                       (prn "Cache-Control: max-age=" it))
                     (f str req))))
           (let filetype (static-filetype op)
             (aif (and filetype (file-exists (string staticdir* op)))
                  (do (prn (type-header* filetype))
                      (awhen static-max-age*
                        (prn "Cache-Control: max-age=" it))
                      (prn)
                      (w/infile-binary i it
                        (whilet b (readb i)
                          (writeb b str))))
                  (respond-err str unknown-msg*))))))

(def static-filetype (sym)
  (let fname (coerce sym 'string)
    (and (~find #\/ fname)
         (case (downcase (last (check (tokens fname #\.) ~single)))
           "gif"  'gif
           "jpg"  'jpg
           "jpeg" 'jpg
           "png"  'png
           "css"  'text/html
           "txt"  'text/html
           "htm"  'text/html
           "html" 'text/html
           "arc"  'text/html
           ))))

(def respond-err (str msg . args)
  (w/stdout str
    (prn header*)
    (prn)
    (apply pr msg args)))

(def parseheader (lines)
  (let (type op args) (parseurl (car lines))
    (list type
          op
          args
          (and (is type 'post)
               (some (fn (s)
                       (and (begins s "Content-Length:")
                            (errsafe:coerce (cadr (tokens s)) 'int)))
                     (cdr lines)))
          (some (fn (s)
                  (and (begins s "Cookie:")
                       (parsecookies s)))
                (cdr lines)))))

; (parseurl "GET /p1?foo=bar&ug etc") -> (get p1 (("foo" "bar") ("ug")))

(def parseurl (s)
  (let (type url) (tokens s)
    (let (base args) (tokens url #\?)
      (list (sym (downcase type))
            (sym (cut base 1))
            (if args
                (parseargs args)
                nil)))))

; I don't urldecode field names or anything in cookies; correct?

(def parseargs (s)
  (map (fn ((k v)) (list k (urldecode v)))
       (map [tokens _ #\=] (tokens s #\&))))

(def parsecookies (s)
  (map [tokens _ #\=] 
       (cdr (tokens s [or (whitec _) (is _ #\;)]))))

; Look up a request arg by key. Reads (the req), so callers don't
; need to thread req through. Accepts a symbol or string key:
;   (arg "id")   ; explicit string
;   (arg 'id)    ; symbol --- arc sugar:
;   arg!id       ; equivalent to (arg 'id)
(def arg (key)
  (let req (the req)
    (alref req!args (if (isa key 'sym) (string key) key))))

; reassemble-args urlencodes each key and value for safety

(def reassemble-args ((t req))
  (aif req!args
       (apply string "?" (intersperse '&
                                      (map (fn ((k v))
                                             (with (k (urlencode (string k))
                                                    v (urlencode v))
                                               (string k '= v)))
                                           it)))
       ""))

(= fns* (table) fnids* nil timed-fnids* nil)

; count on huge (expt 64 22) size of fnid space to avoid clashes

(def new-fnid ()
  (check (sym (rand-string 22)) ~fns* (new-fnid)))

(def fnid (f)
  (atlet key (new-fnid)
    (= (fns* key) f)
    (push key fnids*)
    key))

(def timed-fnid (lasts f)
  (atlet key (new-fnid)
    (= (fns* key) f)
    (push (list key (seconds) lasts) timed-fnids*)
    key))

; Within f, it will be bound to the fn's own fnid.  Remember that this is
; so low-level that need to generate the newline to separate from the headers
; within the body of f.

(mac afnid (f)
  `(atlet it (new-fnid)
     (= (fns* it) ,f)
     (push it fnids*)
     it))

;(defop test-afnid req
;  (tag (a href (url-for (afnid (fn (req) (prn) (pr "my fnid is " it)))))
;    (pr "click here")))

; To be more sophisticated, instead of killing fnids, could first 
; replace them with fns that tell the server it's harvesting too 
; aggressively if they start to get called.  But the right thing to 
; do is estimate what the max no of fnids can be and set the harvest 
; limit there-- beyond that the only solution is to buy more memory.

(def harvest-fnids ((o n 50000))  ; was 20000
  (when (len> fns* n) 
    (pull (fn ((id created lasts))
            (when (> (since created) lasts)
              (wipe (fns* id))
              t))
          timed-fnids*)
    (atlet nharvest (trunc (/ n 10))
      (let (kill keep) (split (rev fnids*) nharvest)
        (= fnids* (rev keep)) 
        (each id kill 
          (wipe (fns* id)))))))

(= fnurl* "/x" rfnurl* "/r" rfnurl2* "/y")

(= dead-msg* "\nUnknown or expired link.")
 
; Stored fnid fns are thunks --- they pull req/me/ip from the
; thread-locals bound in respond. Dispatch calls them with no args.

(defop-raw x (str req)
  (w/stdout str
    (aif (fns* (sym arg!fnid))
         (it)
         (pr dead-msg*))))

(defopr-raw y (str req)
  (aif (fns* (sym arg!fnid))
       (w/stdout str (it))
       "deadlink"))

(defopr r
  (aif (fns* (sym arg!fnid))
       (it)
       "deadlink"))

(defop deadlink
  (pr dead-msg*))

(def url-for (fnid)
  (string fnurl* "?fnid=" fnid))

; flink / rflink take a thunk. flink wraps it with (prn) so the
; generated page starts after a blank line; rflink just stores it
; (its return value is the redirect URL).
(def flink (f)
  (string fnurl* "?fnid=" (fnid {do (prn) (f)})))

(def rflink (f)
  (string rfnurl* "?fnid=" (fnid f)))

(mac w/link (expr . body)
  `(tag (a href (flink {do ,expr}))
     ,@body))

(mac w/rlink (expr . body)
  `(tag (a href (rflink {do ,expr}))
     ,@body))

(mac onlink (text . body)
  `(w/link (do ,@body) (pr ,text)))

(mac onrlink (text . body)
  `(w/rlink (do ,@body) (pr ,text)))

; bad to have both flink and linkf; rename flink something like fnid-link

(mac linkf (text . body)
  `(tag (a href (flink {do ,@body})) (pr ,text)))

(mac rlinkf (text . body)
  `(tag (a href (rflink {do ,@body})) (pr ,text)))

;(defop top (linkf 'whoami? (pr "I am " (get-user))))

;(defop testf (w/link (pr "ha ha ha") (pr "laugh")))

(mac w/link-if (test expr . body)
  `(tag-if ,test (a href (flink {do ,expr}))
     ,@body))

(def fnid-field (id)
  (gentag input type 'hidden name 'fnid value id))

; f should be a fn of one arg, which will be http request args.

(def fnform (f bodyfn (o redir))
  (form (if redir rfnurl2* fnurl*)
    (fnid-field (fnid f))
    (bodyfn)))

; Could also make a version that uses just an expr, and var capture.
; Is there a way to ensure user doesn't use "fnid" as a key?

; The aform / arform / taform / tarform / aformh / arformh macros
; take a HANDLER expression as their first argument (not a function
; value). The macro wraps it in a thunk for the fnid contract,
; but callers don't have to. The handler reads its own context
; through (the req), (the me), arg!key etc.

(mac aform (handler . body)
  `(form fnurl*
     (fnid-field (fnid {do (prn) ,handler}))
     ,@body))

(mac arform (handler . body)
  `(form rfnurl*
     (fnid-field (fnid {do ,handler}))
     ,@body))

; aform / arform variants with a fnid lifetime in seconds.

(mac taform (lasts handler . body)
  (w/uniq gh
    `(let ,gh {do (prn) ,handler}
       (form fnurl*
         (fnid-field (if ,lasts (timed-fnid ,lasts ,gh) (fnid ,gh)))
         ,@body))))

(mac tarform (lasts handler . body)
  (w/uniq gh
    `(let ,gh {do ,handler}
       (form rfnurl*
         (fnid-field (if ,lasts (timed-fnid ,lasts ,gh) (fnid ,gh)))
         ,@body))))

; aform / arform variants where the body should manage its own
; HTTP headers (no implicit blank line before content).

(mac aformh (handler . body)
  `(form fnurl*
     (fnid-field (fnid {do ,handler}))
     ,@body))

(mac arformh (handler . body)
  `(form rfnurl2*
     (fnid-field (fnid {do ,handler}))
     ,@body))

; only unique per server invocation

(= unique-ids* (table))

(def unique-id ((o len 8))
  (let id (sym (rand-string (max 5 len)))
    (if (unique-ids* id)
        (unique-id)
        (= (unique-ids* id) id))))

(def srvlog (type . args)
  (w/appendfile o (logfile-name type)
    (w/stdout o (atomic (apply prs (seconds) args) (prn)))))

(def logfile-name (type)
  (string logdir* type "-" (memodate)))

(with (lastasked nil lastval nil)

(def memodate ()
  (let now (seconds)
    (if (or (no lastasked) (> (- now lastasked) 60))
        (= lastasked now lastval (datestring))
        lastval)))

)

(defop || (pr "It's alive."))

(defop topips
  (when (admin)
    (whitepage
      (sptab
        (each ip (let leaders nil
                   (maptable (fn (ip n)
                               (when (> n 100)
                                 (insort (compare > requests/ip*)
                                         ip
                                         leaders)))
                             requests/ip*)
                   leaders)
          (let n (requests/ip* ip)
            (row ip n (pr (num (* 100 (/ n requests*)) 1)))))))))

(defop spurned
  (when (admin)
    (whitepage
      (sptab
        (map (fn ((ip n)) (row ip n))
             (sortable spurned*))))))

; eventually promote to general util

(def sortable (ht (o f >))
  (let res nil
    (maptable (fn kv
                (insort (compare f cadr) kv res))
              ht)
    res))


; Background Threads

(= bgthreads* (table) pending-bgthreads* nil)

(def new-bgthread (id f sec)
  (aif (bgthreads* id) (break-thread it))
  (= (bgthreads* id) (new-thread {while t (sleep sec) (f)})))

; should be a macro for this?

(mac defbg (id sec . body)
  `(do (pull [caris _ ',id] pending-bgthreads*)
       (push (list ',id {do ,@body} ,sec) 
             pending-bgthreads*)))



; Idea: make form fields that know their value type because of
; gensymed names, and so the receiving fn gets args that are not
; strings but parsed values.

