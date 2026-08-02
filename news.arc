#!./sharc

; News.  2 Sep 06.

; to run news: (nsv), then go to http://localhost:8080
; put usernames of admins, separated by whitespace, in arc/admins

; bug: somehow (+ votedir* nil) is getting evaluated.

(let port (readenv "PORT" 8080)
  (= this-site*    "HN Simulator"
     site-url*     "http://localhost:@port" ; no trailing slash
     site-email*   "hn@@ycombinator.lol"
     parent-url*   "/"
     favicon-url*  ""
     site-desc*    "Hacker News simulator" ; for rss feed
     site-color*   (color 170 170 230)
     border-color* (color 170 170 230)))


; Structures

; Could add (html) types like choice, yesno to profile fields.  But not 
; as part of deftem, which is defstruct.  Need another mac on top of 
; deftem.  Should not need the type specs in user-fields.

(deftem profile
  id         nil
  name       nil
  created    (seconds)
  auth       0
  member     nil
  submitted  nil
  votes      nil   ; for now just recent, elts each (time id by sitename dir)
  karma      1
  avg        nil
  weight     .5
  ignore     nil
  email      nil
  about      nil
  showdead   nil
  noprocrast nil
  firstview  nil
  lastview   nil
  maxvisit   20 
  minaway    180
  topcolor   nil
  keys       nil
  hidden     nil   ; ids of items this user has hidden from their listings
  favorites  nil   ; ids of items this user has marked as favorite
  collapsed  nil   ; ids of comments this user has collapsed
  delay      0)

(deftem item
  id         nil
  type       nil
  by         nil
  ip         nil
  time       (seconds)
  url        nil
  title      nil
  text       nil
  votes      nil   ; elts each (time ip by dir score effects)
  score      0
  sockvotes  0
  flags      nil
  dead       nil
  deleted    nil
  parts      nil
  parent     nil
  kids       nil
  keys       nil)


; Load and Save

(= newsdir*  (string arcdir* "news/")
   storydir* (string arcdir* "news/story/")
   profdir*  (string arcdir* "news/profile/")
   votedir*  (string arcdir* "news/vote/"))

(or= votes* (table) profs* (table))

(= initload-users* nil)

(def nsv ((o port (readenv "PORT" 8080)))
  (load-news)
  (serve port))

(def load-news ()
  (map ensure-dir (list arcdir* newsdir* storydir* votedir* profdir*))
  (load-userinfo)
  (unless stories*
    (load-items)
    (ensure-topstories))
  (if (and initload-users* (empty profs*)) (load-users)))

(def load-users ()
  (pr "load users: ")
  (noisy-each 1000 u (users)
    (profile u)))


(def profile ((t u me))
  (profs*|load-prof u))

