; Application Server.  Layer inserted 2 Sep 06.

; ideas: 
; def a general notion of apps of which prompt is one, news another
; give each user a place to store data?  A home dir?

; A user is simply a string: "pg". Use /whoami to test user cookie.

(= hpwfile*    (string arcdir* "hpw")
   adminfile*  (string arcdir* "admins")
   cookfile*   (string arcdir* "cooks")
   uidfile*    (string arcdir* "uids"))

(def asv ((o port (readenv "PORT" 8080)))
  (load-userinfo)
  (serve port))

(or= hpasswords*   (table) admins*        nil
     cookie->user* (table) user->cookies* (table)
     uid->user*    (table) user->uid*     (table))

(mac w/creating-users body
  `(after (w/the creating-users t
            ,@body)
     (save-uids)
     (save-pws)))

(def creating-users () (the creating-users))

(def load-userinfo ()
  (if (empty admins*) (load-admins))
  (if (empty user->uid*) (load-uids))
  (if (empty hpasswords*) (load-pws))
  (if (empty cookie->user*) (load-cookies))
  t)


(def admin ((t u me)) (if (only&mem u admins*) u))

(def load-admins ()
  (= admins* (map string (readfile adminfile*))))

(def save-admins ()
  (w/lock (save-lock adminfile*)
    (aand (apply string (intersperse #\newline admins*))
          (dispfile it adminfile*))))

; always reload admins on page refresh after modifying code.
;
; Ultimately have some way to reload non-arc files.

(load-admins)


(def users ((o test idfn))
  (keys user->uid* test))

(def load-uids ()
  (= user->uid* (load-table uidfile*))
  (each (k v) user->uid* (= (uid->user* v) k)))

(def save-uids ()
  (unless (creating-users)
    (save-table user->uid* uidfile*)))

(def lookup-uid ((t u me))
  (user->uid* u))

(def user-id ((t u me))
  (assert (lookup-uid u) "No uid for user @u"))

(def link-uid (u uid)
  (= (uid->user* uid) u
     (user->uid* u) uid)
  uid)

(or= maxuid-lock* (make-lock 21 "maxuid"))

(def ensure-uid ((t u me))
  (w/lock-or maxuid-lock*
    (lookup-uid u)
    (lets uid (new-user-id)
      (link-uid u uid)
      (save-uids))))

(diskvar maxuid* (+ arcdir* "max-uid") 0)

(def new-user-id ()
  (w/lock maxuid-lock*
    (lets uid (evtil (++ maxuid*) ~uid->user*)
      (todisk maxuid*))))


(def acct-exists ((t u me)) (if (only&hpasswords* u) u))

(def load-pws ()
  (= hpasswords* (load-table hpwfile*))
  (register-accts)
  t)

(or= dc-usernames* (table))

(def register-accts ()
  (= dc-usernames* (table [each (k v) hpasswords*
                            (set (_:downcase k))])))

(def register-acct (user)
  (set (dc-usernames* (downcase user)))
  user)

(def username-conflicts (user)
  (dc-usernames*:downcase user))

(def save-pws ()
  (unless (creating-users)
    (save-table hpasswords* hpwfile*) t))

(def create-acct (user pw)
  (set-pw user pw)
  user)

(def set-pw (user pw)
  (awhen (only&bhash pw)
    (set-hpw user it)
    user))

(def set-hpw (user hpw)
  (when hpw
    (ensure-uid user)
    (= (hpasswords* user) hpw)
    (register-acct user)
    (save-pws)
    user))

(def check-pw (user pw)
  (aand (hpasswords* user) (bcheckpw pw it)))

; bcrypt password hashing (cost 10, matching HN's $2b$10$ format).

(def bhash (pw)
  (bcrypt::hashpw pw 10))

(def bcheckpw (pw hash)
  (bcrypt::checkpw pw hash))

; ----- per-IP account-creation tracking -----
;
; In-memory ip -> list of unix-second creation times.  Resets on
; restart, which at worst grants one extra captcha-free signup window
; per IP after a bounce; fine for an abuse speed bump.

(or= acct-creations* (table))

(def note-acct-creation ((t ip) (o t0 (seconds)))
  ; record a creation and prune entries older than the look-back window.
  (= (acct-creations* ip)
     (cons t0 (keep [> _ (- t0 day*)]
                    (acct-creations* ip)))))

(def recent-acct-creations ((t ip) (o window day*))
  (let now (seconds)
    (len (keep [> _ (- now window)] (acct-creations* ip)))))


; idea: a bidirectional table, so don't need two vars (and sets)

(or= cookie->user* (table) user->cookies* (table) logins* (table))

(def load-cookies ()
  (= cookie->user* (load-table cookfile*)
     user->cookies* (table))
  (each (cookie user) cookie->user*
    (push cookie (user->cookies* user))))

(def save-cookies () (save-table cookie->user* cookfile*) t)

(def user-from-cookie ((t req))
  (aand (alref req!cooks "user")
        (cookie->user* it)))

(def get-user ((t req))
  (whenlets u (user-from-cookie req)
    (= (logins* u) (ip))))

(def cook-user! (user)
  (do1 (link-cookie user)
       (save-cookies)))

(def user-cookie (user)
  (car:user->cookies* user))

(def link-cookie (user (o cookie (new-user-cookie user)))
  (w/place-lock
    (= (cookie->user* cookie) user)
    (push cookie (user->cookies* user)))
  cookie)

(def new-user-cookie (user)
  (evtil (+ (assert user) "&" (rand-string 32)) ~cookie->user*))

(def logout-user ((t user me))
  (wipe (logins* user))
  (w/place-lock
    (each cookie (user->cookies* user)
      (wipe (cookie->user* cookie)))
    (wipe (user->cookies* user)))
  (save-cookies))

(def disable-acct (user)
  (set-pw user (rand-string 20))
  (logout-user user)
  user)

(def copy-account (old new)
  (assert (acct-exists old))
  (assert (~acct-exists new))
  (logout-user old)
  (logout-user new)
  (set-hpw new (hpasswords* old))
  new)

; (me)        --- read the current request's user
; (me other)  --- the current user, only if it equals other
;
; Doubles as predicate-and-value: (when (me other) ...) runs the body
; only when the viewer is `other`.

(def me args
  (if (no args) (the me) (caris args (the me))))

(def ip () (the ip))

(def op args
  (if (no args) (the op) (caris args (the op))))

(defplace me (fn () '(the me)))
(defplace ip (fn () '(the ip)))
(defplace op (fn () '(the op)))

(mac w/me (val . body)
  `(w/the me ,val ,@body))