(def load-prof (u)
  ; Have to check goodname because some user ids come from http requests.
  ; So this is like safe-item.  Don't need a sep fn there though.
  (aand (goodname u)
        (lookup-uid u)
        (file-exists (prof-path it))
        (lets p (temload 'profile it)
          (= (profs* p!id) p))))

(def save-prof ((t u me))
  (let uid (user-id u)
    (ensure-dir (prof-dir uid))
    (save-table (profile u) (prof-path uid))
    u))

; Need this because can create users on the server (for other apps)
; without setting up places to store their state as news users.

(def ensure-news-user ((t u me))
  (when (acct-exists u)
    (ensure-uid u)
    (unless (profile u)
      (init-user u))))
          
(def init-user (u)
  (atomic
    (unless (profs* u)
      (ensure-uid u)
      (or= (votes* u) (table) 
           (profs* u) (inst 'profile 'id u))
      (save-votes u)
      (save-prof u)
      u)))


(def votes ((t u me))
  (votes*|load-votes u))

(def load-votes ((t u me))
  (aand (lookup-uid u)
        (file-exists (votes-path it))
        (= (votes* u) (load-table it))))

(def save-votes ((t u me))
  (let uid (user-id u)
    (ensure-dir (votes-dir uid))
    (save-table (votes* u) (votes-path uid))
    u))

(mac uvar (u k) `((profile ,u) ',k))
(mac my (k) `((profile) ,k))

; '(me) (quoted) rather than (t u me): macro defaults evaluate
; at expansion time, so (t u me) would bake in (the me)'s value
; at compile time -- nil -- in every call site. The quoted form
; keeps (me) in the expansion to be evaluated at each runtime call.

(mac karma   ((o u '(me))) `(uvar ,u karma))
(mac ignored ((o u '(me))) `(uvar ,u ignore))

(def verify-user (u)
  (whenlet uid (lookup-uid u)
    (and (acct-exists u)
         (file-exists:votes-path uid)
         (file-exists:prof-path uid)
         u)))

(def duplicate-user (old new)
  (atomic
    (assert (verify-user old)) ; user exists with old name.
    (assert (~verify-user new)) ; no user data with new name.

    ; load user
    (profile old)
    (votes old)

    ; duplicate user data.
    (= (profs* new) (profs* old)  ; profile
       (votes* new) (votes* old)) ; votes

    ; if the old user was an admin, make the new user an admin.
    (when (mem old admins*)
      (pushnew new admins*)
      (save-admins))

    ; duplicate uid.
    (link-uid new (user-id old))

    ; both usernames now point to same uid.
    (save-uids)

    ; duplicate account data; both usernames now have same pw.
    (copy-account old new)

    (save-pws)

    new))

; erases user data, but leaves the profile intact.

(def erase-user (u)
  (atomic
    (assert (verify-user u))
    (assert (isnt (uid->user* (user-id u)) u)
            "@u still owns uid @(user-id u); erasing would orphan it")

    ; load user
    (profile u)
    (votes u)

    (logout-user u)

    ; remove the username's data:
    (wipe (profs* u))       ; profile
    (wipe (votes* u))       ; votes
    (wipe (hpasswords* u))  ; password
    (wipe (dc-usernames*:downcase u)) ; downcased usernames
    (wipe (user->uid* u))   ; uid

    ; remove from admins list.
    (when (mem u admins*)
      (pull u admins*)
      (save-admins))

    ; now that the username's data is no longer in memory, save the
    ; uids and passwords.
    (save-uids)
    (save-pws)

    u))

; Written such that news still loads if killed at any point.

(def rename-user (old new)
  (atomic
    ; first, duplicate the user data.
    (duplicate-user old new)

    ; now that all data exists for both usernames, rename.
    (= (uvar new id) new
       (uid->user* (user-id new)) new)
    (save-prof new)
    (save-uids)

    ; wipe the comment cache, so that the rename shows up immediately.
    (each id (uvar new submitted)
      (uncache-comment id))

    ; lastly, remove all user data associated with old name.
    (erase-user old)

    new))

(def loaded-users ((o f idfn))
  (keys profs* f))

(def loaded-votes ((o f idfn))
  (keys votes* f))

(def check-key (k (t u me))
  (and u (mem k (uvar u keys))))

(def by (i)
  (assert (uid->user* i!by) (uid-message i)))

(def uid-message (i)
  (+ "No such uid @{i!by}"
     (aif (the story) " on story @{it!id}")
     " from item @{i!id}"))

(def author (i (t u me)) (is u (by i)))

(def same-author (i s) (is (by i) (by s)))

(def same-ip (i s) (is i!ip s!ip))


(or= stories* nil comments* nil ; descending ids
     items* (table) url->story* (table))

(diskvar maxid* (+ newsdir* "max-id") 0)

(= initload* 15000)

(mac w/loading-items body
  `(w/the loading-items t
     (w/the loaded-items nil
       (do1 (do ,@body)
            (only&insert-items (the loaded-items))))))

(def loading-items () (the loading-items))

; Could be smarter about preloading by keeping track of popular pages.

(def load-items ((o n initload*))
  (system:list "rm" "-f" (string storydir* "*/*.tmp"))
  (pr "load items: ")
  (latest-items idfn nil n 100))

(def merge-item-lists (xs ys . zs)
  (if zs
      (apply merge-item-lists (merge-item-lists xs ys) zs)
      ; (compare < !id) is slightly misleading: it's used to sort items
      ; with equal ids. The resulting list is in desending order.
      (dedup-items (merge (compare < !id) (copylist xs) (copylist ys)))))

(def dedup-items (xs)
  (dedup xs !id))

(def item-buckets ()
  (aand (dirs storydir*)
        ; `almost` cuts each trailing "/" leaving a numeric string.
        (sort > (map int:almost it))))

(def item-ids (bucket)
  (aand (dir (string storydir* bucket))
        (sort > (map int it))))

(mac each-item-id (var . body)
  (w/uniq (bucket id)
    `(each ,bucket (item-buckets)
       (each ,var (item-ids ,bucket)
         ,@body))))

(mac each-item (var . body)
  (w/uniq id
    `(w/loading-items
       (each-item-id ,id
         (whenlet ,var (item ,id)
           ,@body)))))

(def ensure-topstories ()
  (aif (errsafe (readfile1 (+ newsdir* "topstories")))
       (= ranked-stories* (map item it))
       (do (prn "ranking stories.") 
           (flushout)
           (gen-topstories))))

(def astory   (i) (is i!type 'story))
(def acomment (i) (is i!type 'comment))
(def apoll    (i) (is i!type 'poll))

(def item (id) (items*|load-item id))

(def sameitem (compare is !id))
(def compitem (compare >  !time))

(mac put-item (i var (o cmp 'compitem) (o same 'sameitem))
  `(insortnew ,cmp ,i ,var ,same))

(mac pull-item (i var (o same 'sameitem))
  `(pull ,i ,var ,same))

(def load-item (id)
  (when (safe-id id)
    (let i (temload 'item (item-path id))
      (= (items* id) i)
      (if (loading-items) (push i (the loaded-items))
          (metastory i)   (put-item i stories*)
          (acomment i)    (put-item i comments*))
      (unless (blank i!url)
        (awhen (astory&live i)
          (register-url i i!url)))
      i)))

(def save-item (i)
  (ensure-dir (item-dir i!id))
  (save-table i (item-path i!id)))

(def new-item-id ()
  (do1 (evtil (++ maxid*) ~file-exists:item-path)
       (todisk maxid*)))

; these must stay constant after deploying news.

(= item-bucket-size* 5000
   prof-bucket-size* 5000
   vote-bucket-size* 5000)

(def bucket-id (id size) (trunc:/ id size))

(def item-dir (id)
  (string storydir* (bucket-id id item-bucket-size*) "/"))

(def prof-dir (uid)
  (string profdir* (bucket-id uid prof-bucket-size*) "/"))

(def votes-dir (uid)
  (string votedir* (bucket-id uid vote-bucket-size*) "/"))

(def item-path (id) (and id (string (item-dir id) id)))

(def prof-path (uid) (and uid (string (prof-dir uid) uid)))

(def votes-path (uid) (and uid (string (votes-dir uid) uid)))

; Note that duplicates are only prevented of items that have at some 
; point been loaded. 

(def register-url (i url)
  (= (url->story* (canonical-url url)) i!id))

; redefined later

(or= stemmable-sites* (table))

(def canonical-url (url)
  (if (stemmable-sites* (sitename url))
      (cut url 0 (pos #\? url))
      url))

(def kids (i) (map item i!kids))

; For use on external item references (from urls).  Checks id is int 
; because people try e.g. item?id=363/blank.php

(def safe-item (id)
  (aif (safe-id id) (item it)))

(def safe-id     (id) (ok-id:saferead id))
(def safe-uid    (id) (ok-uid:saferead id))
(def safe-int    (id) (ok-int:saferead id))
(def safe-whole  (id) (ok-whole:saferead id))
(def safe-posint (id) (ok-posint:saferead id))

(def find-id   (id) (file-exists (item-path id)))

(def ok-id     (id) (and (exact id) (find-id id) id))
(def ok-uid    (id) (and (exact id) (uid->user* id) id))
(def ok-int    (id) (and (exact id) id))
(def ok-whole  (id) (and (exact id) (>= id 0) id))
(def ok-posint (id) (and (exact id) (> id 0) id))

(def dead (i)         i!dead)
(def deleted (i)      i!deleted)
(def announcement (i) (mem 'announce i!keys))
(def imported (i)     (mem 'imported i!keys))

(defplace dead         (fn (i) `(,i 'dead)))
(defplace deleted      (fn (i) `(,i 'deleted)))
(defplace announcement (fn (i) `(mem 'announce (,i 'keys))))
(defplace imported     (fn (i) `(mem 'imported (,i 'keys))))

(def live (i) (no (dead|deleted i)))

(def kill (i how)
  (unless (dead i)
    (log-kill i how)
    (uncache-comment i!id)
    (set (dead i))
    (save-item i)))

(or= kill-log* nil)

(def log-kill (i (t how me))
  (push (list i!id how) kill-log*))

(def loaded-item-ids ()
  (sort > (keys items*)))

(mac each-loaded-item (var . body)
  (w/uniq g
    `(each ,g (loaded-item-ids)
       (whenlet ,var (items* ,g)
         ,@body))))

(def loaded-items (test)
  (accum a (each-loaded-item i (test&a i))))

(def newslog args (apply srvlog 'news (ip) (me) args))


; Ranking

; Votes divided by the age in hours to the gravityth power.
; Would be interesting to scale gravity in a slider.

(= gravity* 1.8 timebase* 120 front-threshold* 1 
   nourl-factor* .4 lightweight-factor* .3)

(def frontpage-rank (s (o scorefn realscore) (o gravity gravity*))
  (if (announcement s) inf
      (imported s)     0
                       (news-score s scorefn gravity)))

(def news-score (s (o scorefn realscore) (o gravity gravity*))
  (* (news-score-base (- (scorefn s) 0.5) (item-age s) gravity)
     (frontpage-penalty s)))


(def news-score-base (score age (o gravity gravity*))
  (/ (news-score-mul score)
     (news-score-div age gravity)))

(def news-score-mul (score)
  (if (> score 0) (expt score .8) score))

(def news-score-div (age (o gravity gravity*))
  (expt (/ (+ age timebase*) 60) gravity))

(def frontpage-penalty (s)
  (if (~in s!type 'story 'poll) .5
      (blank s!url)             nourl-factor*
      (lightweight s)           (min lightweight-factor* 
                                     (contro-factor s))
                                (contro-factor s)))

(def contro-factor (s)
  (aif (check (visible-family s nil) [> _ 20])
       (contro-score (realscore s) it)
       1))

(def contro-score (score ncomments)
  (min 1 (expt (/ score ncomments) 2)))

(def realscore (i) (- i!score i!sockvotes))

(disktable lightweights* (+ newsdir* "lightweights"))

(def lightweight (s)
  (or (dead s)
      (mem 'rally s!keys)  ; title is a rallying cry
      (mem 'image s!keys)  ; post is mainly image(s)
      (lightweights* (sitename s!url))
      (lightweight-url s!url)))

(defmemo lightweight-url (url)
  (in (downcase (last (tokens url #\.))) "png" "jpg" "jpeg"))

(def item-age (i) (minutes-since i!time))

(def user-age ((t u me)) (minutes-since (uvar u created)))

; Only looks at the 1000 most recent stories, which might one day be a 
; problem if there is massive spam. 

(def gen-topstories ()
  (= ranked-stories* (rank-stories 180 1000 (memo frontpage-rank))))

(def save-topstories ()
  (writefile (map !id (firstn 180 ranked-stories*))
             (+ newsdir* "topstories")))
 
(def rank-items (n consider scorefn (o test idfn))
  (bestn n (compare > scorefn) (latest-items test nil consider)))

(def rank-stories (n consider scorefn (o test idfn))
  (rank-items n consider scorefn metastory&test))

(def rank-comments (n consider scorefn (o test idfn))
  (rank-items n consider scorefn acomment&test))

(def latest-items (test (o stop) (o n) (o noisy))
  (accum a
    (w/noisy iter
      (catch
        (each-item i
          (if (or (and stop (stop i)) (and n (<= n 0)))
              (throw))
          (when (test i)
            (a i)
            (if n (-- n))
            (iter)))))))

(def insert-items (xs)
  (let items (items-by-type xs)
    (= stories*  (merge-item-lists stories* items!story items!poll)
       comments* (merge-item-lists comments* items!comment))
    (hook 'initload items))
  xs)

; gives a table whose each key is an item type, like !story or
; !comment, and whose value is a list of items of that type in
; descending order.

(def items-by-type (xs)
  (lets items (table)
    (each i xs
      (push i (items i!type)))
    ; ensure items are in descending id order
    (zaptable [sort (compare > !id) _] items)))

(def latest-items-by-type (n (o noisy))
  (items-by-type:latest-items idfn nil n noisy))

; redefined later

(def metastory (i) (and i (in i!type 'story 'poll)))

(def adjust-rank (s (o scorefn frontpage-rank))
  (put-item s ranked-stories* (compare > (memo scorefn)))
  (save-topstories))

; If something rose high then stopped getting votes, its score would
; decline but it would stay near the top.  Newly inserted stories would
; thus get stuck in front of it. I avoid this by regularly adjusting 
; the rank of a random top story.

;(defbg rerank-random 30 (rerank-random))

(def rerank-random ()
  (when ranked-stories*
    (adjust-rank (ranked-stories* (rand (min 50 (len ranked-stories*)))))))

(def topstories (n (o threshold front-threshold*))
  (retrieve n (andf shown [>= (realscore _) threshold]) ranked-stories*))

(= max-delay* 10)

(def cansee (i (t user me))
  (if (deleted i) (admin user)
      (dead i)    (or (author i user) (seesdead user))
      (flagged i) (or (author i user) (seesdead user))
      (delayed i) (author i user)
      t))

(let mature (table)
  (def delayed (i)
    (and (no (mature i!id))
         (acomment i)
         (or (< (item-age i) (min max-delay* (uvar (by i) delay)))
             (do (set (mature i!id))
                 nil)))))

(def seesdead ((t user me))
  (or (and user (uvar user showdead))
      (editor user)))

(def visible (items)
  (keep shown items))

(def shown (i) (cansee&~hidden i))

(def cansee-descendant (c (t user me))
  (or (cansee c user)
      (some [cansee-descendant (item _) user]
            c!kids)))
  
(def editor ((t u me))
  (and u (or (admin u) (> (uvar u auth) 0))))

(def member ((t u me))
  (and u (or (admin u) (uvar u member))))


; Page Layout

(= logo-url* "arc.png")

(unless (empty favicon-url*)
  (defopr favicon.ico favicon-url*))

; redefined later

(def gen-css-url ()
  (gentag link rel 'stylesheet type 'text/css href (static-src "news.css")))

(mac npage (title . body)
  `(tag (html op (op)) ; op lets hn.js know which listing it's on
     (tag head
       (gen-css-url)
       (gentag link rel "shortcut icon" href favicon-url*)
       (tag (script src (static-src "hn.js")))
       (tag title (presc ,title)))
     (tag body 
       (center
         (tag (table id 'hnmain border 0 cellpadding 0 cellspacing 0 width "85%"
                     bgcolor sand)
           ,@body)))))

(or= pagefns* nil)

(mac fulltop (lid label title whence . body)
  (w/uniq (gi gl gt gw)
    `(with (,gi ,lid ,gl ,label ,gt ,title ,gw ,whence)
       (npage (+ (if ,gt (+ ,gt bar*) "") this-site*)
         (if (check-procrast)
             (do (pagetop 'full ,gi ,gl ,gt ,gw)
                 (hook 'page ,gl)
                 ,@body)
             (row (procrast-msg ,gw)))))))

(mac longpage (t1 lid label title whence . body)
  (w/uniq gt
    (set (ignored-scopeids* gt)) ; ignore gt because (msec) is unique
    `(let ,gt ,t1
       (fulltop ,lid ,label ,title ,whence
         (tag (tr id "bigbox")
           (td ,@body))
         (trtd (vspace 10)
               (color-stripe (main-color))
               (br)
               (center
                 (or (hook 'longfoot) (footer))
                 (br2)
                 (admin-bar (- (msec) ,gt) ,whence)))))))

(def footer ()
  (spanclass yclinks
    (w/bars
      (link "Guidelines"  "newsguidelines.html")
      (link "FAQ"         "newsfaq.html")
      (link "Lists"       "lists")
      (link "API"         "https://github.com/HackerNews/API")
      (link "Security"    "security.html")
      (link "DMCA"        "dmca.html")
      (link "Apply to YC" "https://www.ycombinator.com/apply/")
      (link "Contact"     "mailto:@site-email*"))))

(def gc ((o full t))
  (sb-ext::gc :full full))

(def memory-after-gc ()
  (gc)
  (memory))

(def admin-bar (elapsed whence)
  (when (or (admin) arg!perf)
    (w/bars
      (pr (num:len fns*) " fnids")
      (pr "loaded " (num:len items*) " of " (num:item-count) " items")
      (pr (num:len:loaded-users) " of " (num maxuid*) " users")
      (pr (num:len:loaded-votes) " of " (num maxuid*) " votes")
      (pr (num:memory-after-gc) " bytes")
      (pr (num elapsed 3 t t) " msec")
      (when (admin)
        (link "settings" "newsadmin")
        (hook 'admin-bar whence)))))

(defcache item-count 60
  (len:all-item-ids))

(def all-item-ids ()
  (mappend item-ids (item-buckets)))

(def color-stripe (c)
  (tag (table width "100%" cellspacing 0 cellpadding 1)
    (tr (tdcolor c))))

(mac shortpage (lid label title whence . body)
  `(fulltop ,lid ,label ,title ,whence
     (trtd ,@body)))

(mac minipage (label . body)
  `(npage (+ this-site* bar* ,label)
     (pagetop nil nil ,label)
     (trtd ,@body)))

(def msgpage (msg (o title))
  (minipage (or title "Message")
    (spanclass admin
      (center (if (len> msg 80)
                  (widtable 500 msg)
                  (pr msg))))
    (br2)))


; Page top

(= sand (color 246 246 239) textgray (gray 130))

(def main-color ((t user me))
  (aif (and user (uvar user topcolor))
       (hex>color it)
       site-color*))

(def pagetop (switch lid label (o title) (o whence))
; (tr (tdcolor black (vspace 5)))
  (tr (tdcolor (main-color)
        (tag (table border 0 cellpadding 0 cellspacing 0 width "100%"
                    style "padding:2px")
          (tr (gen-logo)
              (when (is switch 'full)
                (tag (td style "line-height:12pt; height:10px;")
                  (spanclass pagetop
                    (tag (b class 'hnname)
                      (link this-site* "news"))
                    (toprow label))))
             (if (is switch 'full)
                 (tag (td style "text-align:right;padding-right:4px;")
                   (spanclass pagetop (topright whence)))
                 (tag (td style "line-height:12pt; height:10px;")
                   (spanclass pagetop (prbold label))))))))
  (each f pagefns* (f))
  (spacerow 10))

(def gen-logo ()
  (tag (td style "width:18px;padding-right:4px")
    (tag (a href parent-url*)
      (tag (img src logo-url* width 18 height 18
                style "border:1px #@(hexrep border-color*) solid; display:block;")))))

(or= toplabels* '(nil "welcome" "new" "threads" "comments" "lists" "*"))

; redefined later

(= welcome-url* "newswelcome.html")

(def toprow (label)
  (w/bars
    (if (noob) (toplink "welcome" welcome-url* label))
    (toplink "new" "newest" label)
    (if (me) (toplink "threads" (threads-url) label))
    (toplink "comments" "newcomments" label)
    (toplink "lists" "lists" label)
    (hook 'toprow label)
    (link "submit")
    (unless (mem label toplabels*)
      (tag (a href label)
        (fontcolor white (presc label))))))

(def toplink (name dest label)
  (tag-if (is name label) (span class 'topsel)
    (link name dest)))

(def topright (whence (o showkarma t))
  (when (me)
    (userlink (me) nil t (if (me) 'me))
    (when showkarma
      (pr " (")
      (tag (span id 'karma)
        (pr (karma)))
      (pr ")"))
    (pr " | "))
  (if (me)
      (link "logout" (logout-url whence) "logout")
      (link "login"  (login-url  whence) "login")))

(def logout-url (whence)
  (string "logout?goto=" (urlencode:safe-goto whence)
          "&auth=" (auth-for (me) "logout")))

(def login-url (whence)
  (string "login?goto=" (urlencode:safe-goto whence)))

(= noob-days* 14) ; how long a user's name is colored green

(def noob ((t u me) (t i story))
  (and u (if i
             (bynoob i u)
             (< (days-since (uvar u created)) noob-days*))))

(def bynoob (i (o u (by i)))
  (and u (< (- (user-age u) (item-age i))
            (* 60 24 noob-days*))))

; News-Specific Defop Variants

(mac defopt (name test msg . body)
  `(defop ,name
     (if (,test (me))
         (do ,@body)
         (login-page 'both (+ "Please log in" ,msg ".")
                     (list {} (string ',name (reassemble-args)))))))

(mac defopg (name . body) `(defopt ,name idfn   ""                     ,@body))
(mac defope (name . body) `(defopt ,name editor " as an editor"        ,@body))
(mac defopa (name . body) `(defopt ,name admin  " as an administrator" ,@body))

(def pagems ()
  (or (the ms) (msec)))

(mac opexpand (definer name parms . body)
  `(,definer ,name
     (with (user (me) ip (ip))
       (= (the ms) (msec))
       (with ,(mappend [list _ `(arg ',_)] parms)
         (newslog ',name ,@parms)
         ,@body))))

(or= newsop-names* nil)

(mac newsopr body
  `(opexpand defopr ,@body))

(mac newsop body
  `(do (pushnew ',(car body) newsop-names*)
       (opexpand defop ,@body)))

(mac newsopg body
  `(do (pushnew ',(car body) newsop-names*)
       (opexpand defopg ,@body)))

(mac adop (name parms . body)
  (w/uniq g
    `(opexpand defopa ,name ,parms
       (let ,g (string ',name)
         (shortpage nil ,g ,g ,g
           ,@body)))))

(mac edop (name parms . body)
  (w/uniq g
    `(opexpand defope ,name ,parms
       (let ,g (string ',name)
         (shortpage nil ,g ,g ,g
           ,@body)))))


; News Admin

(defopa newsadmin
  (newslog 'newsadmin)
  (newsadmin-page))

; Note that caching* is reset to val in source when restart server.

(def nad-fields ()
  `((num      caching         ,caching*                       t t)
    (posint   perpage         ,perpage*                       t t)
    (posint   threads-perpage ,threads-perpage*               t t)
    (yesno    autoreload      ,autoreload*                    t t)
    (bigtoks  comment-kill    ,comment-kill*                  t t)
    (bigtoks  comment-ignore  ,comment-ignore*                t t)
    (bigtoks  lightweights    ,(sort < (keys lightweights*))  t t)))

; Need a util like vars-form for a collection of variables.
; Or could generalize vars-form to think of places (in the setf sense).

(def newsadmin-page ()
  (shortpage nil nil "newsadmin" "newsadmin"
    (tag u (ulink "manage spam sites" (spamsites-page)))
    (br2)
    (vars-form (nad-fields)
               (fn (name val)
                 (case name
                   caching            (= caching* val)
                   perpage            (= perpage* val)
                   threads-perpage    (= threads-perpage* val)
                   autoreload         (= autoreload* val)
                   comment-kill       (todisk comment-kill* val)
                   comment-ignore     (todisk comment-ignore* val)
                   lightweights       (todisk lightweights* (memtable val))))
               {do "newsadmin"})
    (br2)
    (urform (let subject arg!id
              (if (profile subject)
                  (do (killallby subject)
                      (submitted-url subject))
                  "newsadmin"))
      (single-input "" 'id 20 "kill all by"))
    (br2)
    (urform (do (set-ip-ban arg!ip t)
                "newsadmin")
      (single-input "" 'ip 20 "ban ip"))))

(def spamsites-page ()
  (minipage "Spam Sites"
    (para "When a user submits a site from these domains, they'll be"
          " shown the message \"Stop spamming us\" and the item"
          " won't be submitted.")
    (para "(Only for annoyingly high-volume spammers. For ordinary"
          " spammers it's enough to ban their sites and ip"
          " addresses.)")
    (para)
    (br)
    (sptab
      (each site (sort < (keys big-spamsites*))
        (row (pr site) (tag u (ulink "remove"
                                (newslog 'remove-spamsite site)
                                (wipe (big-spamsites* site))
                                (todisk big-spamsites*)
                                (spamsites-page))))))
    (br)
    (uform (iflet site (sitename arg!url)
                  (do (newslog 'add-spamsite site)
                      (set (big-spamsites* site))
                      (todisk big-spamsites*)
                      (spamsites-page))
                  (pr "Bad url."))
      (single-input "" 'url 20 "add spam url"))
    (br)
    (link "Back" "newsadmin")))


; Users

(newsop user (id uid)
  (aif (only&profile id)
        (user-page id)
       (safe-uid uid)
        (user-page (uid->user* it))
        (pr "No such user.")))

(def prjson (x)
  (to-json x (is (downcase arg!print) "pretty")))

(newsopr user.json (id)
  (responding type-header*!json (prn)
    (prjson:user-api id)))

(def user-api (user)
  (w/me nil
    (whenlet p (profile user)
      (obj about     (check p!about ~blank)
           created   p!created
           id        p!id
           karma     p!karma
           submitted (keep cansee:item p!submitted)))))

(def user-page (user)
  (shortpage nil nil (+ "Profile: " user) (user-url user)
    (profile-form user)
    (hook 'user user)))

(def profile-form (user)
  (let prof (profile user)
    (when (and (me user) (blank prof!email))
      (alert-msg "Please put a valid address in the email field, or we
                 won't be able to send you a new password if you
                 forget yours.  Your address is only visible to you
                 and us.  Crawlers and other users can't see it."))
    (vars-form (user-fields user)
               (fn (name val)
                 (when (and (is name 'ignore) val (no prof!ignore))
                   (log-ignore user 'profile))
                 (when (and (is name 'topcolor) (is val (hexrep site-color*)))
                   (wipe val))
                 (= (prof name) val))
               {do (save-prof user)
                   (user-url user)})))

(def alert-msg (msg)
  (zerotable
    (tr (tdcolor (color 255 255 170)
          (tag (table cellpadding 5 width "100%")
            (row msg))))))

(= topcolor-threshold* 0)

(= email-msg*
  (tostring
    (tag (font size 2)
      (pr "Only admins see your email below. To share publicly,"
          " add to the 'about' box."))))

(def user-fields (user)
  (withs (e (editor)
          a (admin)
          w (me user)
          k (and w (> (karma user) topcolor-threshold*))
          u (or a w)
          m (or a (and (member user) (member)))
          p (profile user))
    `((raw     user        ,(user-field user)                        t   nil)
      (string  name        ,(p 'name)                               ,m  ,(and m u))
      (string  created     ,(text-age:user-age user)                 t   nil)
      (int     auth        ,(p 'auth)                               ,e  ,a)
      (yesno   member      ,(p 'member)                             ,a  ,a)
      (posint  karma       ,(p 'karma)                               t  ,a)
      (num     avg         ,(p 'avg)                                ,a  nil)
      (yesno   ignore      ,(p 'ignore)                             ,e  ,e)
      (num     weight      ,(p 'weight)                             ,a  ,a)
      (mdtext2 about       ,(p 'about)                               t  ,u)
      (raw     nil         ,(tostring:spacerow 5)                   ,u  nil)
      (string  nil         ,email-msg*                              ,u  nil)
      (string  email       ,(p 'email)                              ,u  ,u)
      (yesno   showdead    ,(p 'showdead)                           ,u  ,u)
      (yesno   noprocrast  ,(p 'noprocrast)                         ,u  ,u)
      (string  firstview   ,(p 'firstview)                          ,a   nil)
      (string  lastview    ,(p 'lastview)                           ,a   nil)
      (posint  maxvisit    ,(p 'maxvisit)                           ,u  ,u)
      (posint  minaway     ,(p 'minaway)                            ,u  ,u)
      (sexpr   keys        ,(p 'keys)                               ,a  ,a)
      (hexcol  topcolor    ,(or (p 'topcolor) (hexrep site-color*)) ,k  ,k)
      ,@(topcolor-default p u)
      (int     delay       ,(p 'delay)                              ,u  ,u)
      (string  nil         ,(resetpw-link)                          ,w   nil)
      (string  nil         ,(user-submissions-link user)             t   nil)
      (string  nil         ,(user-comments-link user)                t   nil)
      (string  nil         ,(user-hidden-link user)                 ,u   nil)
      (string  nil         ,(upvoted-links user)                    ,u   nil)
      (string  nil         ,(favorited-links u user)                 t   nil)
      )))

(def topcolor-default (p u)
  (when (p 'topcolor)
    `((string  default     ,(hexrep site-color*)                    ,u  nil))))

(def user-field (user)
  (tostring
    (tag (tr class 'athing)
      (tag (td valign 'top)
        (pr "user:"))
      (tag (td timestamp (uvar user created))
        (userlink user nil (me user))))))

(def resetpw-link ()
  (tostring:underlink "reset password" "resetpw"))

(def user-submissions-link ((t user me))
  (tostring:underlink "submissions" (submitted-url user)))

(def user-comments-link ((t user me))
  (tostring:underlink "comments" (threads-url user)))

(def user-hidden-link ((t user me))
  (when (hidden-items user)
    (tostring:underlink "hidden" (hidden-url user))))

(def upvoted-links ((t user me))
  (when (uvar user votes)
    (tostring
      (underlink "upvoted submissions" (upvoted-url user))
      (pr " / ")
      (underlink "comments" (upvoted-url user t)))))

(def favorited-links ((o u) (t user me))
  (if u
      (tostring
        (underlink "favorite submissions" (favorites-url user))
        (pr " / ")
        (underlink "comments" (favorites-url user t))
        (sp)
        (tag i
          (pr " (publicly visible)")))
      (tostring
        (underlink "favorites" (favorites-url user)))))


; Main Operators

; remember to set caching to 0 when testing non-logged-in 

; these are configurable via /newsadmin

(or= caching* 1 perpage* 30 threads-perpage* 10)

(= maxend* 210 cache-busters* '(perf p n next))

(mac newscache (name args time . body)
  (w/uniq gc
    `(let ,gc (cache {unless (some arg cache-busters*)
                       (* caching* ,time)}
                     (fn ,args
                       (tostring (w/me nil ,@body))))
       (def ,name ,args
         (if (me)
             (do ,@body)
             (pr (,gc ,@args)))))))


(newsop news () (newspage "news"))

(newsop ||   () (newspage ""))

;(newsop index.html () (newspage "index.html"))

(newscache newspage (whence) 90
  (listpage (msec) (topstories maxend*) nil nil
            (pageurl whence) t
            [pageurl whence (+ (curpage) 1)]))

(def listpage (t1 items label title (o url label) (o number t) (o moreurl) (o perpage perpage*))
  (hook 'listpage)
  (longpage t1 nil label title url
    (when items
      (aif (the listpage-body) (it))
      (display-items items label title url number moreurl perpage))))

(def paginated (display items label title (o url label) (o number t) (o moreurl) (o perpage perpage*))
  (let (start end numstart items) (paginate items perpage)
    (display-page display items label title url start end number moreurl numstart)))

(def display-items (items label title whence (o number t) (o moreurl) (o perpage perpage*))
  (paginated (fn (n i whence (o inlist))
               (display-item n i whence inlist)
               (spacerow (if (acomment i) 15 5) "spacer"))
             items label title whence number moreurl perpage))

(def curpage ()
  (or (safe-posint arg!p) 1))

(def cur-n ()
  (or (safe-posint arg!n) 1))

(def pageurl (whence (o p (curpage)) (o n (cur-n)))
  (whenceurl whence nil
             (if (> n 1) n)
             (if (> p 1) (string p))))

(def nexturl (whence (o next arg!next) (o n (cur-n)))
  (whenceurl whence
             (only&string next)
             (if (only&> n 1) (string n))
             nil))

(def whenceurl (whence (o next arg!next) (o n arg!n) (o p arg!p))
  (let sep (if (pos #\? whence) #\& #\?)
    (if p
         (string whence sep "p=" (urlencode:string p))
        next
         (string whence sep "next=" (urlencode:string next)
                 (when n
                   (string "&n=" (urlencode:string n))))
         whence)))

; Returns (start end numstart items): start/end are the index window into
; items for the page, numstart is the rank to show for the first item.
; ?p=N gives a page-numbered window; ?next=ID[&n=N] is an id cursor (used by
; newest/from, whose lists run newest-id-first) that keeps items from ID on.

(def paginate (items perpage)
  (aif (safe-posint arg!p)
        (with (start (* (- it 1) perpage)
               end   (* it perpage))
          (list start end (+ start 1) items))
       (safe-id arg!next)
        (list 0 perpage (cur-n) (keep [<= _!id it] items))
        (list 0 perpage (cur-n) items)))


(newsop newest () (newestpage))

; Note: dead/deleted items will persist for the remaining life of the 
; cached page.  If this were a prob, could make deletion clear caches.

(newscache newestpage () 40
  (listpage (msec) (newstories) "new" "New Links"
            (nexturl "newest") t
            [nexturl "newest" _ (+ (cur-n) perpage*)]))

(def newstories ((o n maxend*))
  (retrieve n shown stories*))

;(def newstories ((o n maxend*) (o consider 2000))
;  (rank-stories n consider !time shown))


(newsop best () (bestpage))

(newscache bestpage () 1000
  (listpage (msec) (beststories) "best" "Top Links"
            (pageurl "best") t
            [pageurl "best" (+ (curpage) 1)]))

; As no of stories gets huge, could test visibility in fn sent to best.

(def beststories ((o n maxend*))
  (bestn n (compare > realscore) (visible stories*)))


(newsop noobstories () (noobspage stories* "noobstories"))
(newsop noobcomments () (noobspage comments* "noobcomments"))

(def noobspage (source whence)
  (listpage (msec) (noobs maxend* source) whence "New Accounts"
            (nexturl whence) nil
            [nexturl whence _]))

(def noobs (n source)
  (retrieve n cansee&bynoob source))

(newsop show () (showpage))

(newscache showpage () 60
  (listpage (msec) (showstories) "show" "Show"
            (pageurl "show") t
            [pageurl "show" (+ (curpage) 1)]))

(def showstories ((o n maxend*))
  (retrieve n shown&ashow stories*))

(def ashow (i)
  (headmatch "Show HN" i!title))

(mac margin args
  (tostring
    (each (kind val) (pair args)
      (pr "margin-" kind ":" val ";"))))

(newsop from (site kind next)
  (with (stories  (items-from site metastory)
         comments (items-from site acomment))
    (w/the listpage-body
           {tag (div style (margin left 36px top 6px bottom 12px))
             (w/bars
               (link (plural (len stories) "submission")
                     (fromurl site nil "story"))
               (link (plural (len comments) "comment")
                     (fromurl site nil "comment")))}
      (let kind (saferead (or kind "story"))
        (listpage (pagems)
                  (case kind
                    story   stories
                    comment comments)
                  "from"
                  (string (when (is kind 'story)
                            "Submissions from ")
                          site)
                  (fromurl site) nil
                  [fromurl site _])))))

(def fromurl (site (o next arg!next) (o kind arg!kind))
  (whenceurl
    (string "from?" (if site "site=") (only&urlencode site)
            (if (or kind next) "&kind=@(or kind "story")"))
    (only&string next)))

(def items-from (site test)
  (visible (keep test (map item (sitename->items* site)))))


(newsop bestcomments () (bestcpage))

(newscache bestcpage () 1000
  (listpage (msec) (bestcomments maxend*)
            "best comments" "Best Comments"
            (pageurl "bestcomments") nil
            [pageurl "bestcomments" (+ (curpage) 1)]))

(def bestcomments (n)
  (bestn n (compare > realscore) (visible comments*)))


(newsop lists ()
  (longpage (msec) nil "lists" "Lists" "lists"
    (sptab
      (row (link "best")         "Highest voted recent links")
      (row (link "bestcomments") "Highest voted recent comments")
      (row (link "active")       "Most active current discussions")
      (row (link "noobstories")  "Submissions from new accounts")
      (row (link "noobcomments") "Comments from new accounts")
      (row (link "leaders")      "Users with most karma")
      (row (link "topcolors")    (topcolors-label))
      (when (editor)
        (spacerow 10)
        (row (prbold "Editor links"))
        (map [row:link _] '(flagged killed)))
      (when (admin)
        (spacerow 10)
        (row (prbold "Admin links"))
        (map [row:link _] '(optimes editors topips spurned badlogins
                            goodlogins badguys badsites badips)))
      (hook 'listspage))))

(def topcolors-label ()
  (pr "A sampler of ")
  (underlink "topcolors" "https://news.ycombinator.com/item?id=97573")
  (pr " chosen by active users"))


; Upvoted page

(def voted-items (test (t user me))
  (keep (andf test [cansee _ user])
        (map item (keys:votes user))))

(def upvoted-url (user (o comments))
  (string "upvoted?id=" user (if comments "&comments=t")))

(newsop upvoted (id comments) 
  (if (only&profile id)
      (upvoted-page id (in comments "t" "T"))
      (pr "No such user.")))

(def upvoted-page (user comments)
  (if (or (me user) (admin))
      (with (items (sort (compare < item-age)
                         (voted-items (if comments acomment metastory) user))
             title (if (~me user)
                        "@{user}'s upvoted @(if comments 'comments 'submissions)"
                        "Upvoted @(if comments 'comments 'submissions)"))
        (listpage (pagems) items "upvoted" title
                  (nexturl (upvoted-url user comments)) (no comments)
                  [nexturl (upvoted-url user comments) _
                           (unless comments (+ (cur-n) perpage*))]))
      (pr "Can't display that.")))


; Favorites

(def favorite-items (test (t user me))
  (keep test (keep [cansee _ user] (map item (uvar user favorites)))))

(def favorites-url (user (o comments))
  (string "favorites?id=" user (if comments "&comments=t")))

(newsop favorites (id comments) 
  (if (profile id)
      (favorites-page id (in comments "t" "T"))
      (pr "No such user.")))

(def favorites-page (user comments)
  (with (items (favorite-items (if comments acomment metastory) user)
         title "@{user}'s favorites")
    (w/the listpage-body
           {tag (div style "margin-left:14px; margin-top:6px; margin-bottom:12px")
             (w/bars
               (link "submissions" (favorites-url user))
               (link "comments" (favorites-url user t)))
             (unless items
               (para (string user " hasn't added any favorite "
                             (if comments 'comments 'submissions) " yet."))
               (para "To add one to your own favorites, click on its timestamp"
                     " to go to its page, then click 'favorite' at the top."))}
      (listpage (pagems) items "favorites" title
                (nexturl (favorites-url user comments)) (no comments)
                [nexturl (favorites-url user comments) _
                         (unless comments (+ (cur-n) perpage*))]))))

(def fave-url (id (o auth arg!auth) (o un (in arg!un "t" "T")))
  (or= auth (auth-for (or (me) "") id))
  (string "fave?id=" (urlencode:string id)
          (if un "&un=t")
          (if auth (string "&auth=" (urlencode auth)))))

; The (good-auth "" id auth) branch lets a favorite survive logging in:
; the logged-out "favorite" link carries an auth token bound to "" (no
; user), so after the login redirect the fave still goes through.  That
; "" token is the same for every logged-out visitor, so it's effectively
; public and lets an attacker CSRF a logged-in user into favoriting an
; arbitrary item.  We accept that intentionally: favoriting is a benign,
; public, easily-undone action, and keeping fave-on-login is worth it.

(newsopr fave (id auth)
  (let i (safe-item id)
    (if (~me)
         (string "login?goto=" (urlencode (fave-url id auth)))
        (and i (or (good-auth (me) id auth)
                   (good-auth  ""  id auth))) ; "" = fave on login (see above)
         (do (set-favorite (me) id)
             (favorites-url (me) (acomment i)))
         (favorites-url (me)))))

(def set-favorite (user id (o un (in arg!un "t" "T")))
  (aand (safe-id id)
        (do (= (mem it (uvar user favorites)) (no un))
            (save-prof user))))


; Story Display

(def display-page (display items label title whence
                   (o start 0) (o end perpage*) (o number)
                   (o moreurl) (o numstart (+ start 1)))
  (zerotable
    (let n (- numstart 1)
      (each i (cut items start end)
        (display (and number (++ n)) i whence)))
    (when end
      (when (< end (len items))
        (spacerow 10 "morespace")
        (tr (tag (td colspan (if number 2 1)))
            (tag (td class 'title)
              (morelink display-page
                        display items label title end (+ end perpage*)
                        number moreurl (+ numstart perpage*))))))))

; This code is inevitably complex because the More fn needs to know 
; its own fnid in order to supply a correct whence arg to stuff on 
; the page it generates, like logout and delete links.

(def morelink (f display items label title start end number moreurl . args)
  (tag (a href
          (if moreurl
              (moreurl (moreitem (items start)))
              (url-for
                (afnid {do (prn)
                           (let url (url-for it) ; it bound by afnid
                             (newslog 'more label)
                             (longpage (msec) nil label title url
                               (apply f display items label title url start
                                      end number moreurl args)))})))
          class 'morelink
          rel 'next)
    (pr "More")))

(def moreitem (x)
  (if (isa!table x) x!id x))

(def display-story (i s whence)
  (w/the story s
    (when (cansee|!kids s)
      (tag (tr class "athing submission" id s!id)
        (display-item-number i)
        (tag (td valign 'top class 'votelinks) (votelinks s whence))
        (titleline s s!url whence))
      (tr (tag (td colspan (if i 2 1)))
          (tag (td class 'subtext)
            (spanclass subline
              (hook 'itemline s)
              (itemline s whence)
              (unless i (editlink s))
              (when (flaggable i s) (flaglink s whence))
              (hidelink s whence)
              (favelink s)
              (when (in s!type 'story 'poll) (commentlink s))
              (when (apoll s) (addoptlink s))
              (killlink s whence)
              (blastlink s whence)
              (blastlink s whence t)
              (deletelink s whence)
              (unless (blank s!text) (linkslink s whence))
              (if (admin) (fromlink s))))))))

(def flaggable (i s)
  (or (no i) (astory s)))

(def fromlink (s)
  (unless (blank s!url)
    (if (admin) (pr bar*))
    (let site (sitename s!url)
      (link (if (admin) "from" (ellipsize site 40))
            (+ "from?site=" site)))))

(def display-item-number (i)
  (when i (tag (td align 'right valign 'top class 'title)
            (spanclass rank (pr i ".")))))

(= follow-threshold* 5)

(def titleline (s url whence)
  (tag (td class 'title)
    (if (cansee s)
        (spanclass titleline
          (deadmark s)
          (titlelink s url)
          (awhen (sitename url)
            (tag (span class "sitebit comhead")
              (pr " (" )
              (if (admin)
                  (w/rlink (do (set-site-ban it
                                             (case (car (banned-sites* it))
                                               nil    'ignore
                                               ignore 'kill
                                               kill   nil))
                               whence)
                    (let ban (car (banned-sites* it))
                      (tag-if ban (font color (case ban
                                                ignore darkred
                                                kill   darkblue))
                        (spanclass sitestr (pr it)))))
                  (spanclass sitestr (fromlink s)))
              (pr ") "))))
        (pr (pseudo-text s)))))

(def titlelink (s url)
  (let toself (blank url)
    (tag (a href (if toself
                      (item-url s!id)
                     (or (live s) (author s) (editor))
                      url
                      nil)
            rel  (unless (or toself (> (realscore s) follow-threshold*))
                   'nofollow)) 
      (presc s!title))))
      
(def pseudo-text (i)
  (if (deleted i) "[deleted]"
      (flagged i) "[flagged]"
      (delayed i) "[delayed]"
                  "[dead]"))

(def deadmark (i)
  (when (flagged i)
    (pr " [flagged] "))
  (when (and (dead i) (seesdead))
    (pr " [dead] "))
  (when (and (deleted i) (admin))
    (pr " [deleted] ")))

(= downvote-threshold* 0 downvote-time* 1440)

(= votewid* 14)
      
(def votelinks (i whence (o downtoo))
  (center
    (if (author i)
         (do (fontcolor orange (pr "*"))
             (br)
             (hspace votewid*))
        ; Render arrows for logged-out viewers (click -> login) and for
        ; logged-in users who could vote here, ignoring whether they've
        ; already voted (canvote ... t).  When they have voted, votelink
        ; adds nosee so the arrows are present but hidden, letting hn.js
        ; un-hide them on unvote.
        (and (cansee i) (or (~me) (canvote i 'up t)))
         (do (votelink i whence 'up)
             (if (and downtoo
                      (or (admin)
                          (< (item-age i) downvote-time*))
                      (canvote i 'down t))
                 (votelink i whence 'down)
                 ; don't understand why needed, but is, or a new
                 ; page is generated on voting
                 (tag (span id (+ "down_" i!id)))))
        (hspace votewid*))))

(def voted (i)
  (aif (votes) (it i!id)))

(defplace voted (fn (i) `((votes* (me)) (,i 'id))))

; could memoize votelink more, esp for non-logged in users,
; since only uparrow is shown; could straight memoize

; redefined later (identically) so the outs catch new vals of up-url, etc.

(def votelink (i whence dir)
  (tag (a id    (if (me) (string dir '_ i!id))
          ; hn.js's click handler catches .clicky; nosee hides an arrow
          ; the user has already used (visibility:hidden) until unvote.
          class (if (me) (string 'clicky (if (voted i) " nosee")))
          href  (vote-url i dir whence))
    (if (is dir 'up)
        (out (tag (div class "votearrow"           title "upvote")))
        (out (tag (div class "votearrow rotate180" title "downvote"))))))

; hn.js reads id/how/auth/goto from the vote link's href.

(def vote-url (i dir whence)
  (+ "vote?id=" i!id
     "&how=" dir
     (aif (me) (+ "&auth=" (auth-for it i!id)))
     "&goto=" (urlencode (string whence (if (begins whence "item")
                                            (string "#" i!id))))))

; Not much stricter than whether to generate the arrow.  Further tests 
; applied in vote-for.

(def canvote (i dir (o ignore-voted))
  (and (me)
       (news-type&live i)
       (or ignore-voted (~voted i!id))
       (or (is dir 'up)
           (and (acomment i)
                (> (karma) downvote-threshold*)
                (no (aand i!parent (author (item it))))))))

; Need the by argument or someone could trick logged in users into 
; voting something up by clicking on a link.  But a bad guy doesn't 
; know how to generate an auth arg that matches each user's cookie.

(newsopr vote (id how auth goto)
  (with (i      (safe-item id)
         how    (saferead how)
         whence (safe-goto goto))
    (if (no i)
         (flink {pr "No such item."})
        (no (in how 'up 'down 'un))
         (flink {pr "Can't make that vote."})
        (no user)
         (flink
           {login-page 'both "You have to be logged in to vote."
                       (list {do (newslog 'vote-login)
                                 (when (canvote i how)
                                   (vote-for i how)
                                   (logvote i))}
                             whence)})
        (~good-auth user i!id auth)
         (flink {pr "User mismatch."})
        (is how 'un)
         (do (unvote-for i)
             (logvote i)
             whence)
        (canvote i how)
         (do (vote-for i how)
             (logvote i)
             whence)
         (flink {pr "Can't make that vote."}))))


; Hiding.

; Lets a logged-in user remove items from their own listings without
; affecting anyone else.  The hidden ids live in the user's profile.

(def hidden (i (t user me))
  (and user (mem i!id (uvar user hidden))))

(def hide-item (i)
  (pushnew i!id my!hidden)
  (save-prof))

(def unhide-item (i)
  (pull i!id my!hidden)
  (save-prof))

(def hide-url (i un whence)
  (+ "hide?id=" i!id
     (if un "&un=t")
     (aif (me) (+ "&auth=" (auth-for it i!id)))
     "&goto=" (urlencode whence)))

(def hidelink (i whence)
  (when (and (me) (news-type i))
    (pr bar*)
    (with (label "@(if (hidden i) 'un-)hide"
           url (hide-url i (hidden i) whence))
      (if (in (op) "" "news" "newest")
          (clickylink label url "clicky hider" nil)
          (link label url)))))

(newsopr hide (id un auth goto)
  (when (good-auth user id)
    (whenlet i (safe-item id)
      (if (blank un)
          (hide-item i)
          (unhide-item i))))
  (safe-goto goto))

(newsopg hidden (id)
  (let subject (check id ~blank&goodname)
    (if (and subject (~me subject) (~admin))
        (pr "Can't display that.")
        (listpage (msec)
                  (only&hidden-items subject)
                  "hidden" "Hidden submissions"
                  (nexturl (hidden-url subject)) t
                  [nexturl (hidden-url subject) _
                           (+ (cur-n) perpage*)]))))

(def hidden-url ((t user me))
  (string "hidden" (if user "?id=") user))

(def hidden-items ((t user me))
  (rem no (map item (uvar user hidden))))


; snip-story backs the JS "hide" on listing pages (see hidestory /
; newstory in hn.js).  It hides the item, like the hide op, then returns
; a 2-element JSON array [html next] so the page can drop the hidden row
; and pull in one more item from the bottom: html is the rendered next
; story and next is the id of the story after it, for the morelink's
; cursor.  The link is the hide link with hide->snip-story, goto->onop.

(newsop snip-story (id auth onop next)
  (awhen (safe-item id)
    (when (and user (good-auth user it!id auth))
      (hide-item it)))
  (to-json (snip-pair onop next)))

; /newest is ordered by id, so hn.js sends a next= item id: render the
; first visible story at/after it and return the id after that for the
; morelink's cursor.  /news (and root /) is ranked and shows the top
; perpage*; hn.js sends no cursor there, so once the item is hidden the
; story that refills the bottom is simply the one now at perpage*-1.  No
; new cursor is needed (the page-based morelink stays valid).

(def snip-pair (onop next)
  ; onop is the listing's whence; on a paginated page it carries a query
  ; string (e.g. "newest?next=12&n=3"), so match newest on its base op.
  ; newest is cursor-based, so it refills on any page.  The front page is
  ; page-based, so only its first page (exact "news"/"") can be refilled;
  ; deeper pages match nothing and safely no-op.
  (if (is (only&car:tokens onop #\?) "newest")
       (w/the op "newest"
         (whenlet n (safe-id next)
           (whenlet tail (keep [<= _!id n] (newstories maxend*))
             (list (tostring (display-item 1 (car tail) onop t))
                   (aand (cadr tail) it!id)))))
      (in onop "news" "")
       (w/the op onop
         (whenlet s ((topstories maxend*) (- perpage* 1))
           (list (tostring (display-item 1 s onop t)) nil)))))


(def cansee-score (i)
  (or (isnt i!type 'comment)
      (author i)
      (admin)))

(def itemline (i (o whence))
  (when (cansee-score i)
    (itemscore i)
    (pr " by "))
  (byline i whence))

(def itemscore (i)
  (tag (span class 'score id (+ "score_" i!id))
    (pr (plural (scoreof i) "point")))
  (hook 'itemscore i))

(def scoreof (i)
  (if (is i!type 'pollopt) (realscore i) i!score))

; redefined later

(def byline (i (o whence))
  (if (cansee i) (userlink (by i)))
  (pr " ")
  (agelink i)
  (pr " ")
  (unvotelink i whence))

(def user-url (user) (+ "user?id=" user))

(= show-avg* nil)

(def userlink (user (o show-avg t) (o show-noob t) (o id))
  (tag (a href (user-url user) class 'hnuser id id)
    (user-name user show-noob))
  (awhen (and show-avg* (admin) show-avg (uvar user avg))
    (pr " (@(num it 1 t t))")))

(def text-time (secs)
  (let (Y M D h m s) (map zeropad (rev:timedate secs))
    (+ "" Y "-" M "-" D "T" h ":" m ":" s " " secs)))

(def agelink (i)
  (tag (span class "age" title (text-time i!time))
    (link (text-age:item-age i) (item-url i!id))))

(def unvotelink (i (o whence))
  ; hn.js injects the "unvote" link here after a live vote; render it
  ; server-side too when the user has already voted, so it persists
  ; across refreshes.
  (tag (span id (string "unv_" i!id))
    ; not (author i): you auto-upvote your own items but can't unvote them
    (whenlet vote (and (me) (~author i) (voted i))
      (pr bar*)
      (tag (a id    (string "un_" i!id)
              class 'clicky
              href  (vote-url i 'un (or whence "news")))
        (pr (if (is vote!3 'up) "unvote" "undown"))))))

(= noob-color* (color 60 150 60))

(def user-name (user (o show-noob t))
  (if (and (editor) (ignored user))
       (fontcolor darkred (pr user))
      (and (admin) (admin user))
       (fontcolor darkblue (pr user))
      (and (admin|member) (member&~me user))
       (fontcolor orange (pr user))
      (and show-noob (me) (noob user))
       (fontcolor noob-color* (pr user))
       (pr user)))

(= show-threadavg* nil)

(def commentlink (i)
  (when (cansee i)
    (pr bar*)
    (tag (a href (item-url i!id))
      (let n (w/loading-items (- (visible-family i) 1))
        (if (> n 0)
            (do (pr (plural n "comment"))
                (awhen (and show-threadavg* (admin user) (threadavg i))
                  (pr " (@(num it 1 t t))")))
            (pr "discuss"))))))

(def visible-family (i (t user me))
  (+ (if (deleted i) 0 (~cansee i user) 0 1)
     (sum [visible-family _ user] (kids i))))

(def threadavg (i)
  (only&avg (map [or (uvar _ avg) 1] 
                 (rem admin (dedup (map by (keep live (family i))))))))

(= user-changetime* 120 editor-changetime* 1440)

(or= everchange* (table) noedit* (table))

(def canedit (i (t user me))
  (or (admin user)
      (and (~noedit* i!type)
           (editor user)
           (< (item-age i) editor-changetime*))
      (own-changeable-item i user)))

(def own-changeable-item (i (t user me))
  (and (author i user)
       (~mem 'locked i!keys)
       (~deleted i)
       (or (everchange* i!type)
           (< (item-age i) user-changetime*))))

(def editlink (i)
  (when (canedit i)
    (pr bar*)
    (link "edit" (edit-url i))))

(def favelink (i)
  (when (or (and (is (op) "item") (is arg!id (string i!id)))
            (and (is (op) "favorites") (me) (is arg!id (me))))
    (pr bar*)
    (let un (and (me) (mem i!id my!favorites))
      (link "@(if un 'un-)favorite"
            (fave-url i!id (auth-for (or (me) "") i!id) un)))))

(def addoptlink (p)
  (when (or (admin) (author p))
    (pr bar*)
    (onlink "add choice" (add-pollopt-page p))))

; reset later

(= flag-threshold* 0 flag-kill-threshold* 0 many-flags* 0)

; Un-flagging something doesn't unkill it, if it's now no longer
; over flag-kill-threshold.  Ok, since arbitrary threshold anyway.

(def flaglink (i whence)
  (when (and (me)
             (or (admin) (~author i))
             (or (admin) (> (karma) flag-threshold*)))
    (pr bar*)
    (w/rlink (do (if (admin)
                     (togglemem 'flagged i!keys)
                     (togglemem (me) i!flags))
                 (save-item i)
                 (when (and (~admin)
                            (~mem 'nokill i!keys)
                            (len> i!flags flag-kill-threshold*)
                            (< (realscore i) 10)
                            (~user-voted-for i admin))
                   (pushnew 'flagged i!keys)
                   (kill i 'flags))
                 whence)
      (let flag (if (admin) (flagged i) (mem (me) i!flags))
        (pr "@(if flag 'un)flag")))
    (when (and (admin) (len> i!flags many-flags*))
      (pr bar* (plural (len i!flags) "flag") " ")
      (w/rlink (do (togglemem 'nokill i!keys)
                   (save-item i)
                   whence)
        (pr (if (mem 'nokill i!keys) "un-notice" "noted"))))))

(def user-voted-for (i test)
  (find test:uid->user*:!2 i!votes))

(def announcelink (i whence)
  (when (editor)
    (pr bar*)
    (w/rlink (do (zap no (announcement i))
                 (save-item i)
                 whence)
      (pr "@(if (announcement i) 'un-)announce"))))

(def killlink (i whence)
  (when (admin)
    (pr bar*)
    (w/rlink (do (zap no (dead i))
                 (= (mem 'nokill i!keys) (~dead i))
                 (dead&log-kill i)
                 (save-item i)
                 whence)
      (pr "@(if (dead i) 'un)kill"))))

; "allow links" turns on clickable urls in story text.

(def nolinks (s)
  (~mem 'links s!keys))

(def linkslink (i whence)
  (when (admin)
    (pr bar*)
    (w/rlink (do (togglemem 'links i!keys)
                 (let md (unmarkdown i!text)
                   (= i!text (md-from-form md (nolinks i))))
                 (save-item i)
                 whence)
      (pr "@(if (nolinks i) 'allow 'disable) links"))))

; Blast kills the submission and bans the user.  Nuke also bans the 
; site, so that all future submitters will be ignored.  Does not ban 
; the ip address, but that will eventually get banned by maybe-ban-ip.

(def blastlink (i whence (o nuke))
  (when (and (admin) 
             (or (no nuke) (~empty i!url)))
    (pr bar*)
    (w/rlink (do (toggle-blast i nuke)
                 whence)
      (prt (if (ignored (by i)) "un-") (if nuke "nuke" "blast")))))

(def toggle-blast (i (o nuke))
  (atomic
    (if (ignored (by i))
        (do (wipe (dead i) (ignored (by i)))
            (awhen (and nuke (sitename i!url))
              (set-site-ban it nil)))
        (do (set (dead i))
            (ignore (by i) (if nuke 'nuke 'blast))
            (awhen (and nuke (sitename i!url))
              (set-site-ban it 'ignore))))
    (if (dead i) (log-kill i))
    (save-item i)
    (save-prof (by i))))

(def candelete (i (t user me))
  (or (admin user) (own-changeable-item i user)))

(def deletelink (i whence)
  (when (candelete i)
    (pr bar*)
    (link "@(if (deleted i) 'un)delete"
          (delete-url i!id whence))))

(def delete-url (id (o whence arg!goto))
  (string "delete-confirm?id=" (urlencode:string id)
          (if whence (string "&goto=" (urlencode whence)))))

(newsop delete-confirm (id goto)
  (let i (safe-item id)
    (if (only&candelete i)
        (del-confirm-page i goto)
        (prn "You can't delete that."))))

; Undeleting stories could cause a slight inconsistency. If a story
; linking to x gets deleted, another submission can take its place in
; url->story.  If the original is then undeleted, there will be two 
; stories with equal claim to be in url->story.  (The more recent will
; win because it happens to get loaded later.)  Not a big problem.

(def del-confirm-page (i whence)
  (minipage "Confirm"
    (tab
      (display-item nil i (delete-url i!id whence))
      (spacerow 20)
      (tr (td)
          (td (item-form "xdelete" i!id whence
                (prn "Do you want this to @(if (deleted i) 'stay 'be) deleted?")
                (br2)
                (but "Yes" "d") (sp) (but "No" "d")))))))

(newsopr xdelete (id goto d)
  (when (good-auth user id)
    (whenlet i (safe-item id)
      (= (deleted i) (is d "Yes"))
      (save-item i)))
  (safe-goto goto))

(def logvote (story)
  (newslog 'vote (story 'id) (list (story 'title))))

(def text-date (secs)
  (let (Y M D h m s) (rev:timedate secs)
    (let M (case M
             1 "Jan"   2 "Feb"  3 "March"
             4 "April" 5 "May"  6 "June"
             7 "July"  8 "Aug"  9 "Sept"
             10 "Oct"  11 "Nov" 12 "Dec"
             (err "Bad month number"))
      (tostring (pr M " " D ", " Y)))))

(def text-age (a)
  (tostring
    (if (>= a 525600) (pr "on " (text-date:since (* a 60)))
        (>= a 1440)   (pr (plural (trunc (/ a 1440)) "day")    " ago")
        (>= a   60)   (pr (plural (trunc (/ a 60))   "hour")   " ago")
                      (pr (plural (trunc a)          "minute") " ago"))))


; Voting

; A user needs legit-threshold karma for a vote to count if there has 
; already been a vote from the same IP address.  A new account below both
; new- thresholds won't affect rankings, though such votes still affect 
; scores unless not a legit-user.

(= legit-threshold* 0 new-age-threshold* 0 new-karma-threshold* 2)

(def legit-user ((t user me))
  (or (editor user)
      (> (karma user) legit-threshold*)))

(def possible-sockpuppet ((t user me))
  (or (ignored user)
      (< (uvar user weight) .5)
      (and (< (user-age user) new-age-threshold*)
           (< (karma user) new-karma-threshold*))))

(= downvote-ratio-limit* .65 votewindow* 100)

(or= recent-votes* nil)

(def votable (i)
  (and (~voted i) (live|author i)))

; Note: if vote-for by one user changes (s 'score) while s is being
; edited by another, the save after the edit will overwrite the change.
; Actual votes can't be lost because that field is not editable.  Not a
; big enough problem to drag in locking.

(def vote-for (i (o dir 'up))
  (when (votable i)
    (withs (ip   (logins* (me))
            vote (list (seconds) ip (user-id) dir i!score nil)
            effect (fn (name n) (push (list name n) vote!5) n))
      (unless (or (and (or (ignored) check-key!novote)
                       (~author i))
                  (and (is dir 'down)
                       (~editor)
                       (or check-key!nodowns
                           (> (downvote-ratio) downvote-ratio-limit*)
                           ; prevention of karma-bombing
                           (just-downvoted (by i))))
                  (and (~legit-user)
                       (~author i)
                       (find [is _!1 ip] i!votes))
                  (and (isnt i!type 'pollopt)
                       (biased-voter i vote)))
        (++ i!score (effect 'score (case dir up 1 down -1)))
        ; canvote protects against sockpuppet downvote of comments 
        (when (and (is dir 'up) (possible-sockpuppet))
          (++ i!sockvotes (effect 'sockvotes 1)))
        (metastory&adjust-rank i)
        (unless (or (author i)
                    (and (is ip i!ip) (~editor))
                    (is i!type 'pollopt))
          (++ (karma (by i)) (effect 'karma (case dir up 1 down -1)))
          (save-prof (by i)))
        (uncache-comment i!id))
      (if (admin) (pushnew 'nokill i!keys))
      (push vote i!votes)
      (save-item i)
      (let pvote (list (seconds) i!id (user-id) (sitename i!url) dir)
        (push pvote my!votes))
      (= (voted i) vote)
      (save-votes)
      (zap [firstn votewindow* _] my!votes)
      (save-prof)
      (push (cons i!id vote) recent-votes*))))

; Inverse of vote-for: undo the current user's vote on i.
; hn.js sends how=un.

(def unvote-for (i)
  (whenlet vote (voted i)
    (each (name n) (errsafe vote!5) ; legacy votes don't have effects
      (case name
        score     (-- i!score n)
        sockvotes (-- i!sockvotes n)
        karma     (do (-- (karma (by i)) n)
                      (save-prof (by i)))
        (err "Unknown vote-for effect name @name")))
    (metastory&adjust-rank i)
    (pull [is _!2 (user-id)] i!votes)
    (save-item i)
    (wipe (voted i))
    (save-votes)
    (pull [is _!1 i!id] my!votes)
    (save-prof)
    (uncache-comment i!id)))

; redefined later

(def biased-voter (i vote) nil)

; ugly to access vote fields by position number

(def downvote-ratio ((o sample 20))
  (ratio [is _!1!3 'down]
         (keep [let u (by (item _!0))
                 (no (me|ignored u))]
               (bestn sample (compare > car:cadr) (tablist (votes))))))

(def just-downvoted (victim (o n 3))
  (let prev (firstn n (recent-votes-by))
    (and (is (len prev) n)
         (all (fn ((id sec ip voter dir score))
                (and (author (item id) victim) (is dir 'down)))
              prev))))

; Ugly to pluck out fourth element.  Should read votes into a vote
; template.  They're stored slightly differently in two diff places: 
; in one with the voter in the car and the other without.

(def recent-votes-by ((t user me))
  (keep [is _!3 (user-id user)] recent-votes*))


; Story Submission

(newsop submit ()
  (if user
      (submit-page)
      (submit-login-warning)))

(def submit-login-warning ((o url "") (o title "") (o text ""))
  (login-page 'both "You have to be logged in to submit."
              {do (newslog 'submit-login)
                  (submit-page url title text)}))

(def submit-page ((o url "") (o title "") (o text "") (o msg))
  (minipage "Submit"
    (pagemessage msg)
    (urform (process-story arg!url arg!title arg!text)
      (tab
        (row "title"  (input "title" title 50))
        (row "url"    (input "url" url 50))
        (row "text"   (textarea "text" 4 50 (only&pr text)))
        (row ""       (submit))
        (spacerow 20)
        (row "" submit-instructions*)))))

(= submit-instructions*
   "Leave url blank to submit a question for discussion. If there is
   no url, text will appear at the top of the thread. If there is a
   url, text is optional.")

; For use by outside code like bookmarklet.
; http://news.domain.com/submitlink?u=http://foo.com&t=Foo
; Added a confirm step to avoid xss hacks.

(newsop submitlink (url title text)
  (if user
      (submit-page url title text)
      (submit-login-warning url title text)))

(= title-limit* 80
   retry*       "Please try again."
   toolong*     "Please make title < @title-limit* characters."
   toofast*     "You're submitting too fast.  Please slow down.  Thanks."
   spammage*    "Stop spamming us.  You're wasting your time.")

; Only for annoyingly high-volume spammers. For ordinary spammers it's
; enough to ban their sites and ip addresses.

(disktable big-spamsites* (+ newsdir* "big-spamsites"))

(def process-story (url title text)
  (aif (and (~blank url) (live-story-w/url url))
       (do (vote-for it)
           (item-url it!id))
       (if (no (me))
            (flink {submit-login-warning url title text})
           (no (and (blank|valid-url url)
                    (~blank title)))
            (flink {submit-page url title text retry*})
           (unless (admin) (len> title title-limit*))
            (flink {submit-page url title text toolong*})
           ; could also match (recent-spam:sitename url)
           (big-spamsites*:sitename url)
            (flink {msgpage spammage*})
           (oversubmitting 'story url)
            (flink {msgpage toofast*})
           (withs (septext (and (~blank url) (~blank text))
                   s (create-story url (process-title title)
                                   (unless septext text))
                   c (if septext (create-comment s text)))
             (story-ban-test s url)
             (when (ignored (me)) (kill s 'ignored))
             (submit-item s)
             (when c (submit-item c))
             (maybe-ban-ip s)
             "newest"))))

(def submit-item (i)
  (push i!id my!submitted)
  (save-prof)
  (vote-for i))

(def recent-spam (site)
  (and (caris (banned-sites* site) 'ignore)
       (recent-items [is (sitename _!url) site] 720)))

(def recent-items (test minutes)
  (let cutoff (- (seconds) (* 60 minutes))
    (latest-items test [< _!time cutoff])))

; Turn this on when spam becomes a problem.

(= enforce-oversubmit* nil)

; New user can't submit more than 2 stories in a 2 hour period.
; Give overeager users the key toofast to make limit permanent.

(def oversubmitting (kind (o url))
  (and enforce-oversubmit*
       (or check-key!toofast
           (ignored)
           (< (user-age) new-age-threshold*)
           (< (karma) new-karma-threshold*))
       (len> (recent-items [or (author _) (is _!ip (ip))] 180)
             (if (is kind 'story)
                 (if (bad-user) 0 1)
                 (if (bad-user) 1 10)))))

; Note that by deliberate tricks, someone could submit a story with a 
; blank title.

(diskvar scrubrules* (+ newsdir* "scrubrules"))

(def process-title (s)
  (lets s2 (multisubst scrubrules* s)
    (zap upcase (s2 0))))

(def live-story-w/url (url) 
  (aand (url->story* (canonical-url url)) (check (item it) live)))

(load "sitename.arc")

(def create-story (url title text)
  (newslog 'create url (list title))
  (lets s (inst 'item 'type 'story 'id (new-item-id)
                      'url url 'title title
                      'text (only&md-from-form text t)
                      'by (user-id) 'ip (ip))
    (save-item s)
    (= (items* s!id) s)
    (register-story s)
    (push s stories*)))

(def register-story (s (o url s!url) (o site (sitename url)))
  (unless (blank url)
    (register-url s url)
    (process-url s url site)
    (save-site-items)))

(def register-comment (c text)
  (awhen (urls text)
    (each url it (process-url c url))
    (save-site-items)))

(def process-url (i (o url i!url) (o site (sitename url)))
  (when site
    (put-site-item i site)
    ; for e.g. "github.com/antirez", also register "github.com"
    (aif (root-site site) (put-site-item i it))))

(def root-site (site) (aif (pos #\/ site) (cut site 0 it)))

(disktable sitename->items* (+ newsdir* "sitename-items"))

(def save-site-items () (todisk sitename->items*))

(def put-site-item (i (o site (sitename i!url)))
  (if site (insortnew > i!id (sitename->items* site))))


; Bans

; user is the user being ignored. actor is who's doing the
; ignoring; defaults to (the me) for interactive ignores, but
; site-ban-test / comment-ban-test pass nil to record a system
; action with no human actor.
(def ignore (user cause (t actor me))
  (set (ignored user))
  (save-prof user)
  (log-ignore user cause actor))

(diskvar ignore-log* (+ newsdir* "ignore-log"))

(def log-ignore (user cause (t actor me))
  (todisk ignore-log* (cons (list user actor cause) ignore-log*)))

; Kill means stuff with this substring gets killed. Ignore is stronger,
; means that user will be auto-ignored.  Eventually this info should
; be stored on disk and not in the source code.

(disktable banned-ips*     (+ newsdir* "banned-ips"))   ; was ips
(disktable banned-sites*   (+ newsdir* "banned-sites")) ; was sites

(diskvar  comment-kill*    (+ newsdir* "comment-kill"))
(diskvar  comment-ignore*  (+ newsdir* "comment-ignore"))

(= ip-ban-threshold* 3)

(def set-ip-ban (ip yesno (o info) (t actor me))
  (= (banned-ips* ip) (and yesno (list actor (seconds) info)))
  (todisk banned-ips*))

(def set-site-ban (site ban (o info) (t actor me))
  (= (banned-sites* site) (and ban (list ban actor (seconds) info)))
  (todisk banned-sites*))

; Kill submissions from banned ips, but don't auto-ignore users from
; them, because eventually ips will become legit again.

; Note that ban tests are only applied when a link or comment is
; submitted, not each time it's edited.  This will do for now.

(def story-ban-test (i url)
  (site-ban-test i url)
  (ip-ban-test i)
  (hook 'story-ban-test i url))

(def site-ban-test (i url)
  (whenlet ban (banned-sites* (sitename url))
    (if (caris ban 'ignore) (ignore (me) 'site-ban nil))
    (kill i 'site-ban)))

(def ip-ban-test (i)
  (if (banned-ips* (ip)) (kill i 'banned-ip)))

(def comment-ban-test (i string kill-list ignore-list (t user me))
  (when (some [posmatch _ string] ignore-list)
    (ignore user 'comment-ban nil))
  (when (or (banned-ips* (ip)) (some [posmatch _ string] kill-list))
    (kill i 'comment-ban)))

; An IP is banned when multiple ignored users have submitted over
; ban-threshold* (currently loaded) dead stories from it.  

; Can consider comments too if that later starts to be a problem,
; but the threshold may start to be higher because then you'd be
; dealing with trolls rather than spammers.

(def should-ban-ip (s)
  (when (and (dead s) (ignored (by s)))
    (let bads (loaded-items (andf dead&astory [same-ip _ s]))
      (and (len> bads ip-ban-threshold*)
           (some [and (ignored:by _) (~same-author _ s)] bads)))))

(def maybe-ban-ip (s)
  (if (should-ban-ip s) (set-ip-ban s!ip t nil nil)))

(def killallby (user) 
  (map [kill _ 'all] (submissions user)))

; Only called from repl.

(def kill-whole-thread (c)
  (kill c 'thread)
  (map0 kill-whole-thread (kids c)))


; Polls

; a way to add a karma threshold for voting in a poll
;  or better still an arbitrary test fn, or at least pair of name/threshold.
; option to sort the elements of a poll when displaying
; exclusive field? (means only allow one vote per poll)

(= poll-threshold* 1)

(newsop newpoll ()
  (if (and user (>= (karma user) poll-threshold*))
      (newpoll-page)
      (pr "Sorry, you need @poll-threshold* karma to create a poll.")))

(def newpoll-page ((o title "Poll: ") (o text "") (o opts "") (o msg))
  (minipage "New Poll"
    (pagemessage msg)
    (urform (process-poll arg!title
                          (md-from-form arg!text t)
                          arg!choices)
      (tab
        (row "title"   (input "title" title 50))
        (row "text"    (textarea "text" 4 50 (only&pr text)))
        (row ""        "Use blank lines to separate choices:")
        (row "choices" (textarea "choices" 7 50 (only&pr opts)))
        (row ""        (submit))))))

(= fewopts* "A poll must have at least two options.")

(def process-poll (title text opts)
  (if (or (blank title) (blank opts))
       (flink {newpoll-page title text opts retry*})
      (len> title title-limit*)
       (flink {newpoll-page title text opts toolong*})
      (len< (paras opts) 2)
       (flink {newpoll-page title text opts fewopts*})
      (atlet p (create-poll (multisubst scrubrules* title) text opts)
        (ip-ban-test p)
        (when (ignored) (kill p 'ignored))
        (submit-item p)
        (maybe-ban-ip p)
        "newest")))

(def create-poll (title text opts)
  (newslog 'create-poll title)
  (lets p (inst 'item 'type 'poll 'id (new-item-id)
                      'title title 'text text
                      'by (user-id) 'ip (ip))
    (= p!parts (map !id (map [create-pollopt p nil nil _]
                             (paras opts))))
    (save-item p)
    (= (items* p!id) p)
    (push p stories*)))

(def create-pollopt (p url title text)
  (lets o (inst 'item 'type 'pollopt 'id (new-item-id)
                      'url url 'title title 'text text 'parent p!id
                      'by (user-id) 'ip (ip))
    (save-item o)
    (= (items* o!id) o)
    (vote-for o)))

(def add-pollopt-page (p)
  (minipage "Add Poll Choice"
    (urform (do (add-pollopt p arg!x)
                (item-url p!id))
      (tab
        (row "text" (textarea "x" 4 50))
        (row ""     (submit))))))

(def add-pollopt (p text)
  (unless (blank text)
    (atlet o (create-pollopt p nil nil text)
      (++ p!parts (list o!id))
      (save-item p))))

(def display-pollopts (p whence)
  (each o (visible (map item p!parts))
    (display-pollopt nil o whence)
    (spacerow 7)))

(def display-pollopt (n o whence)
  (tag (tr class 'athing id o!id)
    (display-item-number n)
    (tag (td valign 'top class 'votelinks)
      (votelinks o whence))
    (tag (td class 'comment)
      (tag (div style "margin-top:1px;margin-bottom:0px")
        (if (~cansee o) (pr (pseudo-text o))
            (~live o)        (spanclass cdd
                               (presc (if (~blank o!title) o!title o!text)))
                             (if (and (~blank o!title) (~blank o!url))
                                 (link o!title o!url)
                                 (fontcolor black (presc o!text)))))))
  (tr (if n (td))
      (td)
      (tag (td class 'default)
        (spanclass comhead
          (itemscore o)
          (unvotelink o whence)
          (editlink o)
          (let whenceid (string whence "#" o!id)
            (killlink o whenceid)
            (deletelink o whenceid))
          (deadmark o)))))


; Individual Item Page (= Comments Page of Stories)

(defmemo item-url (id (o anchor))
  (string (if id "item?id=") id (if anchor "#") anchor))

(newsop item (id)
  (let s (safe-item id)
    (if (news-type s)
        (do (if (deleted s) (note-baditem))
            (item-page s))
        (do (note-baditem)
            (pr "No such item.")))))

(newsopr item.json (id)
  (responding type-header*!json (prn)
    (prjson:item-api id)))

(def item-api (id)
  (w/me nil
    (whenlet i (safe-item id)
      (let del (deleted i)
        (when (news-type i)
          (obj by          (unless del (by i))
               dead        (unless del (~live i))
               deleted     del
               descendants (unless del
                             (if (in i!type 'story 'poll)
                               (- (visible-family i) 1)))
               id          i!id
               kids        (unless del (map !id (keep cansee (ranked-kids i))))
               parent      (if (~in i!type 'pollopt) i!parent)
               parts       (unless del (keep cansee:item i!parts))
               poll        (if (in i!type 'pollopt) i!parent)
               score       (unless del (if (cansee-score i) (scoreof i)))
               text        (unless del (check i!text ~empty))
               time        i!time
               title       (unless del (check i!title ~empty))
               type        i!type
               url         (unless del (check i!url ~empty))))))))

(or= baditemreqs* (table))

(= baditem-threshold* 1/100)

; Something looking at a lot of deleted items is probably the bad sort
; of crawler.  Throttle it for this server invocation.

(def note-baditem ()
  (unless (admin)
    (++ (baditemreqs* (ip) 0))
    (with (r (requests/ip* (ip)) b (baditemreqs* (ip)))
       (when (and (> r 500) (> (/ b r) baditem-threshold*))
         (set (throttle-ips* (ip)))))))

; redefined later

(def news-type (i) (and i (in i!type 'story 'comment 'poll 'pollopt)))

(def ranked-siblings (items)
  (sort (compare > (memo frontpage-rank)) items))

(def ranked-kids (i)
  (ranked-siblings:kids i))

(def item-page (i)
  (w/the-if story (if (metastory i) i)
    (with (title (and (cansee i)
                      (or i!title (aand i!text (ellipsize (striptags it)))))
           here (item-url i!id))
      (longpage (pagems) nil nil title here
        (tag (table class 'fatitem border 0)
          (display-item nil i here)
          (display-item-text i)
          (when (apoll i)
            (spacerow 10)
            (tr (td)
                (td (tab (display-pollopts i here)))))
          (when (and (cansee i) (comments-active i))
            (spacerow 10)
            (row "" (comment-form i here))))
        (br)
        (when (and i!kids (commentable i))
          (w/the comment-nav (comment-navs:ranked-kids i)
            (tag (table border 0 class 'comment-tree)
              (display-subcomments i here)))
          (br2))))))

(def commentable (i) (in i!type 'story 'comment 'poll))

; By default the ability to comment on an item is turned off after 
; 14 days, but this can be overriden with commentable key.

(= commentable-threshold* (* 60 24 14))

(def comments-active (i)
  ;(or (admin)
      (and (~announcement i)
           (live&commentable i)
           (live:superparent i)
           (or (< (item-age i) commentable-threshold*)
               (mem 'commentable i!keys))))


(or= displayfn* (table))

(= (displayfn* 'story)   (fn (n i here inlist)
                           (display-story n i here)))

(= (displayfn* 'comment) (fn (n i here inlist)
                           (display-comment n i here nil 0 t (no inlist))))

(= (displayfn* 'poll)    (displayfn* 'story))

(= (displayfn* 'pollopt) (fn (n i here inlist)
                           (display-pollopt n i here)))

(def display-item (n i here (o inlist))
  ((displayfn* (i 'type)) n i here inlist))

(def superparent (i)
  (aif i!parent (superparent:item it) i))

(def display-item-text (s)
  (when (metastory&cansee s)
    (unless (blank s!text)
      (spacerow 2)
      (row "" (tag (div class "toptext" style "margin-top:4px")
                (pr s!text))))))


; Edit Item

(def edit-url (i) (+ "edit?id=" i!id))

(newsop edit (id)
  (let i (safe-item id)
    (if (and (only&cansee&editable-type i)
             (or (admin) (news-type|author i)))
        (edit-page i)
        (pr "No such item."))))

(def editable-type (i) (fieldfn* i!type))

(or= fieldfn* (table))

(= (fieldfn* 'story)
   (fn (s)
     (with (a (admin)  e (editor)  x (canedit s)
            md (if (nolinks s) 'mdtext2 'mdtext))
       `((string1 title     ,s!title        t ,x)
         (url     url       ,s!url          t ,e)
         (,md     text      ,s!text         t ,x)
         ,@(standard-item-fields s a e x)))))

(= (fieldfn* 'comment)
   (fn (c)
     (with (a (admin)  e (editor)  x (canedit c))
       `((mdtext  text      ,c!text         t ,x)
         ,@(standard-item-fields c a e x)))))

(= (fieldfn* 'poll)
   (fn (p)
     (with (a (admin)  e (editor)  x (canedit p))
       `((string1 title     ,p!title        t ,x)
         (mdtext2 text      ,p!text         t ,x)
         ,@(standard-item-fields p a e x)))))

(= (fieldfn* 'pollopt)
   (fn (p)
     (with (a (admin)  e (editor)  x (canedit p))
       `((string  title     ,p!title        t ,x)
         (url     url       ,p!url          t ,x)
         (mdtext2 text      ,p!text         t ,x)
         ,@(standard-item-fields p a e x)))))

(def standard-item-fields (i a e x)
       `((int     votes     ,(len i!votes) ,a  nil)
         (int     score     ,i!score        t ,a)
         (int     sockvotes ,i!sockvotes   ,a ,a)
         (yesno   dead      ,(dead i)      ,e ,e)
         (yesno   deleted   ,(deleted i)   ,a ,a)
         (sexpr   flags     ,i!flags       ,a nil)
         (sexpr   keys      ,i!keys        ,a ,a)
         (string  ip        ,i!ip          ,e  nil)))

; Should check valid-url etc here too.  In fact make a fn that
; does everything that has to happen after submitting a story,
; and call it both there and here.

(def edit-page (i)
  (let here (edit-url i)
    (shortpage nil nil "Edit" here
      (tab (display-item nil i here)
           (display-item-text i))
      (br2)
      (vars-form ((fieldfn* i!type) i)
                 (fn (name val)
                   (unless (ignore-edit i name val)
                     (when (and (is name 'dead) val (~dead i))
                       (log-kill i))
                     (= (i name) val)
                     (when (and (is name 'text) (acomment i))
                       (register-comment i (unmarkdown val)))
                     (when (and (is name 'url) (metastory i))
                       (register-story i))))
                 {do (if (admin) (pushnew 'locked i!keys))
                     (save-item i)
                     (metastory&adjust-rank i)
                     (uncache-comment i!id)
                     here})
      (hook 'edit i))))

(def ignore-edit (i name val)
  (case name title (unless (admin) (len> val title-limit*))
             dead  (and (mem 'nokill i!keys) (~admin))))

 
; Comment Submission

(def comment-login-warning (parent whence (o text))
  (login-page 'both "You have to be logged in to comment."
              {do (ensure-news-user)
                  (newslog 'comment-login)
                  (addcomment-page parent whence text)}))

(def addcomment-page (parent whence (o text) (o msg))
  (minipage "Add Comment"
    (pagemessage msg)
    (tab
      (let here (flink {addcomment-page parent whence text msg})
        (display-item nil parent here))
      (spacerow 10)
      (row "" (comment-form parent whence text)))))

(= noob-comment-msg*
   "If you haven't already, would you mind reading about HN's
 @(tostring:underlink
    "approach to comments"
    "https://news.ycombinator.com/newswelcome.html")
 and
 @(tostring:underlink
    "site guidelines"
    "https://news.ycombinator.com/newsguidelines.html#comments")?")

; Comment forms last for 30 min (- cache time)

(def comment-form (parent whence (o text) (t user me))
  (tarform 1800
           (when-umatch/r user
             (process-comment parent arg!text whence))
    (textarea "text" 8 80
      (aif text (prn (unmarkdown it))))
    (formatdoc-link)
    (when (and noob-comment-msg* (noob user))
      (br2)
      (pr noob-comment-msg*))
    (br2)
    (submit (if (acomment parent) "reply" "add comment"))))

(= comment-threshold* -20)

; Have to remove #\returns because a form gives you back "a\r\nb"
; instead of just "a\nb".   Maybe should just remove returns from
; the vals coming in from any form, e.g. in aform.

(def process-comment (parent text whence)
  (aif (~me)
        (flink {comment-login-warning parent whence text})
       (empty text)
        (flink {addcomment-page parent whence text retry*})
       (oversubmitting 'comment)
        (flink {msgpage toofast*})
       (find-duplicate-comment parent (normalize-text text))
        (string whence "#" it!id)
        (atlet c (create-comment parent text)
          (comment-ban-test c text comment-kill* comment-ignore*)
          (if (bad-user) (kill c 'ignored/karma))
          (submit-item c)
          (string whence "#" c!parent))))

(def normalize-text (text)
  (unmarkdown (md-from-form text)))

(def find-duplicate-comment (parent text)
  (catch
    (each k parent!kids
      (whenlet i (item k)
        (when (and (me (by i)) (cansee i) (is (unmarkdown i!text) text))
          (throw i))))))

(def bad-user ((t u me))
  (or (ignored u) (< (karma u) comment-threshold*)))

(def create-comment (parent text)
  (newslog 'comment parent!id)
  (let c (inst 'item 'type 'comment 'id (new-item-id)
                     'text (md-from-form text) 'parent parent!id
                     'by (me) 'ip (ip))
    (save-item c)
    (= (items* c!id) c)
    (push c!id parent!kids)
    (save-item parent)
    (push c comments*)
    (register-comment c text)))

; Comment Display

; A comment is collapsed if an admin marks it as collapsed with the
; "collapse" link or the user collapsed it with the [-] button.

(def collapsed (c)
  (or (mem 'collapsed c!keys)
      (and (me) (mem c!id my!collapsed))))

; hn.js sends this on every [-]/[+] toggle (when logged in) so the choice
; persists across page loads.  Fire-and-forget: the response is ignored.

(newsop collapse (id un)
  (when (me)
    (whenlet c (safe-item id)
      (= (mem c!id my!collapsed) (no un))
      (save-prof))))

(def display-comments (cs whence (o indent 0) (o initialpar t) (o initialon t))
  (w/the comment-nav (comment-navs cs)
    (each c cs
      (display-comment-tree c whence indent initialpar initialon))))

; collhidden is true when an ancestor is collapsed, so this comment starts
; out hidden (noshow); its own collapsed state hides its body and descendants.

(def display-comment-tree (c whence (o indent 0) (o initialpar) (o initialon)
                                     (o collhidden))
  (when (cansee-descendant c)
    (display-1comment c whence indent initialpar initialon collhidden)
    (display-subcomments c whence (+ indent 1) (or collhidden (collapsed c)))))

(def display-1comment (c whence indent showpar showon (o collhidden))
  (tag (tr class (+ "athing comtr" (if (collapsed c) " coll" "")
                                   (if collhidden " noshow" ""))
           id c!id)
    (td (tab (display-comment nil c whence t indent showpar showon)))))

(def display-subcomments (c whence (o indent 0) (o collhidden))
  (each k (ranked-kids c)
    (display-comment-tree k whence indent (> indent 0) nil collhidden)))

(def display-comment (n c whence (o astree) (o indent 0)
                                 (o showpar) (o showon))
  (tr (display-item-number n)
      (when astree (tag (td class 'ind indent indent) (hspace (* indent 40))))
      (tag (td valign 'top class (+ "votelinks" (if (and astree (collapsed c))
                                                     " nosee" "")))
        (votelinks c whence t))
      (display-comment-body c whence astree indent showpar showon)))

; Comment caching doesn't make generation of comments significantly
; faster, but may speed up everything else by generating less garbage.

; It might solve the same problem more generally to make html code
; more efficient.

(or= comment-cache* (table) comment-cache-timeout* (table))

(= cc-window* 10000)

(or= comments-printed* 0 cc-hits* 0)

(= comment-caching* t) 

; Cache comments generated for nil user that are over a minute old.
; Only try to cache most recent 10k items.  But this window moves,
; so if server is running a long time could have more than that in
; cache.  Probably should actively gc expired cache entries.

(def display-comment-body (c whence astree indent showpar showon)
  (++ comments-printed*)
  (if (should-cache-comment c whence astree indent showpar showon)
      (pr (cached-comment-body c whence indent))
      (gen-comment-body c whence astree indent showpar showon)))

(def should-cache-comment (c whence astree indent showpar showon)
  ;(ero `(should-cache-comment ,c!id ,whence ,astree ,indent ,showpar ,showon))
  (and comment-caching*
       astree (no showpar) (no showon)
       (live c)
       (nor (admin) (editor) (author c))
       (~collapsed c) ; per-user state; don't bake into the shared cache
       ;(< (- maxid* c!id) cc-window*)
       (> (since c!time) 60))) ; was 3600

(def cached-comment-body (c whence indent)
  (or (and (> (or (comment-cache-timeout* c!id) 0) (seconds))
           (awhen (comment-cache* c!id)
             (++ cc-hits*)
             it))
      (= (comment-cache-timeout* c!id)
          (cc-timeout c!time)
         (comment-cache* c!id)
          (tostring (gen-comment-body c whence t indent nil nil)))))

(def uncache-comment (id)
  (wipe (comment-cache* id)))

; Cache for the remainder of the current minute, hour, or day.

(def cc-timeout (t0)
  (let age (since t0)
    (+ t0 (if (< age  3600) (cc-time age    60)
              (< age 86400) (cc-time age  3600)
                            (cc-time age 86400)))))

(def cc-time (age secs) (* (+ (trunc:/ age secs) 1) secs))

(def gen-comment-body (c whence astree indent showpar showon)
  (tag (td class 'default)
    (tag (div style "margin-top:2px; margin-bottom:-10px;")
      (spanclass comhead
        (itemline c whence)
        (deadmark c)
        (spanclass navs
          (when astree
            (rootlink c whence))
          (when (or (no astree) showpar)
            (parentlink c whence indent))
          (when (or (no astree) (headmatch "threads" whence))
            (unless (> indent 0)
              (contextlink c whence)))
          (when astree
            (prevlink c whence)
            (nextlink c whence))
          (editlink c)
          (favelink c)
          (let whenceid (if astree (string whence "#" c!id) whence)
            (when (and (is indent 0) (op "item"))
              (announcelink c whenceid))
            (killlink c whenceid)
            (blastlink c whenceid)
            (deletelink c whenceid)
            (unless (and (~admin) (or astree (~me)))
              (flaglink c whenceid))
            (when astree
              (collapsebutton c))
            (collapselink c whenceid))
          (spanclass onstory
            (when showon
              (pr " | on: ")
              (let s (superparent c)
                (link (ellipsize s!title 50) (item-url s!id))))))))
    (br)
    (tag (div class (+ "comment" (if (and astree (collapsed c)) " noshow" "")))
      (if (~cansee c)
          (pr (pseudo-text c))
          (tag (div class (string "commtext " (comment-class c)))
            (pr c!text)))
      (tag (div class 'reply)
        (when (and astree (cansee c))
          (para)
          (tag (font size 1)
            (if (and (~mem 'neutered c!keys)
                     (replyable c indent)
                     (comments-active c))
                (underline (replylink c whence)))))))))

; computes prev, next, root, and number of descendants for each
; comment.

(def comment-navs (tops)
  (lets nav (table)
    ((afn (sibs parent next-after root)
       (withs (vs   (keep cansee-descendant sibs) ; only the ones that render
               last (edge vs))
         (apply + 0 ; total of this sibling group
           (map (fn (j)
                  (let c (vs j)
                    (withs (prv (if (is j 0) parent ((vs (- j 1)) 'id))
                            nxt (if (>= j last) next-after ((vs (+ j 1)) 'id))
                            rt  (or root c!id) ; top-level: c is its own root
                            ; recurse: subtree's "next-after" is c's own next; root carries down
                            n   (+ 1 (self (ranked-kids c) c!id nxt rt))) ; 1 + descendants
                      (= (nav c!id) (obj root rt prev prv next nxt n n))
                      n))) ; this comment's subtree size
                (range 0 last)))))
     tops nil nil nil)))

(def cnav (c key (t comment-nav))
  (aand (comment-nav c!id) (it key)))

(def root-comment (c) (cnav c 'root))

(def prev-comment (c) (cnav c 'prev))

(def next-comment (c) (cnav c 'next))

(def clickylink (text (o url text) (o class 'clicky) (o aria-hidden t))
  (tag (a href url class class aria-hidden aria-hidden)
    (presc text)))

(def rootlink (c whence)
  (whenlet root (root-comment c)
    (unless (or (is root c!id)
                (is root c!parent))
      (when (cansee c) (pr bar*))
      (clickylink "root" (string whence "#" root)))))

(def parentlink (c whence (o indent 0))
  (pr bar*)
  (if (or (is indent 0) (is (string c!id) arg!id))
      (link "parent" (item-url c!parent))
      (clickylink "parent" (string whence "#" c!parent))))

(def contextlink (c whence)
  (whenlet s (superparent c)
    (pr bar*)
    (tag (a href (item-url s!id c!id)
            rel 'nofollow)
      (pr "context"))))

(def prevlink (c whence)
  (whenlet prev (prev-comment c)
    (unless (is prev c!parent)
      (pr bar*)
      (clickylink "prev" (string whence "#" prev)))))

(def nextlink (c whence)
  (whenlet next (next-comment c)
    (pr bar*)
    (clickylink "next" (string whence "#" next))))

(def collapsebutton (c)
  (pr " ")
  (tag (a class "togg clicky" id c!id n (cnav c 'n)
          href "javascript:void(0)")
    (pr (if (collapsed c) "[@(cnav c 'n) more]" "[–]"))))

; Admin-only: toggle whether this comment is collapsed by default for
; everyone.

(def collapselink (c whence)
  (when (admin)
    (pr bar*)
    (w/rlink (do (togglemem 'collapsed c!keys)
                 (save-item c)
                 whence)
      (pr "@(if (mem 'collapsed c!keys) 'un)collapse"))))

; For really deeply nested comments, caching could add another reply 
; delay, but that's ok.

; People could beat this by going to the link url or manually entering 
; the reply url, but deal with that if they do.

(= reply-decay* 1.8)   ; delays: (0 0 1 3 7 12 18 25 33 42 52 63)

(def replyable (c indent)
  (or (< indent 2)
      (> (item-age c) (expt (- indent 1) reply-decay*))))

(def replylink (i whence (o title 'reply))
  (link title (+ "reply?id=" i!id "&whence=" (urlencode whence))))

(newsop reply (id whence)
  (with (i      (safe-item id)
         whence (safe-goto whence))
    (if (only&comments-active i)
        (if user
            (addcomment-page i whence)
            (login-page 'both "You have to be logged in to comment."
                        {do (newslog 'comment-login)
                            (addcomment-page i whence)}))
        (pr "No such item."))))

(def comment-color (c)
  (if (> c!score 0) black (grayrange c!score)))

(defmemo grayrange (s)
  (gray (min 221 (round (expt (* (+ (abs s) 2) 900) .6)))))

; HN's commtext fade classes (in news.css): lightest text for the most
; downvoted, cdd for dead.

(def comment-class (c)
  (if (is arg!id (string c!id))
       "c00"
      (and (~live c) (~author c))
       "cdd"
      (gray-to-comment-class ((comment-color c) 'r))))

(def gray-to-comment-class (mono)
  (let x (as!string mono 16)
    (string "c" (if (len< x 2) "0") x)))

(defmemo score-from-comment-class ((o str "c00"))
  (let g (int (cut str 1) 16)
    (if (is g 0) 1
      (catch
        (for i -7 0
          (let c (int (cut (hexrep:grayrange i) 4) 16)
            (when (is g c)
              (throw i))))
        (assert nil "No such score for comment class @str")))))

; Threads

(def threads-url ((t user me))
  (string "threads?id=" user))

(newsop threads (id)
  (if id
      (threads-page id)
      (pr "No user specified.")))

(def threads-page (user)
  (if (profile user)
      (withs (title (+ user "'s comments")
              label (if (me user) "threads" title)
              here  (nexturl (threads-url user))
              moreurl [nexturl (threads-url user) _])
        (longpage (pagems) nil label title here
          (awhen (user-comments user)
            (let (start end numstart items) (paginate it threads-perpage*)
              (display-threads display-comments items label title here start end nil moreurl)))))
      (prn "No such user.")))

(def user-comments ((t user me))
  (keep cansee&~subcomment (comments user maxend*)))

(def display-threads (display comments label title whence
                      (o start 0) (o end threads-perpage*)
                      (o number) (o moreurl))
  (tab
    (display (cut comments start end) whence)
    (when end
      (let newend (+ end threads-perpage*)
        (when (and (aif maxend* (<= newend it) t)
                   (< end (len comments)))
          (spacerow 10)
          (row (tab (tr (td (hspace 0))
                        (td (hspace votewid*))
                        (tag (td class 'title)
                          (morelink display-threads
                                    display comments label title end newend
                                    number moreurl))))))))))

(def submissions ((t u me) (o n)) 
  (map item (firstn n (uvar u submitted))))

(def comments ((t u me) (o n))
  (keep acomment (submissions u n)))

(def stories ((t u me) (o n))
  (keep metastory (submissions u n)))
  
(def subcomment (c)
  (some [same-author _ c]
        (keep acomment&~deleted (ancestors c))))

(def ancestors (i)
  (accum a (trav i!parent a:item self:!parent:item)))


; Submitted

(def submitted-url (user) (+ "submitted?id=" user))
       
(newsop submitted (id)
  (if (only&profile id)
      (submitted-page id)
      (pr "No such user.")))

(def submitted-page (user)
  (if (profile user)
      (with (label (+ user "'s submissions")
             here  (submitted-url user))
        (longpage (pagems) nil label label here
          (aif (keep cansee (stories user))
               (display-items it label label here))))
      (pr "No such user.")))


; RSS

(newsop rss () (w/me nil (rsspage)))

(newscache rsspage () 90 
  (rss-stories (retrieve perpage* live ranked-stories*)))

(def rss-stories (stories)
  (tag (rss version "2.0")
    (tag channel
      (tag title (pr this-site*))
      (tag link (pr site-url*))
      (tag description (pr site-desc*))
      (each s stories
        (tag item
          (let comurl (+ site-url* "/" (item-url s!id))
            (tag title    (presc s!title))
            (tag link     (presc (if (blank s!url) comurl s!url)))
            (tag comments (presc comurl))
            (tag description
              (cdata (link "Comments" comurl)))))))))


; User Stats

(newsop leaders () (leaderspage))

(= nleaders* 20)

(newscache leaderspage () 1000
  (longpage (msec) nil "leaders" "Leaders" "leaders"
    (sptab
      (let i 0
        (each u (firstn nleaders* (leading-users))
          (tr (tdr:pr (++ i) ".")
              (td (userlink u nil))
              (tdr:pr (karma u))
              (when (admin)
                (tdr:prt (only&num (uvar u avg) 2 t t))))
          (if (is i 10) (spacerow 30)))))))

(= leader-threshold* 1)  ; redefined later

(def leading-users ()
  (sort (compare > [karma _])
        (users [and (> (karma _) leader-threshold*) (~admin _)])))

(adop editors ()
  (tab (each u (users [is (uvar _ auth) 1])
         (row (userlink u)))))

(adop users ()
  (paginated display-user (userlist) "users" "New Users"
             (pageurl "users") t
             [pageurl "users" (+ (curpage) 1)]
             5000))

(def display-user (n u whence)
  (prrow (lookup-uid u)
         (hspace 5)
         (len (keep metastory (submissions u)))
         (hspace 10)
         (len:comments u)
         (hspace 5)
         (userlink u)
         (text-age:user-age u))
  (spacerow 5))

(defcache userlist 45
  (sort (compare > lookup-uid) (users)))


(= update-avg-threshold* 0)  ; redefined later

(defbg update-avg 45
  (unless (or (empty profs*) (no stories*))
    (only&update-avg (update-avg-user))))

(def update-avg (user)
  (= (uvar user avg) (comment-score user))
  (save-prof user))

(def update-avg-user ()
  (rand-user [and (only&> (car (uvar _ submitted)) 
                          (- maxid* initload*))
                  (only&len> (uvar _ submitted) 
                             update-avg-threshold*)]))

(def rand-user ((o test idfn))
  (rand-elt (loaded-users test)))

; Ignore the most recent 5 comments since they may still be gaining votes.  
; Also ignore the highest-scoring comment, since possibly a fluff outlier.

(def comment-score (user)
  (aif (check (nthcdr 5 (comments user 50)) [len> _ 10])
       (avg (cdr (sort > (map !score (rem deleted it)))))
       nil))


; Comment Analysis

; Instead of a separate active op, should probably display this info 
; implicitly by e.g. changing color of commentlink or by showing the 
; no of comments since that user last looked.

(newsop active () (active-page))

(newscache active-page () 600
  (listpage (msec) (actives) "active" "Active Threads"
            (pageurl "active") t
            [pageurl "active" (+ (curpage) 1)]))

(def actives ((o n maxend*) (o consider 2000))
  (rank-stories n consider (memo active-rank) shown))

(= active-threshold* 1500)

(def active-rank (s)
  (sum [max 0 (- active-threshold* (item-age _))]
       (cdr (family s))))

(def family (i) (cons i (mappend family:item i!kids)))


(newsop newcomments () (newcomments-page))

(newscache newcomments-page () 60
  (listpage (msec) (visible (firstn maxend* comments*))
            "comments" "New Comments"
            (pageurl "newcomments") nil
            [pageurl "newcomments" (+ (curpage) 1)]))


; Doc

(defop formatdoc
  (msgpage formatdoc* "Formatting Options"))

(= formatdoc-url* "formatdoc")

(= formatdoc* 
"Blank lines separate paragraphs.
<p>Text surrounded by asterisks is italicized. To get a literal
asterisk, use \\* or **.
<p> Text after a blank line that is indented by two or more spaces is
formatted as code.
<p> Urls become links, except in the text field of a submission.
<p> If your url gets linked incorrectly, put it in &lt;angle
brackets&gt; and it should work.<br><br>")


; Noprocrast

(def check-procrast ((t user me))
  (or (no user)
      (no (uvar user noprocrast))
      (let now (seconds)
        (unless (uvar user firstview)
          (reset-procrast user))
        (or (when (< (/ (- now (uvar user firstview)) 60)
                     (uvar user maxvisit))
              (= (uvar user lastview) now)
              (save-prof user)
              t)
            (when (> (/ (- now (uvar user lastview)) 60)
                     (uvar user minaway))
              (reset-procrast user)
              t)))))
                
(def reset-procrast (user)
  (= (uvar user lastview) (= (uvar user firstview) (seconds)))
  (save-prof user))

(def procrast-msg (whence (t user me))
  (let m (+ 1 (trunc (- (uvar user minaway)
                        (minutes-since (uvar user lastview)))))
    (pr "<b>Get back to work!</b>")
    (para "Sorry, you can't see this page.  Based on the anti-procrastination
           parameters you set in your profile, you'll be able to use the site 
           again in " (plural m "minute") ".")
    (para "(If you got this message after submitting something, don't worry,
           the submission was processed.)")
    (para "To change your anti-procrastination settings, go to your profile 
           by clicking on your username.  If <tt>noprocrast</tt> is set to 
           <tt>yes</tt>, you'll be limited to sessions of <tt>maxvisit</tt>
           minutes, with <tt>minaway</tt> minutes between them.")
    (para)
    (w/rlink whence (underline (pr "retry")))
    ; (hspace 20)
    ; (w/rlink (do (reset-procrast user) whence) (underline (pr "override")))
    (br2)))


; Reset PW

(defopg resetpw (resetpw-page))

(def resetpw-page ((o msg))
  (minipage "Reset Password"
    (if msg
         (pr msg)
        (blank my!email)
         (do (pr "Before you do this, please add your email address to your ")
             (underlink "profile" (user-url (me)))
             (pr ". Otherwise you could lose your account if you mistype
                  your new password.")))
    (br2)
    (urform (try-resetpw arg!p)
      (single-input "New password: " 'p 20 "reset" t))))

(def try-resetpw (newpw)
  (if (no (<= 8 (len newpw) 72))
      (flink
        {resetpw-page "Passwords should be between 8 and 72 characters long.
                       Please choose another."})
      (do (set-pw (me) newpw)
          (save-pws)
          "news")))


; Scrubrules

(defopa scrubrules
  (scrub-page scrubrules*))

; If have other global alists, generalize an alist edit page.
; Or better still generalize vars-form.

(def scrub-page (rules (o msg nil))
  (minipage "Scrubrules"
    (when msg (pr msg) (br2))
    (uform (with (froms (lines arg!from)
                  tos   (lines arg!to))
             (if (is (len froms) (len tos))
                 (do (todisk scrubrules* (map list froms tos))
                     (scrub-page scrubrules* "Changes saved."))
                 (scrub-page rules "To and from should be same length.")))
      (pr "From: ")
      (tag (textarea name 'from 
                     cols (apply max 20 (map len (map car rules)))
                     rows (+ (len rules) 3))
        (apply pr #\newline (intersperse #\newline (map car rules))))
      (pr " To: ")
      (tag (textarea name 'to 
                     cols (apply max 20 (map len (map cadr rules)))
                     rows (+ (len rules) 3))
        (apply pr #\newline (intersperse #\newline (map cadr rules))))
      (br2)
      (submit "update"))))


; Abuse Analysis

(adop badsites ()
  (sptab 
    (row "Dead" "Days" "Site" "O" "K" "I" "Users")
    (each (site deads) (with (banned (banned-site-items)
                              pairs  (killedsites))
                         (+ pairs (map [list _ (banned _)]
                                       (rem (fn (d)
                                              (some [caris _ d] pairs))
                                            (keys banned-sites*)))))
      (let ban (car (banned-sites* site))
        (tr (tdr (when deads
                   (onlink (len deads)
                           (listpage (msec) deads
                                     nil (+ "killed at " site) "badsites" t))))
            (tdr (when deads (pr (round (days-since ((car deads) 'time))))))
            (td site)
            (td (w/rlink (do (set-site-ban site nil) "badsites")
                  (fontcolor (if ban gray!220 black) (pr "x"))))
            (td (w/rlink (do (set-site-ban site 'kill) "badsites")
                  (fontcolor (case ban kill darkred gray!220) (pr "x"))))
            (td (w/rlink (do (set-site-ban site 'ignore) "badsites")
                  (fontcolor (case ban ignore darkred gray!220) (pr "x"))))
            (td (each u (dedup (map by deads))
                  (userlink u nil)
                  (pr " "))))))))

(defcache killedsites 300
  (let bads (table [each-loaded-item i
                     (awhen (and (dead i) (sitename i!url))
                       (push i (_ it)))])
    (with (acc nil deadcount (table))
      (each (site items) bads
        (let n (len items)
          (when (> n 2)
            (= (deadcount site) n)
            (insort (compare > deadcount:car)
                    (list site (rev items))
                    acc))))
      acc)))

(defcache banned-site-items 300
  (table [each-loaded-item i
           (awhen (and (dead i) (check (sitename i!url) banned-sites*))
             (push i (_ it)))]))

; Would be nice to auto unban ips whose most recent submission is > n 
; days old, but hard to do because of lazy loading.  Would have to keep
; a table of most recent submission per ip, and only enforce bannnedness
; if < n days ago.

(adop badips ()
  (withs ((bads goods) (badips)
          (subs ips)   (sorted-badips bads goods))
    (sptab
      (row "IP" "Days" "Dead" "Live" "Users")
      (each ip ips
        (tr (td (let banned (banned-ips* ip)
                  (w/rlink (do (set-ip-ban ip (no banned))
                               "badips")
                    (fontcolor (if banned darkred) (pr ip)))))
            (tdr (when (goods|bads ip)
                   (pr (round (days-since 
                                (max (aif (car (goods ip)) it!time 0) 
                                     (aif (car (bads  ip)) it!time 0)))))))
            (tdr (onlink (len (bads ip))
                         (listpage (msec) (bads ip) nil (+ "dead from " ip) "badips")))
            (tdr (onlink (len (goods ip))
                         (listpage (msec) (goods ip) nil (+ "live from " ip) "badips")))
            (td (each u (subs ip)
                  (userlink u nil) 
                  (pr " "))))))))

(defcache badips 300
  (with (bads (table) goods (table))
    (each-loaded-item s
      (if (dead&commentable s)
          (push s (bads  s!ip))
          (push s (goods s!ip))))
    (list (zaptable rev bads)
          (zaptable rev goods))))

(def sorted-badips (bads goods)
  (withs (ips  (let ips (rem [len< (bads _) 2] (keys bads))
                (+ ips (rem [mem _ ips] (keys banned-ips*))))
          subs (table 
                 [each ip ips
                   (= (_ ip) (dedup (map by (+ (bads ip) (goods ip)))))]))
    (list subs
          (sort (compare > (memo [badness (subs _) (bads _) (goods _)]))
                ips))))

(def badness (subs bads goods)
  (* (/ (len bads)
        (max .9 (expt (len goods) 2))
        (expt (+ (days-since (aif (car bads) it!time 0))
                 1)
              2))
     (if (len> subs 1) 20 1)))


(edop flagged ()
  (display-selected-items [retrieve maxend* flagging _] "flagged"))

(def flagged (i) 
  (mem 'flagged i!keys))

(def flagging (i)
  (and (~mem 'nokill i!keys)
       (or (flagged i)
           (len> i!flags many-flags*))))

(edop killed ()
  (display-selected-items [retrieve maxend* dead _] "killed"))

(def display-selected-items (f whence)
  (display-items (f stories*) nil nil whence)
  (vspace 35)
  (color-stripe textgray)
  (vspace 35)
  (display-items (f comments*) nil nil whence))


; Rather useless thus; should add more data.

(adop badguys ()
  (tab (each u (sort (compare > [uvar _ created])
                     (users [ignored _]))
         (row (userlink u nil)))))

(adop badlogins ()  (logins-page bad-logins*))

(adop goodlogins () (logins-page good-logins*))

(def logins-page (source)
  (sptab (each (time ip user) (firstn 100 (rev (qlist source)))
           (row time ip user))))


; Stats

(adop optimes ()
  (sptab
    (tr (td "op") (tdr "avg") (tdr "med") (tdr "req") (tdr "total"))
    (spacerow 10)
    (each name (sort < newsop-names*)
      (tr (td name)
          (let ms (only&avg (qlist (optimes* name)))
            (tdr:prt (only&num ms 3 t t))
            (tdr:prt (only&num (only&med (qlist (optimes* name))) 3 t t))
            (let n (opcounts* name)
              (tdr:prt n)
              (tdr:prt (and n (num (/ (* n ms) 1000) 3 t t)))))))))

(defop topcolors 
  (minipage "Custom Colors"
    (tab 
      (each c (topcolors)
        (tr (td (pr "#" c)) (tdcolor (hex>color c) (hspace 30)))))))

(defcache topcolors 90
  (dedup (map downcase (trues [uvar _ topcolor] (users)))))

; Forgot page

(def forgot-url (id)
  (if (goodname id)
      (string "forgot?id=" id)
      "forgot"))

(defhook login-form (afterward acct pw)
  (link "Forgot your password?" (forgot-url acct)))

(= forgot-msg* "Password reset email sent. If you don't see it, 
                you might want to check your spam folder.")

(newsop forgot (id)
  (prbold "Reset your password")
  (br2)
  (aform (forgot-user arg!s)
    (inputs (s username 20 id))
    (br)
    (submit "Send reset email")))

(def forgot-user (user)
  (aif (~profile user)
        (pr "Unknown user")
       (check (uvar user email) ~blank)
        (do (changepw-email user it)
            (msgpage forgot-msg*))
        (msgpage
          (tostring
            (pr "Sorry, there's no email address in the profile so we"
                " can't send you a reset link.")
            (br2)
            (pr "You're welcome to contact us at @{site-email*}."
                " Assuming you're the account owner, there's usually"
                " something we can do.")))))

(def changepw-email (user email)
  (send-email
    email
    "@this-site* Password Recovery"
    (tostring
      (prn "Someone (hopefully you) requested we reset your password"
           " for @user at @{this-site*}. Your password has not yet"
           " been changed. If you want to change it, please visit "
           (+ site-url* (flink {changepw-page user})
              "&fnop=passwd-reset."))
      (prn)
      (prn "If not, just ignore this message."))))

(def changepw-page (user (o msg))
  (minipage "Reset Password for @user"
    (if msg (pr msg))
    (br2)
    (arform (try-changepw user arg!pw)
      (tab
        (row "New password: " (gentag input type 'password name 'pw size 20))
        (row "" (submit "Change"))))))

(def try-changepw (user newpw)
  (if (no (<= 8 (len newpw) 72))
      (flink {changepw-page user
               "Passwords should be between 8 and 72 characters long. 
                Please choose another."})
      (do (set-pw user newpw)
          (save-pws)
          "news")))

(defhook login ()
  (ensure-news-user)
  (newslog 'top-login))

(when (main)
  (nsv)
  (repl))