(def fake-req ((o args) (t u me) (t ip))
  (inst 'request 'args (pair (map string args))
        'ip ip 'cooks (aif (user-cookie u) `(("user" ,it)))))

(mac w/args (args . body)
  `(w/the req (fake-req ,args)
     ,@body))


(mac when-umatch (user . body)
  `(if (me ,user)
       (do ,@body)
       (mismatch-message)))

(def mismatch-message ()
  (prn "Dead link: users don't match."))

(mac when-umatch/r (user . body)
  `(if (me ,user)
       (do ,@body)
       "mismatch"))

(defop mismatch (mismatch-message))

(mac uform (after . body)
  (w/uniq g
    `(let ,g (me)
       (aform (when-umatch ,g ,after) ,@body))))

(mac urform (after . body)
  (w/uniq g
    `(let ,g (me)
       (arform (when-umatch/r ,g ,after) ,@body))))

; Like onlink, but checks that user submitting the request is the
; same it was generated for.  For extra protection could log the
; username and ip addr of every genlink, and check if they match.

(mac ulink (text . body)
  (w/uniq g
    `(let ,g (me)
       (linkf ,text (when-umatch ,g ,@body)))))

(mac urlink (text . body)
  (w/uniq g
    `(let ,g (me)
       (rlinkf ,text (when-umatch/r ,g ,@body)))))

(defop admin (admin-gate))

(def admin-gate ()
  (if (admin)
      (admin-page)
      (login-page 'login nil {admin-gate})))

(def admin-page msg
  (let user (me)
    (whitepage
      (prbold "Admin: ")
      (hspace 20)
      (pr user " | ")
      (w/link (do (logout-user user)
                  (whitepage (pr "Bye " user ".")))
        (pr "logout"))
      (when msg (hspace 10) (map pr msg))
      (br2)
      (urform (with (u arg!acct p arg!pw)
                (if (or (empty u) (empty p))
                     (flink {pr "Bad data."})
                    (acct-exists u)
                     (flink {admin-page "User already exists: " u})
                     (do (create-acct u p)
                         "admin")))
        (pwfields "create (server) account")))))

(def hello-page ()
  (whitepage (prs "hello" (me) "at" (ip))))


; Shell.
;
; `shell` drops nils from the arg list so callers can conditionally
; include flags inline: `(shell 'curl (if quiet '-sS) url)`.

(def shellquote (str)
  (string "'" (multisubst (list (list "'" "'\"'\"'")) (string str)) "'"))

(def shellargs (cmd (o args))
  (string cmd " " (intersperse #\space (map shellquote:string (rem nil args)))))

(def shell (cmd . args)
  ; runs cmd with args, returns stdout as a string.
  (allchars (pipe-from (shellargs cmd args))))

(def shellsafe (cmd . args)
  (errsafe (apply shell cmd args)))


; Auth tokens.

; Per-user token for authenticating action links (e.g. hide).  Derived
; from a server secret so it can't be forged, stable per user so links
; keep working across restarts, and (unlike the cookie) safe to put in a
; url.

(diskvar hmac-key* (string arcdir* "hmac-key"))

(def auth-key ()
  (or hmac-key*
      (do1 (or= hmac-key* (rand-string 64))
           (todisk hmac-key*))))

; The token is bound to the user and the item id, so a token issued for
; one story can't be replayed to act on another.  It's the same for hide
; and un-hide of a given item (the un flag isn't part of the token).

(def auth-for (user id)
  (and user (downcase (sha1::hmac-sha1-hex (auth-key) (string user "/" id)))))

(def good-auth (user id (o auth (or arg!auth arg!hmac)))
  (and user auth (is auth (auth-for user id))))

(def auth-input (id (t u me))
  (and u (hidden-input 'hmac (auth-for u id))))

(mac item-form (action id whence . body)
  (w/uniq gid
    `(let ,gid ,id
       (form ,action
         (hidden-input 'id ,gid)
         (hidden-input 'goto ,whence)
         (auth-input ,gid)
         ,@body))))


; Safe redirects.

; A goto value comes straight from the query string, so before using it
; as a redirect target we make sure it points back into the site (a
; relative path, no scheme or //host).  Otherwise action links like
; hide could be turned into open redirects to phishing pages.

; goto arrives already url-decoded (parseargs decodes every query value),
; so we don't decode it again here.

(def safe-goto (goto (o default "/"))
  (if (and goto (relative-url goto)) goto default))

(def relative-url (s)
  (and (~blank s)
       (~begins s "//")            ; rejects protocol-relative "//host"
       (~find #\\ s)
       (let colon (pos #\: s)
         (or (no colon)            ; no scheme at all, or
             (aand (pos #\/ s)     ; the ':' only appears after the first '/'
                   (< it colon))))))


(defop login
  (login-page 'both nil (list {} (safe-goto arg!goto))))

; switch is one of: register, login, both

; afterward is either a function on the newly created username and
; ip address, in which case it is called to generate the next page 
; after a successful login, or a pair of (function url), which means 
; call the function, then redirect to the url.

; classic example of something that should just "return" a val
; via a continuation rather than going to a new page.

(def login-page (switch (o msg nil) (o afterward hello-page)
                        (o acct arg!acct) (o pw arg!pw) (o validate))
  (whitepage
    (pagemessage msg)
    (when (in switch 'login 'both)
      (login-form "Login" switch login-handler afterward acct pw)
      (hook 'login-form afterward acct pw)
      (br2))
    (when (in switch 'register 'both)
      (login-form "Create Account" switch create-handler afterward acct pw
                  (and validate recaptcha-widget)))))

(def login-form (label switch handler afterward
                       (o acct arg!acct) (o pw arg!pw) (o extra))
  (prbold label)
  (br2)
  ; extra, if given, is a thunk rendered inside the form after the
  ; username/password fields (e.g. a captcha widget), so whatever it
  ; emits posts along with the fnid form.
  (fnform {handler switch afterward}
          {do (pwfields (downcase label) acct pw)
              (if extra (extra))}
          (acons afterward)))

(def login-handler (switch afterward)
  (with (user arg!acct pw arg!pw)
    (unless (me user) (logout-user))
    (aif (good-login user pw (ip))
         (login it (ip) (car:user->cookies* it) afterward)
         (failed-login switch "Bad login." afterward))))

(def create-handler (switch afterward)
  (with (user arg!acct pw arg!pw)
    (logout-user)
    ; an over-threshold IP must solve a captcha.  show it on any bounce
    ; back to the form (a POST), but never on the initial form (a GET);
    ; tokens are single-use, so even a username error needs a fresh one.
    (aif (bad-newacct user pw)
         (failed-login 'register it afterward (recaptcha-required))
         (do (create-acct user pw)
             (note-acct-creation)
             (login user (ip) (cook-user! user) afterward)))))

(def login (user ip cookie afterward)
  (prcookie cookie)
  (= (logins* user) ip
     (the me) user)
  (hook 'login)
  (if (acons afterward)
      (let (f url) afterward
        (f)
        url)
      (do (prn)
          (afterward))))

(def failed-login (switch msg afterward (o validate)
                    (o acct arg!acct) (o pw arg!pw))
  (if (acons afterward)
      (flink {login-page switch msg afterward acct pw validate})
      (do (prn)
          (login-page switch msg afterward acct pw validate))))

(def prcookie (cook)
  (prheader "Set-Cookie"
            "user=" cook
            "; Path=/; expires=Sun, 17-Jan-2038 19:14:07 GMT"
            "; SameSite=Lax; Secure; HttpOnly"))

(def pwfields ((o label "login") (o acct arg!acct) (o pw arg!pw))
  (inputs (acct username 20 acct
                autocorrect    'off spellcheck 'false
                autocapitalize 'off autofocus  (is label "login"))
          (pw   password 20 pw))
  (br)
  (submit label))

(or= good-logins* (queue) bad-logins* (queue))

(def good-login (user pw ip)
  (let record (list (seconds) ip user)
    (if (check-pw user pw)
        (do (unless (user-cookie user) (cook-user! user))
            (enq-limit record good-logins*)
            user)
        (do (enq-limit record bad-logins*)
            nil))))

(def bad-newacct (user pw)
  (if (and (recaptcha-required)
           (~recaptcha-pass (arg "g-recaptcha-response")))
       "Validation required."
      (no (goodname user 2 15))
       "Usernames can only contain letters, digits, dashes and 
        underscores, and should be between 2 and 15 characters long.  
        Please choose another."
      (acct-exists user)
       "That username is taken. Please choose another."
      (username-conflicts user)
       "That username conflicts with an existing one.  Names are
        case-insensitive.  Please choose another."
      (or (no pw) (no (<= 8 (len pw) 72)))
       "Passwords should be between 8 and 72 characters long. Please
        choose another."
       nil))

(def goodchar (c)
  (or (alphadig c) (in c #\- #\_)))

(def goodname (str (o min 1) (o max nil))
  (and (isa!string str)
       (>= (len str) min)
       (~find ~goodchar str)
       (or (no max) (<= (len str) max))
       str))

(def fake-username ()
  (evtil (memorable-name) ~lookup-uid))

(def fake-usernames (n)
  (n-dedup n (fake-username)))

(def create-users (n pw (o init))
  (lets names (fake-usernames n)
    (let hpw (bhash pw)
      (w/creating-users
        (noisy-each 1000 u names
          (ensure-uid u)
          (set-hpw u hpw)
          (if init (unless (init u) (ero "Failed to init @u"))))))))

(defopr logout
  (when (and (me) (good-auth (me) "logout"))
    (logout-user))
  (safe-goto arg!goto))

(defop whoami
  (aif (me)
       (prs it 'at (ip))
       (do (pr "You are not logged in. ")
           (w/link (login-page 'both) (pr "Log in"))
           (pr "."))))


(= formwid* 60 bigformwid* 80 numwid* 16 formatdoc-url* nil)

; Eventually figure out a way to separate type name from format of 
; input field, instead of having e.g. toks and bigtoks

(def varfield (typ id val)
  (if (in typ 'string 'string1 'url)
       (gentag input type 'text name id value val size formwid*)
      (in typ 'num 'int 'posint 'sym)
       (gentag input type 'text name id value val size numwid*)
      (in typ 'users 'toks)
       (gentag input type 'text name id value (tostring (apply prs val))
                     size formwid*)    
      (is typ 'sexpr)
       (gentag input type 'text name id 
                     value (trim (tostring (map [do (write _) (sp)] val)))
                     size formwid*)
      (in typ 'syms 'text 'doc 'mdtext 'mdtext2 'lines 'bigtoks)
       (let text (if (in typ 'syms 'bigtoks)
                      (tostring (apply prs (map sanitize val)))
                     (is typ 'lines)
                      (tostring (apply pr (intersperse #\newline (map sanitize val))))
                     (in typ 'mdtext 'mdtext2)
                      (sanitize:unmarkdown val)
                     (no val)
                      ""
                     (sanitize val))
         (tag (textarea name id
                        cols (needcols typ)
                        rows (needrows text (needcols typ) 4)
                        wrap 'virtual 
                        style (if (is typ 'doc)
                                  "font-size:8.5pt"
                                  "vertical-align:bottom"))
           (prn) ; needed or 1 initial newline gets chopped off
           (pr text))
         (when (in typ 'mdtext 'mdtext2)
           (formatdoc-link)))
      (caris typ 'choice)
       (menu id (cddr typ) val)
      (is typ 'yesno)
       (menu id '("yes" "no") (if val "yes" "no"))
      (is typ 'hexcol)
       (gentag input type 'text name id value val)
      (is typ 'time)
       (gentag input type 'text name id value (if val (english-time val) ""))
      (is typ 'date)
       (gentag input type 'text name id value (if val (english-date val) ""))
       (err "unknown varfield type" typ)))

(def formatdoc-link ()
  (when formatdoc-url*
    (pr " ")
    (tag (a href formatdoc-url* tabindex -1)
      (tag (font size -2 color (gray 175))
        (pr "help")))))

(def text-rows (text wid (o pad 3))
  (+ (trunc (/ (len text) (* wid .8))) pad))

(def needcols (typ)
  (if (is typ 'doc) bigformwid* formwid*))

(def needrows (text cols (o pad 0))
  (+ pad (max (+ 1 (count #\newline text))
              (roundup (/ (len text) (- cols 5))))))

(def varline (typ id val (o liveurls))
  (if (in typ 'users 'syms 'toks 'bigtoks)  (apply prs (map sanitize val))
      (is typ 'lines)                       (map prn:sanitize val)
      (is typ 'yesno)                       (pr (if val 'yes 'no))
      (caris typ 'choice)                   (varline (cadr typ) nil val)
      (is typ 'url)                         (if (and liveurls (valid-url val))
                                                (link val)
                                                (pr (sanitize val)))
      (skip-sanitize typ id)                (pr (or val ""))
      (text-type typ)                       (pr (or (sanitize val) ""))
                                            (pr (sanitize val))))

(def skip-sanitize (typ id)
  (or (in typ 'mdtext 'mdtext2)
      (and (is typ 'string) (is id nil))))

(def text-type (typ) (in typ 'string 'string1 'url 'text 'mdtext 'mdtext2))

; Newlines in forms come back as /r/n.  Only want the /ns. Currently
; remove the /rs in individual cases below.  Could do it in aform or
; even in the parsing of http requests, in the server.

(def readvar (typ str (o fail nil))
  (case (carif typ)
    string  str
    string1 (if (blank str) fail str)
    url     (if (blank str) "" (valid-url str) str fail)
    num     (let n (saferead str) (if (number n) n fail))
    int     (let n (saferead str)
              (if (number n) (round n) fail))
    posint  (let n (saferead str)
              (if (and (number n) (> n 0)) (round n) fail))
    text    str
    doc     str
    mdtext  (md-from-form str)
    mdtext2 (md-from-form str t)                      ; for md with no links
    sym     (or (sym:car:tokens str) fail)
    syms    (map sym (tokens str))
    sexpr   (errsafe (readall str))
    users   (rem [no (goodname _)] (tokens str))
    toks    (tokens str)
    bigtoks (tokens str)
    lines   (lines str)
    choice  (readvar (cadr typ) str)
    yesno   (is str "yes")
    hexcol  (if (hex>color str) str fail)
    time    (or (errsafe (parse-time str)) fail)
    date    (or (errsafe (parse-date str)) fail)
            (err "unknown readvar type" typ)))

; dates should be tagged date, and just redefine <

(def varcompare (typ)
  (if (in typ 'syms 'sexpr 'users 'toks 'bigtoks 'lines 'hexcol)
       (fn (x y) (> (len x) (len y)))
      (is typ 'date)
       (fn (x y)
         (or (no y) (and x (date< x y))))
       (fn (x y)
         (or (empty y) (and (~empty x) (< x y))))))


; (= fail* (uniq))

(def fail* () nil) ; coudn't possibly come back from a form
  
; Takes a list of fields of the form (type label value view modify) and 
; a fn f and generates a form such that when submitted (f label newval) 
; will be called for each valid value.  Finally done is called.

(def vars-form (fields f done (o button "update") (o lasts))
  ; Capture (the me) at form-generation time so the submit-side
  ; when-umatch can verify the submitter is the same user who
  ; received the form.
  (let user (me)
    (tarform lasts
             (if (all [no (_ 4)] fields)
                 nil
                 (when-umatch user
                   (each (k v) (req-args)
                     (let name (sym k)
                       (awhen (find [is (cadr _) name] fields)
                         ; added sho to fix bug
                         (let (typ id val sho mod) it
                           (when (and mod v)
                             (let newval (readvar typ v fail*)
                               (unless (in newval fail* val)
                                 (f name newval))))))))
                   (done)))
      (tab
        (showvars fields))
      (unless (all [no (_ 4)] fields)  ; no modifiable fields
        (br)
        (submit button)))))
                
(def showvars (fields (o liveurls))
  (each (typ id val view mod question) fields
    (when view
      (unless (and (no val) (or (is id nil) (is typ 'raw)))
        (when question
          (tr (td (prn question))))
        (if (is typ 'raw)
            (pr val)
            (tr (unless question (tag (td valign 'top)  (only&pr id ":")))
                (td (if mod
                        (varfield typ id val)
                        (varline  typ id val liveurls)))))
        (prn)))))

; http://daringfireball.net/projects/markdown/syntax

(def md-from-form (str (o nolinks))
  (markdown (trim (rem #\return str) 'end) 60 nolinks))

(def markdown (s (o maxurl) (o nolinks))
  (let ital nil
    (tostring
      (forlen i s
        (iflet (newi spaces) (indented-code s i (if (is i 0) 2 0))
               (do (pr  "<p><pre><code>")
                 (let cb (code-block s (- newi spaces 1))
                   (presc cb)
                   (= i (+ (- newi spaces 1) (len cb))))
                 (pr "</code></pre>"))
               (iflet newi (parabreak s i (if (is i 0) 1 0))
                      (do (unless (is i 0) (pr "<p>"))
                          (= i (- newi 1)))
                      (is (s i) #\\)
                       ; a backslash escapes a following * into a literal
                       ; asterisk; otherwise it's a literal backslash.
                       (if (and (~atend i s) (is (s (+ i 1)) #\*))
                           (do (pr #\*) (++ i))
                           (pr #\\))
                      (and (is (s i) #\*)
                           (~atend i s) (is (s (+ i 1)) #\*))
                       ; a doubled ** is a literal asterisk, not emphasis
                       ; (even inside italics: *foo*** -> <i>foo*</i>)
                       (do (pr #\*) (++ i))
                      (and (is (s i) #\*)
                           (or ital
                               (atend i s)
                               (and (~whitec (s (+ i 1)))
                                    (pos #\* s (+ i 1)))))
                       (do (pr (if ital "</i>" "<i>"))
                           (= ital (no ital)))
                      (and (no nolinks) (urlmatch s i))
                       (withs (n   (urlend s i)
                               url (cut s i n))
                         (tag (a href url rel 'nofollow)
                           (presc (if (no maxurl) url (ellipsize url maxurl))))
                         (= i (- n 1)))
                       (presc (s i))))))))

(def indented-code (s i (o newlines 0) (o spaces 0))
  (let c (s i)
    (if (nonwhite c)
         (if (and (> newlines 1) (> spaces 1))
             (list i spaces)
             nil)
        (atend i s)
         nil
        (is c #\newline)
         (indented-code s (+ i 1) (+ newlines 1) 0)
         (indented-code s (+ i 1) newlines       (+ spaces 1)))))

; If i is start a paragraph break, returns index of start of next para.

(def parabreak (s i (o newlines 0))
  (let c (s i)
    (if (or (nonwhite c) (atend i s))
        (if (> newlines 1) i nil)
        (parabreak s (+ i 1) (+ newlines (if (is c #\newline) 1 0))))))

; Returns the indices of the next paragraph break in s, if any.

(def next-parabreak (s i)
  (unless (atend i s)
    (aif (parabreak s i) 
         (list i it)
         (next-parabreak s (+ i 1)))))

(def paras (s (o i 0))
  (if (atend i s)
      nil
      (iflet (endthis startnext) (next-parabreak s i)
             (cons (cut s i endthis)
                   (paras s startnext))
             (list (trim (cut s i) 'end)))))


; Returns the index of the first char not part of the url beginning
; at i, or len of string if url goes all the way to the end.

; Treats a delimiter as part of a url if it is (a) an open delimiter
; not followed by whitespace or eos, or (b) a close delimiter 
; balancing a previous open delimiter.

(def urlend (s i (o indelim))
  (let c (s i)
    (if (atend i s)
         (if ((orf punc whitec opendelim) c) 
              i 
             (closedelim c)
              (if indelim (+ i 1) i)
             (+ i 1))
        (if (or (whitec c)
                (and (punc c) (whitec (s (+ i 1))))
                (and ((orf whitec punc) (s (+ i 1)))
                     (or (opendelim c)
                         (and (closedelim c) (no indelim)))))
            i
            (urlend s (+ i 1) (or (opendelim c)
                                  (and indelim (no (closedelim c)))))))))

(def opendelim (c)  (in c #\< #\( #\[ #\{))

(def closedelim (c) (in c #\> #\) #\] #\}))

(def urlmatch (s i)
  (or (litmatch "http://" s i)
      (litmatch "https://" s i)))

(mac eachurl (var txt . body)
  (w/uniq (s n i)
    `(let ,s ,txt
       (forlen ,i ,s
         (when (urlmatch ,s ,i)
           (withs (,n (urlend ,s ,i)
                   ,var (cut ,s ,i ,n))
             ,@body
             (= ,i (- ,n 1))))))))

; Returns the list of urls in s, in order.

(def urls (s)
  (eachurl url s
    (out url)))


(def code-block (s i)
  (tostring
    (until (let left (- (len s) i 1)
             (or (is left 0)
                 (and (> left 2)
                      (is (s (+ i 1)) #\newline)
                      (nonwhite (s (+ i 2))))))
     (writec (s (++ i))))))

(def unmarkdown (s)
  (tostring
    (forlen i s
      (if (litmatch "<p>" s i)
           (do (++ i 2) 
               (unless (is i 2) (pr "\n\n")))
          (litmatch "<i>" s i)
           (do (++ i 2) (pr #\*))
          (litmatch "</i>" s i)
           (do (++ i 3) (pr #\*))
          (litmatch "<a href=" s i)
           (let endurl (posmatch [in _ #\> #\space] s (+ i 9))
             (if endurl
                 (do (pr (uneschtml (cut s (+ i 9) (- endurl 1))))
                     (= i (aif (posmatch "</a>" s endurl)
                               (+ it 3)
                               endurl)))
                 (writec (s i))))
          (litmatch "<pre><code>" s i)
           (awhen (findsubseq "</code></pre>" s (+ i 12))
             (pr (uneschtml (cut s (+ i 11) it)))
             (= i (+ it 12)))
          (is (s i) #\*)
           ; a literal asterisk in the html (i.e. not an <i>/</i> tag)
           ; must be escaped so it re-renders as a literal, not italics.
           (pr "\\*")
          (let (c newi) (uneschtml-char s i)
            (writec c)
            (= i (- newi 1)))))))


(def english-time (min)
  (let n (mod min 720)
    (string (let h (trunc (/ n 60)) (if (is h 0) "12" h))
            ":" (zeropad:mod n 60)
            (if (is min 0)   " midnight"
                (is min 720) " noon"
                (>= min 720) " pm"
                             " am"))))

(def parse-time (s)
  (let (nums (o label "")) (halve s letter)
    (with ((h (o m 0)) (map int (tokens nums ~digit))
           cleanlabel  (downcase (rem ~alphadig label)))
      (+ (* (if (is h 12)
                 (if (in cleanlabel "am" "midnight")
                     0
                     12)
                (is cleanlabel "am")
                 h
                 (+ h 12))
            60)
          m))))


(= months* '("January" "February" "March" "April" "May" "June" "July"
             "August" "September" "October" "November" "December"))

(def english-date ((y m d))
  (string d " " (months* (- m 1)) " " y))

(= month-names* (obj "january"    1  "jan"        1
                     "february"   2  "feb"        2
                     "march"      3  "mar"        3
                     "april"      4  "apr"        4
                     "may"        5
                     "june"       6  "jun"        6
                     "july"       7  "jul"        7
                     "august"     8  "aug"        8
                     "september"  9  "sept"       9  "sep"      9
                     "october"   10  "oct"       10
                     "november"  11  "nov"       11
                     "december"  12  "dec"       12))

(def monthnum (s) (month-names* (downcase s)))

; Doesn't work for BC dates.

(def parse-date (s)
  (let nums (date-nums s)
    (if (valid-date nums)
        nums
        (err (string "Invalid date: " s)))))

(def date-nums (s)
  (with ((ynow mnow dnow) (date)
         toks             (tokens s ~alphadig))
    (if (all [all digit _] toks)
         (let nums (map int toks)
           (case (len nums)
             1 (list ynow mnow (car nums))
             2 (iflet d (find [> _ 12] nums)
                        (list ynow (find [isnt _ d] nums) d)
                        (cons ynow nums))
               (if (> (car nums) 31)
                   (firstn 3 nums)
                   (rev (firstn 3 nums)))))
        ([all digit _] (car toks))
         (withs ((ds ms ys) toks
                 d          (int ds))
           (aif (monthnum ms)
                (list (or (errsafe (int ys)) ynow) 
                      it
                      d)
                nil))
        (monthnum (car toks))
         (let (ms ds ys) toks
           (aif (errsafe (int ds))
                (list (or (errsafe (int ys)) ynow) 
                      (monthnum (car toks))
                      it)
                nil))
          nil)))

; To be correct needs to know days per month, and about leap years

(def valid-date ((y m d))
  (and y m d
       (< 0 m 13)
       (< 0 d 32)))

; https://lispcookbook.github.io/cl-cookbook/dates_and_times.html

(def today ()
  (local-time::today))

(def parse-ymd (ymd)
  (let xs (tokens ymd)
    (case (len xs)
      1 (local-time::parse-timestring ymd)
      2 (local-time::parse-timestring (+ xs!0 "T" xs!1 ":00Z"))
      3 (err "Don't know how to parse @ymd"))))

(def format-ymd ((o ts (today)))
  (local-time::format-timestring
    nil ts :format '(:year "-" (:month 2) "-" (:day 2))))

(def format-mdy ((o ts (today)))
  (local-time::format-timestring
    nil ts :format '(:long-month " " :day ", " :year)))

(def format-time ((o ts (local-time::now)))
  (local-time::format-timestring
    nil ts :format '(:year "-" (:month 2) "-" (:day 2) "T"
                           (:hour 2) ":" (:min 2) ":" (:sec 2) "Z")))

(def add-ymd (y m d (o ts (today)))
  (local-time::adjust-timestamp
    ts
    (local-time::offset :year y)
    (local-time::offset :month m)
    (local-time::offset :day d)))

(def english-list xs
  (whenlet ys (rem blank xs)
    (tostring
      (case (len ys)
        0 nil
        1 (pr ys!0 ".")
        2 (pr ys!0 " or " ys!1 ".")
          (do (apply pr (intersperse ", " (almost ys)))
              (pr ", or " (last ys) "."))))))

(mac defopl (name . body)
  `(defop ,name
     (if (me)
         (do ,@body)
         (login-page 'both
                     "You need to be logged in to do that."
                     (list {} (string ',name (reassemble-args)))))))

