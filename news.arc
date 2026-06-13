#!./sharc

; News.  2 Sep 06.

; to run news: (nsv), then go to http://localhost:8080
; put usernames of admins, separated by whitespace, in arc/admins

; bug: somehow (+ votedir* nil) is getting evaluated.

(declare 'atstrings t)

(= this-site*    "My Forum"
   site-url*     "http://news.yourdomain.com/"
   parent-url*   "/news"
   favicon-url*  ""
   site-desc*    "What this site is about."               ; for rss feed
   site-color*   (color 141 141 190)
   border-color* (color 141 141 190)
   prefer-url*   t)


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
  votes      nil   ; elts each (time ip user type score)
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

(= newsdir*  "arc/news/"
   storydir* "arc/news/story/"
   profdir*  "arc/news/profile/"
   votedir*  "arc/news/vote/")

(= votes* (table) profs* (table))

(= initload-users* nil)

(def nsv ((o port 8080))
  (load-news)
  (asv port))

(def load-news ()
  (map ensure-dir (list arcdir* newsdir* storydir* votedir* profdir*))
  (unless stories* (load-items))
  (if (and initload-users* (empty profs*)) (load-users)))

(def load-users ()
  (pr "load users: ")
  (noisy-each 100 id (dir profdir*)
    (load-user id)))

; For some reason vote files occasionally get written out in a 
; broken way.  The nature of the errors (random missing or extra
; chars) suggests the bug is lower-level than anything in Arc.
; Which unfortunately means all lists written to disk are probably
; vulnerable to it, since that's all save-table does.

(def load-user (u)
  (= (votes* u) (load-table (+ votedir* u))
     (profs* u) (temload 'profile (+ profdir* u)))
  u)

; Have to check goodname because some user ids come from http requests.
; So this is like safe-item.  Don't need a sep fn there though.

; A valid registered user (one in hpasswords*) is auto-given a
; fresh news profile if they don't have one yet --- this happens
; for accounts created via app.arc's plain login form, which
; doesn't fire news.arc's ensure-news-user callback. Without
; this, (uvar user k) would call NIL as a function and crash
; the request. Invalid / unknown user ids still return nil.
;
; init-user sets (profs* u) and returns u (the username), not the
; profile, so we read it back from profs* after init.
(def profile ((t u me))
  (or (profs* u)
      (aand (goodname u)
            (or (and (file-exists (+ profdir* u))
                     (= (profs* u) (temload 'profile (+ profdir* u))))
                (when (hpasswords* u)
                  (init-user u)
                  (profs* u))))))

(def votes ((t u me))
  (or (votes* u)
      (aand (file-exists (+ votedir* u))
            (= (votes* u) (load-table it)))))
          
(def init-user (u)
  (= (votes* u) (table) 
     (profs* u) (inst 'profile 'id u))
  (save-votes u)
  (save-prof u)
  u)

; Need this because can create users on the server (for other apps)
; without setting up places to store their state as news users.
; See the admin op in app.arc.  So all calls to login-page from the 
; news app need to call this in the after-login fn.

(def ensure-news-user ()
  (profile))

(def save-votes ((t u me)) (save-table (votes* u) (+ votedir* u)))

(def save-prof  ((t u me)) (save-table (profs* u) (+ profdir* u)))

(mac uvar (u k) `((profile ,u) ',k))

; '(me) (quoted) rather than (t u me): macro defaults evaluate
; at expansion time, so (t u me) would bake in (the me)'s value
; at compile time -- nil -- in every call site. The quoted form
; keeps (me) in the expansion to be evaluated at each runtime call.
(mac karma   ((o u '(me))) `(uvar ,u karma))
(mac ignored ((o u '(me))) `(uvar ,u ignore))

; Note that users will now only consider currently loaded users.

(def users ((o f idfn)) 
  (keep f (keys profs*)))

(def check-key (k (t u me))
  (and u (mem k (uvar u keys))))

(def author (i (t u me)) (is u i!by))


(= stories* nil comments* nil 
   items* (table) url->story* (table)
   maxid* 0 initload* 15000)

; The dir expression yields stories in order of file creation time 
; (because arc infile truncates), so could just rev the list instead of
; sorting, but sort anyway.

; Note that stories* etc only include the initloaded (i.e. recent)
; ones, plus those created since this server process started.

; Could be smarter about preloading by keeping track of popular pages.

(def load-items ()
  (system (+ "rm " storydir* "*.tmp"))
  (pr "load items: ") 
  (with (items (table)
         ids   (sort > (map int (dir storydir*))))
    (if ids (= maxid* (car ids)))
    (noisy-each 100 id (firstn initload* ids)
      (let i (load-item id)
        (push i (items i!type))))
    (= stories*  (rev (merge (compare < !id) items!story items!poll))
       comments* (rev items!comment))
    (hook 'initload items))
  (ensure-topstories))

(def ensure-topstories ()
  (aif (errsafe (readfile1 (+ newsdir* "topstories")))
       (= ranked-stories* (map item it))
       (do (prn "ranking stories.") 
           (flushout)
           (gen-topstories))))

(def astory   (i) (is i!type 'story))
(def acomment (i) (is i!type 'comment))
(def apoll    (i) (is i!type 'poll))

(def load-item (id)
  (let i (temload 'item (+ storydir* id))
    (= (items* id) i)
    (awhen (and (astory&live i) (check i!url ~blank))
      (register-url i it))
    i))

; Note that duplicates are only prevented of items that have at some 
; point been loaded. 

(def register-url (i url)
  (= (url->story* (canonical-url url)) i!id))

; redefined later

(= stemmable-sites* (table))

(def canonical-url (url)
  (if (stemmable-sites* (sitename url))
      (cut url 0 (pos #\? url))
      url))

(def new-item-id ()
  (evtil (++ maxid*) [~file-exists (+ storydir* _)]))

(def item (id)
  (or (items* id) (errsafe:load-item id)))

(def kids (i) (map item i!kids))

; For use on external item references (from urls).  Checks id is int 
; because people try e.g. item?id=363/blank.php

(def safe-item (id)
  (ok-id&item (if (isa id 'string) (saferead id) id)))

(def ok-id (id) 
  (and (exact id) (<= 1 id maxid*)))

(def arg->item (key)
  (safe-item:saferead (arg key)))

(def live (i) (nor i!dead i!deleted))

(def save-item (i) (save-table i (+ storydir* i!id)))

(def kill (i how)
  (unless i!dead
    (log-kill i how)
    (wipe (comment-cache* i!id))
    (set i!dead)
    (save-item i)))

(= kill-log* nil)

(def log-kill (i (t how me))
  (push (list i!id how) kill-log*))

(mac each-loaded-item (var . body)
  (w/uniq g
    `(let ,g nil
       (loop (= ,g maxid*) (> ,g 0) (-- ,g)
         (whenlet ,var (items* ,g)
           ,@body)))))

(def loaded-items (test)
  (accum a (each-loaded-item i (test&a i))))

(def newslog args (apply srvlog 'news (ip) (me) args))


; Ranking

; Votes divided by the age in hours to the gravityth power.
; Would be interesting to scale gravity in a slider.

(= gravity* 1.8 timebase* 120 front-threshold* 1 
   nourl-factor* .4 lightweight-factor* .3 )

(def frontpage-rank (s (o scorefn realscore) (o gravity gravity*))
  (* (/ (let base (- (scorefn s) 1)
          (if (> base 0) (expt base .8) base))
        (expt (/ (+ (item-age s) timebase*) 60) gravity))
     (if (no (in s!type 'story 'poll))  .5
         (blank s!url)                  nourl-factor*
         (lightweight s)                (min lightweight-factor* 
                                             (contro-factor s))
                                        (contro-factor s))))

(def contro-factor (s)
  (aif (check (visible-family s nil) [> _ 20])
       (min 1 (expt (/ (realscore s) it) 2))
       1))

(def realscore (i) (- i!score i!sockvotes))

(disktable lightweights* (+ newsdir* "lightweights"))

(def lightweight (s)
  (or s!dead
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
 
(def rank-stories (n consider scorefn)
  (bestn n (compare > scorefn) (latest-items metastory nil consider)))

; With virtual lists the above call to latest-items could be simply:
; (map item (retrieve consider metastory:item (gen maxid* [- _ 1])))

(def latest-items (test (o stop) (o n))
  (accum a
    (catch 
      (down id maxid* 1
        (let i (item id)
          (if (or (and stop (stop i)) (and n (<= n 0))) 
              (throw))
          (when (test i) 
            (a i) 
            (if n (-- n))))))))
             
; redefined later

(def metastory (i) (and i (in i!type 'story 'poll)))

(def adjust-rank (s (o scorefn frontpage-rank))
  (insortnew (compare > (memo scorefn)) s ranked-stories*)
  (save-topstories))

; If something rose high then stopped getting votes, its score would
; decline but it would stay near the top.  Newly inserted stories would
; thus get stuck in front of it. I avoid this by regularly adjusting 
; the rank of a random top story.

(defbg rerank-random 30 (rerank-random))

(def rerank-random ()
  (when ranked-stories*
    (adjust-rank (ranked-stories* (rand (min 50 (len ranked-stories*)))))))

(def topstories (n (o threshold front-threshold*))
  (retrieve n
            [and (>= (realscore _) threshold) (cansee _)]
            ranked-stories*))

(= max-delay* 10)

(def cansee (i (t user me))
  (if i!deleted   (admin user)
      i!dead      (or (author i user) (seesdead user))
      (flagged i) (or (author i user) (seesdead user))
      (delayed i) (author i user)
      t))

(let mature (table)
  (def delayed (i)
    (and (no (mature i!id))
         (acomment i)
         (or (< (item-age i) (min max-delay* (uvar i!by delay)))
             (do (set (mature i!id))
                 nil)))))

(def seesdead ((t user me))
  (or (and user (uvar user showdead))
      (editor user)))

(def visible (items (t user me))
  (keep [cansee _ user] items))

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

(defopr favicon.ico favicon-url*)

; redefined later

(def gen-css-url ()
  (gentag link rel 'stylesheet type 'text/css href (static-src "news.css")))

(mac npage (title . body)
  `(tag html 
     (tag head 
       (gen-css-url)
       (prn "<link rel=\"shortcut icon\" href=\"" favicon-url* "\">")
       (tag (script src (static-src "hn.js")))
       (tag title (pr ,title)))
     (tag body 
       (center
         (tag (table id 'hnmain border 0 cellpadding 0 cellspacing 0 width "85%"
                     bgcolor sand)
           ,@body)))))

(= pagefns* nil)

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
                 (hook 'longfoot)
                 (admin-bar (- (msec) ,gt) ,whence)))))))

(def gc ((o full t))
  (sb-ext::gc :full full))

(def memory-after-gc ()
  (gc)
  (memory))

(def admin-bar (elapsed whence)
  (when (or (admin) arg!perf)
    (br2)
    (w/bars
      (pr (len fns*) " fnids")
      (pr (len items*) "/" maxid* " loaded")
      (pr (num:round:memory-after-gc) " bytes")
      (pr (num elapsed 3 t t) " msec")
      (when (admin)
        (link "settings" "newsadmin")
        (hook 'admin-bar whence)))))

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

(= votejs* "
function byId(id) {
  return document.getElementById(id);
}

function vote(node) {
  var v = node.id.split(/_/);   // {'up', '123'}
  var item = v[1]; 

  // adjust score (absent for items with no shown score, e.g. comments)
  var score = byId('score_' + item);
  if (score) {
    var newscore = parseInt(score.innerHTML) + (v[0] == 'up' ? 1 : -1);
    score.innerHTML = newscore + (newscore == 1 ? ' point' : ' points');
  }

  // hide arrows
  var up = byId('up_' + item), down = byId('down_' + item);
  if (up)   up.style.visibility   = 'hidden';
  if (down) down.style.visibility = 'hidden';

  // ping server
  var ping = new Image();
  ping.src = node.href;

  return false; // cancel browser nav
} ")


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
                    (hspace 10)
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

(= toplabels* '(nil "welcome" "new" "threads" "comments" "leaders" "*"))

; redefined later

(= welcome-url* "welcome")

(def toprow (label)
  (w/bars
    (if (noob) (toplink "welcome" welcome-url* label))
    (toplink "new" "newest" label)
    (if (me) (toplink "threads" (threads-url) label))
    (toplink "comments" "newcomments" label)
    (toplink "leaders"  "leaders"     label)
    (hook 'toprow label)
    (link "submit")
    (unless (mem label toplabels*)
      (fontcolor white (pr label)))))

(def toplink (name dest label)
  (tag-if (is name label) (span class 'topsel)
    (link name dest)))

(def topright (whence (o showkarma t))
  (when (me)
    (userlink (me) nil)
    (when showkarma
      (pr " (")
      (tag (span id 'karma)
        (pr (karma)))
      (pr ")"))
    (pr " | "))
  (if (me)
      (urlink 'logout (logout-user) whence)
      (onlink "login"
        (login-page 'both nil
                    (list {do (ensure-news-user)
                              (newslog 'top-login)}
                          whence)))))

(def noob ((t user me))
  (and user (< (days-since (uvar user created)) 1)))


; News-Specific Defop Variants

(mac defopt (name test msg . body)
  `(defop ,name
     (if (,test (me))
         (do ,@body)
         (login-page 'both (+ "Please log in" ,msg ".")
                     (list {ensure-news-user}
                           (string ',name (reassemble-args)))))))

(mac defopg (name . body) `(defopt ,name idfn   ""                     ,@body))
(mac defope (name . body) `(defopt ,name editor " as an editor"        ,@body))
(mac defopa (name . body) `(defopt ,name admin  " as an administrator" ,@body))

(mac opexpand (definer name parms . body)
  `(,definer ,name
     (with (user (me) ip (ip))
       (with ,(and parms (mappend [list _ (list 'arg (list 'quote _))]
                                  parms))
         (newslog ',name ,@parms)
         ,@body))))

(= newsop-names* nil)

(mac newsopr args
  `(opexpand defopr ,@args))

(mac newsop args
  `(do (pushnew ',(car args) newsop-names*)
       (opexpand defop ,@args)))

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
    (bigtoks  comment-kill    ,comment-kill*                  t t)
    (bigtoks  comment-ignore  ,comment-ignore*                t t)
    (bigtoks  lightweights    ,(sort < (keys lightweights*))  t t)))

; Need a util like vars-form for a collection of variables.
; Or could generalize vars-form to think of places (in the setf sense).

(def newsadmin-page ()
  (shortpage nil nil "newsadmin" "newsadmin"
    (vars-form (nad-fields)
               (fn (name val)
                 (case name
                   caching            (= caching* val)
                   comment-kill       (todisk comment-kill* val)
                   comment-ignore     (todisk comment-ignore* val)
                   lightweights       (todisk lightweights* (memtable val))))
               {newsadmin-page})

    (br2)
    (aform (let subject arg!id
             (if (profile subject)
                 (do (killallby subject)
                     (submitted-page subject))
                 (admin&newsadmin-page)))
      (single-input "" 'id 20 "kill all by"))
    (br2)
    (aform (do (set-ip-ban arg!ip t)
               (admin&newsadmin-page))
      (single-input "" 'ip 20 "ban ip"))))


; Users

(newsop user (id)
  (if (only&profile id)
      (user-page id)
      (pr "No such user.")))

(def user-page (user)
  (shortpage nil nil (+ "Profile: " user) (user-url user)
    (profile-form user)
    (hook 'user user)))

(def profile-form (user)
  (let prof (profile user)
    (vars-form (user-fields user)
               (fn (name val)
                 (when (and (is name 'ignore) val (no prof!ignore))
                   (log-ignore user 'profile))
                 (= (prof name) val))
               {do (save-prof user)
                   (user-page user)})))

(= topcolor-threshold* 0)

(= email-msg*
  (+ "<font size=\"2\">"
     "Only admins see your email below. To share publicly,"
     " add to the 'about' box."
     "</font>"))

(def user-fields (user)
  (withs (e (editor)
          a (admin)
          w (me user)
          k (and w (> (karma user) topcolor-threshold*))
          u (or a w)
          m (or a (and (member) w))
          p (profile user))
    `((raw     user        ,(user-field user)                        t   nil)
      (string  name        ,(p 'name)                               ,m  ,m)
      (string  created     ,(text-age:user-age user)                 t   nil)
      (int     auth        ,(p 'auth)                               ,e  ,a)
      (yesno   member      ,(p 'member)                             ,a  ,a)
      (posint  karma       ,(p 'karma)                               t  ,a)
      (num     avg         ,(p 'avg)                                ,a  nil)
      (yesno   ignore      ,(p 'ignore)                             ,e  ,e)
      (num     weight      ,(p 'weight)                             ,a  ,a)
      (mdtext2 about       ,(p 'about)                               t  ,u)
      (raw     nil         ,"<tr style=\"height:5px\"></tr>"        ,u  nil)
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
      (int     delay       ,(p 'delay)                              ,u  ,u)
      (string  nil         ,(resetpw-link)                          ,w   nil)
      (string  nil         ,(user-submissions-link user)             t   nil)
      (string  nil         ,(user-comments-link user)                t   nil)
      (string  nil         ,(upvoted-links user)                    ,u   nil)
      )))

(def user-field (user)
  (tostring
    (tag (tr class 'athing)
      (tag (td valign 'top)
        (pr "user:"))
      (tag (td timestamp (uvar user created))
        (tag (a href (user-url user) class 'hnuser)
          (pr user))))))

(def resetpw-link ()
  (tostring (underlink "reset password" "resetpw")))

(def user-submissions-link ((t user me))
  (tostring:underlink "submissions" (submitted-url user)))

(def user-comments-link ((t user me))
  (tostring:underlink "comments" (threads-url user)))

(def upvoted-links ((t user me))
  (tostring
    (when (uvar user votes)
      (underlink "upvoted submissions" (upvoted-url user))
      (pr " / ")
      (underlink "comments" (upvoted-url user t)))))

(newsop welcome ()
  (pr "Welcome to " this-site* ", " user "!"))


; Main Operators

; remember to set caching to 0 when testing non-logged-in 

(= caching* 1 perpage* 30 threads-perpage* 10 maxend* 210)

; Limiting that newscache can't take any arguments except the user.
; To allow other arguments, would have to turn the cache from a single 
; stored value to a hash table whose keys were lists of arguments.

(mac newscache (name time . body)
  (w/uniq gc
    `(let ,gc (cache {if arg!perf nil (* caching* ,time)}
                     {tostring (w/me nil ,@body)})
       (def ,name ()
         (if (me)
             (do ,@body)
             (pr (,gc)))))))


(newsop news () (newspage))

(newsop ||   () (newspage))

;(newsop index.html () (newspage))

(newscache newspage 90
  (listpage (msec) (topstories maxend*) nil nil "news"))

(def listpage (t1 items label title (o url label) (o number t))
  (hook 'listpage)
  (longpage t1 nil label title url
    (display-items items label title url 0 perpage* number)))


(newsop newest () (newestpage))

; Note: dead/deleted items will persist for the remaining life of the 
; cached page.  If this were a prob, could make deletion clear caches.

(newscache newestpage 40
  (listpage (msec) (newstories maxend*) "new" "New Links" "newest"))

(def newstories (n)
  (retrieve n [cansee _] stories*))


(newsop best () (bestpage))

(newscache bestpage 1000
  (listpage (msec) (beststories maxend*) "best" "Top Links"))

; As no of stories gets huge, could test visibility in fn sent to best.

(def beststories (n)
  (bestn n (compare > realscore) (visible stories*)))


(newsop noobstories () (noobspage stories*))
(newsop noobcomments () (noobspage comments*))

(def noobspage (source)
  (listpage (msec) (noobs maxend* source) "noobs" "New Accounts"))

(def noobs (n source)
  (retrieve n [cansee&bynoob _] source))

(def bynoob (i)
  (< (- (user-age i!by) (item-age i)) 2880))


(newsop bestcomments () (bestcpage))

(newscache bestcpage 1000
  (listpage (msec) (bestcomments maxend*) 
            "best comments" "Best Comments" "bestcomments" nil))

(def bestcomments (n)
  (bestn n (compare > realscore) (visible comments*)))


(newsop lists () 
  (longpage (msec) nil "lists" "Lists" "lists"
    (sptab
      (row (link "best")         "Highest voted recent links.")
      (row (link "active")       "Most active current discussions.")
      (row (link "bestcomments") "Highest voted recent comments.")
      (row (link "noobstories")  "Submissions from new accounts.")
      (row (link "noobcomments") "Comments from new accounts.")
      (when (admin)
        (map row:link
             '(optimes topips flagged killed badguys badlogins goodlogins)))
      (hook 'listspage))))


(def voted-items (test (t user me))
  (keep test (keep [cansee _ user] (map item (keys:votes user)))))

(def upvoted-url (user (o comments))
  (+ "upvoted?id=" user
     (if comments "&comments=t" "")))

(newsop upvoted (id comments) 
  (if (only&profile id)
      (upvoted-page id (in comments "t" "T"))
      (pr "No such user.")))

(def upvoted-page (user comments)
  (if (or (me user) (admin))
      (listpage (msec)
                (sort (compare < item-age)
                      (voted-items (if comments acomment astory) user))
                "upvoted"
                (if (and (~me user) comments)
                     "@{user}'s upvoted comments"
                    (and (~me user) (no comments))
                     "@{user}'s upvoted submissions"
                    comments
                     "Upvoted comments"
                     "Upvoted submissions")
                (upvoted-url user comments))
      (pr "Can't display that.")))


; Story Display

(def display-items (items label title whence
                    (o start 0) (o end perpage*) (o number))
  (zerotable
    (let n start
      (each i (cut items start end)
        (display-item (and number (++ n)) i whence t)
        (spacerow (if (acomment i) 15 5))))
    (when end
      (let newend (+ end perpage*)
        (when (and (<= newend maxend*) (< end (len items)))
          (spacerow 10)
          (tr (tag (td colspan (if number 2 1)))
              (tag (td class 'title)
                (morelink display-items
                          items label title end newend number))))))))

; This code is inevitably complex because the More fn needs to know 
; its own fnid in order to supply a correct whence arg to stuff on 
; the page it generates, like logout and delete links.

(def morelink (f items label title . args)
  (tag (a href
          (url-for
            (afnid {do (prn)
                       (let url (url-for it)     ; it bound by afnid
                         (newslog 'more label)
                         (longpage (msec) nil label title url
                           (apply f items label title url args)))}))
          rel 'nofollow)
    (pr "More")))

(def display-story (i s whence)
  (when (or (cansee s) (s 'kids))
    (tag (tr class "athing submission" id s!id)
      (display-item-number i)
      (tag (td valign 'top class 'votelinks) (votelinks s whence))
      (titleline s s!url whence))
    (tr (tag (td colspan (if i 2 1)))
        (tag (td class 'subtext)
          (spanclass subline
            (hook 'itemline s)
            (itemline s whence)
            (when (in s!type 'story 'poll) (commentlink s))
            (editlink s)
            (when (apoll s) (addoptlink s))
            (unless i (flaglink s whence))
            (killlink s whence)
            (blastlink s whence)
            (blastlink s whence t)
            (deletelink s whence))))))

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
                  (spanclass sitestr (pr it)))
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
      (pr:eschtml s!title))))
      
(def pseudo-text (i)
  (if (flagged i) "[flagged]"
      i!deleted   "[deleted]"
                  "[dead]"))

(def deadmark (i)
  (when (and (flagged i) (seesdead))
    (pr " [flagged] "))
  (when (and i!dead (seesdead))
    (pr " [dead] "))
  (when (and i!deleted (admin))
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

; could memoize votelink more, esp for non-logged in users,
; since only uparrow is shown; could straight memoize

; redefined later (identically) so the outs catch new vals of up-url, etc.

(def votelink (i whence dir)
  (tag (a id    (if (me) (string dir '_ i!id))
          ; hn.js's click handler catches .clicky; nosee hides an arrow
          ; the user has already used (visibility:hidden) until unvote.
          class (if (me) (string 'clicky (if ((votes) i!id) " nosee")))
          href  (vote-url i dir whence))
    (if (is dir 'up)
        (out (tag (div class "votearrow"           title "upvote")))
        (out (tag (div class "votearrow rotate180" title "downvote"))))))

; hn.js reads id/how/auth/goto from the vote link's href.

(def vote-url (i dir whence)
  (+ "vote?id=" i!id
            "&how=" dir
            (aif (me) (+ "&auth=" (urlencode:user->cookie* it)))
            "&goto=" (urlencode whence)))

(= lowest-score* -4)

; Not much stricter than whether to generate the arrow.  Further tests 
; applied in vote-for.

(def canvote (i dir (o ignore-voted))
  (and (me)
       (news-type&live i)
       (or (is dir 'up) (> i!score lowest-score*))
       (or ignore-voted (no ((votes) i!id)))
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
         whence (if goto (urldecode goto) "news"))
    (if (no i)
         (flink {pr "No such item."})
        (no (in how 'up 'down 'un))
         (flink {pr "Can't make that vote."})
        (no user)
         (login-page 'both "You have to be logged in to vote."
                     (list {do (ensure-news-user)
                               (newslog 'vote-login)
                               (when (canvote i how)
                                 (vote-for i how)
                                 (logvote i))}
                           whence))
        (isnt auth (user->cookie* user))
         (flink {pr "User mismatch."})
        (is how 'un)
         (do (unvote-for i)
             (logvote i)
             goto)
        (canvote i how)
         (do (vote-for i how)
             (logvote i)
             goto)
         (flink {pr "Can't make that vote."}))))

(def cansee-score (i)
  (or (isnt i!type 'comment)
      (me i!by)
      (admin)))

(def itemline (i (o whence))
  (when (cansee-score i)
    (itemscore i)
    (pr " by "))
  (byline i whence))

(def itemscore (i)
  (tag (span class 'score id (+ "score_" i!id))
    (pr (plural (if (is i!type 'pollopt) (realscore i) i!score)
                "point")))
  (hook 'itemscore i))

; redefined later

(def byline (i (o whence))
  (userlink i!by)
  (pr " ")
  (agelink i)
  (pr " ")
  (unvotelink i whence))

(def user-url (user) (+ "user?id=" user))

(= show-avg* nil)

(def userlink (user (o show-avg t))
  (tag (a href (user-url user) class 'hnuser id (if (me user) 'me))
    (user-name user))
  (awhen (and show-avg* (admin) show-avg (uvar user avg))
    (pr " (@(num it 1 t t))")))

(def agelink (i)
  (let (s m h D M Y) (map [+ (if (< _ 10) "0" "") _]
                          (timedate i!time))
    (let title (+ "" Y "-" M "-" D "T" h ":" m ":" s " " i!time)
      (tag (span class "age" title title)
        (link (text-age:item-age i) (item-url i!id))))))

(def unvotelink (i (o whence))
  ; hn.js injects the "unvote" link here after a live vote; render it
  ; server-side too when the user has already voted, so it persists
  ; across refreshes.
  (tag (span id (string "unv_" i!id))
    ; not (author i): you auto-upvote your own items but can't unvote them
    (whenlet vote (and (me) (~author i) ((votes) i!id))
      (pr bar*)
      (tag (a id    (string "un_" i!id)
              class 'clicky
              href  (vote-url i 'un (or whence "news")))
        (pr (if (is (vote 3) 'up) "unvote" "undown"))))))

(= noob-color* (color 60 150 60))

(def user-name (user)
  (if (and (editor) (ignored user))
       (fontcolor darkred (pr user))
      (and (editor) (< (user-age user) 1440))
       (fontcolor noob-color* (pr user))
       (pr user)))

(= show-threadavg* nil)

(def commentlink (i)
  (when (cansee i)
    (pr bar*)
    (tag (a href (item-url i!id))
      (let n (- (visible-family i) 1)
        (if (> n 0)
            (do (pr (plural n "comment"))
                (awhen (and show-threadavg* (admin user) (threadavg i))
                  (pr " (@(num it 1 t t))")))
            (pr "discuss"))))))

(def visible-family (i (t user me))
  (+ (if (cansee i user) 1 0)
     (sum [visible-family (item _) user] i!kids)))

(def threadavg (i)
  (only&avg (map [or (uvar _ avg) 1] 
                 (rem admin (dedup (map !by (keep live (family i))))))))

(= user-changetime* 120 editor-changetime* 1440)

(= everchange* (table) noedit* (table))

(def canedit (i (t user me))
  (or (admin user)
      (and (~noedit* i!type)
           (editor user)
           (< (item-age i) editor-changetime*))
      (own-changeable-item i user)))

(def own-changeable-item (i (t user me))
  (and (author i user)
       (~mem 'locked i!keys)
       (no i!deleted)
       (or (everchange* i!type)
           (< (item-age i) user-changetime*))))

(def editlink (i)
  (when (canedit i)
    (pr bar*)
    (link "edit" (edit-url i))))

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
             (~me i!by)
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
                            (~find admin:!2 i!vote))
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

(def killlink (i whence)
  (when (admin)
    (pr bar*)
    (w/rlink (do (zap no i!dead)
                 (if i!dead
                     (do (pull 'nokill i!keys)
                         (log-kill i))
                     (pushnew 'nokill i!keys))
                 (save-item i)
                 whence)
      (pr "@(if i!dead 'un)kill"))))

; Blast kills the submission and bans the user.  Nuke also bans the 
; site, so that all future submitters will be ignored.  Does not ban 
; the ip address, but that will eventually get banned by maybe-ban-ip.

(def blastlink (i whence (o nuke))
  (when (and (admin) 
             (or (no nuke) (~empty i!url)))
    (pr bar*)
    (w/rlink (do (toggle-blast i nuke)
                 whence)
      (prt (if (ignored i!by) "un-") (if nuke "nuke" "blast")))))

(def toggle-blast (i (o nuke))
  (atomic
    (if (ignored i!by)
        (do (wipe i!dead (ignored i!by))
            (awhen (and nuke (sitename i!url))
              (set-site-ban it nil)))
        (do (set i!dead)
            (ignore i!by (if nuke 'nuke 'blast))
            (awhen (and nuke (sitename i!url))
              (set-site-ban it 'ignore))))
    (if i!dead (log-kill i))
    (save-item i)
    (save-prof i!by)))

(def candelete (i (t user me))
  (or (admin user) (own-changeable-item i user)))

(def deletelink (i whence)
  (when (candelete i)
    (pr bar*)
    (linkf (if i!deleted "undelete" "delete")
      (if (candelete i)
          (del-confirm-page i whence)
          (prn "You can't delete that.")))))

; Undeleting stories could cause a slight inconsistency. If a story
; linking to x gets deleted, another submission can take its place in
; url->story.  If the original is then undeleted, there will be two 
; stories with equal claim to be in url->story.  (The more recent will
; win because it happens to get loaded later.)  Not a big problem.

(def del-confirm-page (i whence)
  (minipage "Confirm"
    (tab
      ; link never used so not testable but think correct
      (display-item nil i (flink {del-confirm-page i whence}))
      (spacerow 20)
      (tr (td)
          (td (urform (do (when (candelete i)
                            (= i!deleted (is arg!b "Yes"))
                            (save-item i))
                          whence)
                 (prn "Do you want this to @(if i!deleted 'stay 'be) deleted?")
                 (br2)
                 (but "Yes" "b") (sp) (but "No" "b")))))))

(def logvote (story)
  (newslog 'vote (story 'id) (list (story 'title))))

(def text-age (a)
  (tostring
    (if (>= a 525600) (let (s m h D M Y) (timedate:since (* a 60))
                        (let M (case M
                                 1 "Jan"
                                 2 "Feb"
                                 3 "March"
                                 4 "April"
                                 5 "May"
                                 6 "June"
                                 7 "July"
                                 8 "Aug"
                                 9 "Sept"
                                 10 "Oct"
                                 11 "Nov"
                                 12 "Dec"
                                 (err "Bad month number"))
                          (pr "on " M " " D ", " Y)))
        (>= a 1440) (pr (plural (trunc (/ a 1440)) "day")    " ago")
        (>= a   60) (pr (plural (trunc (/ a 60))   "hour")   " ago")
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

(= downvote-ratio-limit* .65 recent-votes* nil votewindow* 100)

; Note: if vote-for by one user changes (s 'score) while s is being
; edited by another, the save after the edit will overwrite the change.
; Actual votes can't be lost because that field is not editable.  Not a
; big enough problem to drag in locking.

(def vote-for (i (o dir 'up))
  (unless (or ((votes) i!id) 
              (and (~live i) (~me i!by)))
    (withs (ip   (logins* (me))
            vote (list (seconds) ip (me) dir i!score))
      (unless (or (and (or (ignored) check-key!novote)
                       (~me i!by))
                  (and (is dir 'down)
                       (~editor)
                       (or check-key!nodowns
                           (> (downvote-ratio) downvote-ratio-limit*)
                           ; prevention of karma-bombing
                           (just-downvoted i!by)))
                  (and (~legit-user)
                       (~me i!by)
                       (find [is (cadr _) ip] i!votes))
                  (and (isnt i!type 'pollopt)
                       (biased-voter i vote)))
        (++ i!score (case dir up 1 down -1))
        ; canvote protects against sockpuppet downvote of comments 
        (when (and (is dir 'up) (possible-sockpuppet))
          (++ i!sockvotes))
        (metastory&adjust-rank i)
        (unless (or (author i)
                    (and (is ip i!ip) (~editor))
                    (is i!type 'pollopt))
          (++ (karma i!by) (case dir up 1 down -1))
          (save-prof i!by))
        (wipe (comment-cache* i!id)))
      (if (admin) (pushnew 'nokill i!keys))
      (push vote i!votes)
      (save-item i)
      (push (list (seconds) i!id i!by (sitename i!url) dir)
            (uvar (me) votes))
      (= ((votes* (me)) i!id) vote)
      (save-votes)
      (zap [firstn votewindow* _] (uvar (me) votes))
      (save-prof)
      (push (cons i!id vote) recent-votes*))))

; redefined later

; Inverse of vote-for: undo the current user's vote on i.  Mirrors the
; recorded effects (score, karma, the vote records); hn.js sends how=un.

(def unvote-for (i)
  (whenlet vote ((votes) i!id)
    (let dir (vote 3)
      (-- i!score (case dir up 1 down -1))
      (metastory&adjust-rank i)
      (unless (or (author i)
                  (and (is (logins* (me)) i!ip) (~editor))
                  (is i!type 'pollopt))
        (-- (karma i!by) (case dir up 1 down -1))
        (save-prof i!by))
      (pull [is _!2 (me)] i!votes)
      (save-item i)
      (wipe ((votes* (me)) i!id))
      (pull [is _!1 i!id] (uvar (me) votes))
      (save-votes)
      (save-prof)
      (wipe (comment-cache* i!id)))))

(def biased-voter (i vote) nil)

; ugly to access vote fields by position number

(def downvote-ratio ((o sample 20))
  (ratio [is _!1!3 'down]
         (keep [let by ((item (car _)) 'by)
                 (nor (me by) (ignored by))]
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
  (keep [is _!3 user] recent-votes*))


; Story Submission

(newsop submit ()
  (if user
      (submit-page "" "" t)
      (submit-login-warning "" "" t)))

(def submit-login-warning ((o url) (o title) (o showtext) (o text))
  (login-page 'both "You have to be logged in to submit."
              {do (ensure-news-user)
                  (newslog 'submit-login)
                  (submit-page url title showtext text)}))

(def submit-page ((o url) (o title) (o showtext) (o text "") (o msg))
  (minipage "Submit"
    (pagemessage msg)
    (urform (process-story (clean-url arg!u)
                           (striptags arg!t)
                           showtext
                           (and showtext (md-from-form arg!x t)))
      (tab
        (row "title"  (input "t" title 50))
        (if prefer-url*
            (do (row "url" (input "u" url 50))
                (when showtext
                  (row "" "<b>or</b>")
                  (row "text" (textarea "x" 4 50 (only&pr text)))))
            (do (row "text" (textarea "x" 4 50 (only&pr text)))
                (row "" "<b>or</b>")
                (row "url" (input "u" url 50))))
        (row "" (submit))
        (spacerow 20)
        (row "" submit-instructions*)))))

(= submit-instructions*
   "Leave url blank to submit a question for discussion. If there is 
    no url, the text (if any) will appear at the top of the comments 
    page. If there is a url, the text will be ignored.")

; For use by outside code like bookmarklet.
; http://news.domain.com/submitlink?u=http://foo.com&t=Foo
; Added a confirm step to avoid xss hacks.

(newsop submitlink (u t)
  (if user
      (submit-page u t)
      (submit-login-warning u t)))

(= title-limit* 80
   retry*       "Please try again."
   toolong*     "Please make title < @title-limit* characters."
   bothblank*   "The url and text fields can't both be blank.  Please
                 either supply a url, or if you're asking a question,
                 put it in the text field."
   toofast*     "You're submitting too fast.  Please slow down.  Thanks."
   spammage*    "Stop spamming us.  You're wasting your time.")

; Only for annoyingly high-volume spammers. For ordinary spammers it's
; enough to ban their sites and ip addresses.

(disktable big-spamsites* (+ newsdir* "big-spamsites"))

(def process-story (url title showtext text)
  (aif (and (~blank url) (live-story-w/url url))
       (do (vote-for it)
           (item-url it!id))
       (if (no (me))
            (flink {submit-login-warning url title showtext text})
           (no (and (or (blank url) (valid-url url))
                    (~blank title)))
            (flink {submit-page url title showtext text retry*})
           (len> title title-limit*)
            (flink {submit-page url title showtext text toolong*})
           (and (blank url) (blank text))
            (flink {submit-page url title showtext text bothblank*})
           (let site (sitename url)
             (or (big-spamsites* site) (recent-spam site)))
            (flink {msgpage spammage*})
           (oversubmitting 'story url)
            (flink {msgpage toofast*})
           (let s (create-story url (process-title title) text)
             (story-ban-test s url)
             (when (ignored (me)) (kill s 'ignored))
             (submit-item s)
             (maybe-ban-ip s)
             "newest"))))

(def submit-item (i)
  (push i!id (uvar (me) submitted))
  (save-prof (me))
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
  (let s2 (multisubst scrubrules* s)
    (zap upcase (s2 0))
    s2))

(def live-story-w/url (url) 
  (aand (url->story* (canonical-url url)) (check (item it) live)))

(def parse-site (url)
  (rev (tokens (cadr (tokens url [in _ #\/ #\?])) #\.)))

(defmemo sitename (url)
  (and (valid-url url)
       (let toks (parse-site (rem #\space url))
         (if (isa (saferead (car toks)) 'int)
             (tostring (prall toks "" "."))
             (let (t1 t2 t3 . rest) toks  
               (if (and (~in t3 nil "www")
                        (or (mem t1 multi-tld-countries*) 
                            (mem t2 long-domains*)))
                   (+ t3 "." t2 "." t1)
                   (and t2 (+ t2 "." t1))))))))

(= multi-tld-countries* '("uk" "jp" "au" "in" "ph" "tr" "za" "my" "nz" "br" 
                          "mx" "th" "sg" "id" "pk" "eg" "il" "at" "pl"))

(= long-domains* '("blogspot" "wordpress" "livejournal" "blogs" "typepad" 
                   "weebly" "posterous" "blog-city" "supersized" "dreamhosters"
                   ; "sampasite"  "multiply" "wetpaint" ; all spam, just ban
                   "eurekster" "blogsome" "edogo" "blog" "com"))

(def create-story (url title text)
  (newslog 'create url (list title))
  (let s (inst 'item 'type 'story 'id (new-item-id)
                     'url url 'title title 'text text
                     'by (me) 'ip (ip))
    (save-item s)
    (= (items* s!id) s)
    (unless (blank url) (register-url s url))
    (push s stories*)
    s))


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

(= comment-kill* nil ip-ban-threshold* 3)

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

(def maybe-ban-ip (s)
  (when (and s!dead (ignored s!by))
    (let bads (loaded-items [and _!dead (astory _) (is _!ip s!ip)])
      (when (and (len> bads ip-ban-threshold*)
                 (some [and (ignored _!by) (isnt _!by s!by)] bads))
        (set-ip-ban s!ip t nil nil)))))

(def killallby (user) 
  (map [kill _ 'all] (submissions user)))

; Only called from repl.

(def kill-whole-thread (c)
  (kill c 'thread)
  (map kill-whole-thread:item c!kids))


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
    (urform (process-poll (striptags arg!t)
                          (md-from-form arg!x t)
                          (striptags arg!o))
      (tab
        (row "title"   (input "t" title 50))
        (row "text"    (textarea "x" 4 50 (only&pr text)))
        (row ""        "Use blank lines to separate choices:")
        (row "choices" (textarea "o" 7 50 (only&pr opts)))
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
  (let p (inst 'item 'type 'poll 'id (new-item-id)
                     'title title 'text text
                     'by (me) 'ip (ip))
    (= p!parts (map get!id (map [create-pollopt p nil nil _]
                                (paras opts))))
    (save-item p)
    (= (items* p!id) p)
    (push p stories*)
    p))

(def create-pollopt (p url title text)
  (let o (inst 'item 'type 'pollopt 'id (new-item-id)
                     'url url 'title title 'text text 'parent p!id
                     'by (me) 'ip (ip))
    (save-item o)
    (= (items* o!id) o)
    (vote-for o)
    o))

(def add-pollopt-page (p)
  (minipage "Add Poll Choice"
    (urform (do (add-pollopt p (striptags arg!x))
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
                               (pr (if (~blank o!title) o!title o!text)))
                             (if (and (~blank o!title) (~blank o!url))
                                 (link o!title o!url)
                                 (fontcolor black (pr o!text)))))))
  (tr (if n (td))
      (td)
      (tag (td class 'default)
        (spanclass comhead
          (itemscore o)
          (unvotelink o whence)
          (editlink o)
          (killlink o whence)
          (deletelink o whence)
          (deadmark o)))))


; Individual Item Page (= Comments Page of Stories)

(defmemo item-url (id (o anchor))
  (string (if id "item?id=") id (if anchor "#") anchor))

(newsop item (id)
  (let s (safe-item id)
    (if (news-type s)
        (do (if s!deleted (note-baditem))
            (item-page s))
        (do (note-baditem)
            (pr "No such item.")))))

(= baditemreqs* (table) baditem-threshold* 1/100)

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
  (with (title (and (cansee i)
                    (or i!title (aand i!text (ellipsize (striptags it)))))
         here (item-url i!id))
    (longpage (msec) nil nil title here
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
        (br2)))))

(def commentable (i) (in i!type 'story 'comment 'poll))

; By default the ability to comment on an item is turned off after 
; 45 days, but this can be overriden with commentable key.

(= commentable-threshold* (* 60 24 45))

(def comments-active (i)
  (and (live&commentable i)
       (live (superparent i))
       (or (< (item-age i) commentable-threshold*)
           (mem 'commentable i!keys))))


(= displayfn* (table))

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
  (when (and (cansee s)
             (in s!type 'story 'poll)
             (~blank s!text))
    (spacerow 2)
    (row "" s!text)))


; Edit Item

(def edit-url (i) (+ "edit?id=" i!id))

(newsop edit (id)
  (let i (safe-item id)
    (if (and i
             (cansee i)
             (editable-type i)
             (or (news-type i) (admin) (author i)))
        (edit-page i)
        (pr "No such item."))))

(def editable-type (i) (fieldfn* i!type))

(= fieldfn* (table))

(= (fieldfn* 'story)
   (fn (s)
     (with (a (admin)  e (editor)  x (canedit s))
       `((string1 title     ,s!title        t ,x)
         (url     url       ,s!url          t ,e)
         (mdtext2 text      ,s!text         t ,x)
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
         (yesno   dead      ,i!dead        ,e ,e)
         (yesno   deleted   ,i!deleted     ,a ,a)
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
                     (when (and (is name 'dead) val (no i!dead))
                       (log-kill i))
                     (= (i name) val)))
                 {do (if (admin) (pushnew 'locked i!keys))
                     (save-item i)
                     (metastory&adjust-rank i)
                     (wipe (comment-cache* i!id))
                     (edit-page i)})
      (hook 'edit i))))

(def ignore-edit (i name val)
  (case name title (len> val title-limit*)
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
  (if (~me)
       (flink {comment-login-warning parent whence text})
      (empty text)
       (flink {addcomment-page parent whence text retry*})
      (oversubmitting 'comment)
       (flink {msgpage toofast*})
       (atlet c (create-comment parent (md-from-form text))
         (comment-ban-test c text comment-kill* comment-ignore*)
         (if (bad-user) (kill c 'ignored/karma))
         (submit-item c)
         (string whence "#" c!parent))))

(def bad-user ((t u me))
  (or (ignored u) (< (karma u) comment-threshold*)))

(def create-comment (parent text)
  (newslog 'comment (parent 'id))
  (let c (inst 'item 'type 'comment 'id (new-item-id)
                     'text text 'parent parent!id
                     'by (me) 'ip (ip))
    (save-item c)
    (= (items* c!id) c)
    (push c!id parent!kids)
    (save-item parent)
    (push c comments*)
    c))


; Comment Display

(def display-comment-tree (c whence (o indent 0) (o initialpar) (o initialon))
  (when (cansee-descendant c)
    (display-1comment c whence indent initialpar initialon)
    (display-subcomments c whence (+ indent 1))))

(def display-1comment (c whence indent showpar showon)
  (tag (tr class "athing comtr" id c!id)
    (td (tab (display-comment nil c whence t indent showpar showon)))))

(def display-subcomments (c whence (o indent 0))
  (each k (ranked-kids c)
    (display-comment-tree k whence indent (> indent 0))))

(def display-comment (n c whence (o astree) (o indent 0)
                                 (o showpar) (o showon))
  (tr (display-item-number n)
      (when astree (tag (td class 'ind indent indent) (hspace (* indent 40))))
      (tag (td valign 'top class 'votelinks) (votelinks c whence t))
      (display-comment-body c whence astree indent showpar showon)))

; Comment caching doesn't make generation of comments significantly
; faster, but may speed up everything else by generating less garbage.

; It might solve the same problem more generally to make html code
; more efficient.

(= comment-cache* (table) comment-cache-timeout* (table) cc-window* 10000)

(= comments-printed* 0 cc-hits* 0)

(= comment-caching* t) 

; Cache comments generated for nil user that are over an hour old.
; Only try to cache most recent 10k items.  But this window moves,
; so if server is running a long time could have more than that in
; cache.  Probably should actively gc expired cache entries.

(def display-comment-body (c whence astree indent showpar showon)
  (++ comments-printed*)
  (if (and comment-caching*
           astree (no showpar) (no showon)
           (live c)
           (nor (admin) (editor) (author c))
           (< (- maxid* c!id) cc-window*)
           (> (- (seconds) c!time) 60)) ; was 3600
      (pr (cached-comment-body c whence indent))
      (gen-comment-body c whence astree indent showpar showon)))

(def cached-comment-body (c whence indent)
  (or (and (> (or (comment-cache-timeout* c!id) 0) (seconds))
           (awhen (comment-cache* c!id)
             (++ cc-hits*)
             it))
      (= (comment-cache-timeout* c!id)
          (cc-timeout c!time)
         (comment-cache* c!id)
          (tostring (gen-comment-body c whence t indent nil nil)))))

; Cache for the remainder of the current minute, hour, or day.

(def cc-timeout (t0)
  (let age (- (seconds) t0)
    (+ t0 (if (< age 3600)
               (* (+ (trunc (/ age    60)) 1)    60)
              (< age 86400)
               (* (+ (trunc (/ age  3600)) 1)  3600)
               (* (+ (trunc (/ age 86400)) 1) 86400)))))

(def gen-comment-body (c whence astree indent showpar showon)
  (tag (td class 'default)
    (let parent (and (or (no astree) showpar) (c 'parent))
      (tag (div style "margin-top:2px; margin-bottom:-10px; ")
        (spanclass comhead
          (itemline c whence)
          (deadmark c)
          (spanclass navs
            (when astree
              (rootlink c whence))
            (when parent
              (parentlink c whence indent))
            (when (or (no astree)
                      (headmatch "threads" whence))
              (unless (> indent 0)
                (contextlink c whence)))
            (when astree
              (prevlink c whence)
              (nextlink c whence))
            (editlink c)
            (killlink c whence)
            (blastlink c whence)
            (deletelink c whence)
            (unless (or astree (~me))
              (flaglink c whence))
            (spanclass onstory
              (when showon
                (pr " | on: ")
                (let s (superparent c)
                  (link (ellipsize s!title 50) (item-url s!id))))))))
      (when (or parent (cansee c))
        (br))
      (tag (div class 'comment)
        (tag (div class (string "commtext " (comment-class c)))
          (if (~cansee c) (pr (pseudo-text c))
              (pr c!text))))
      (when (and astree (cansee c) (live c))
        (para)
        (tag (font size 1)
          (if (and (~mem 'neutered c!keys)
                   (replyable c indent)
                   (comments-active c))
              (underline (replylink c whence))
              (fontcolor sand (pr "-----"))))))))

(def comment-navs (tops)
  (let nav (table)
    ((afn (sibs parent next-after root)
       (let vs (keep cansee-descendant sibs) ; only the ones that render
         (for j 0 (- (len vs) 1)
           (let c (vs j)
             (withs (prv (if (is j 0)
                             parent
                             ((vs (- j 1)) 'id))
                     nxt (if (>= j (- (len vs) 1))
                             next-after
                             ((vs (+ j 1)) 'id))
                     rt  (or root c!id)) ; top-level: c is its own root
               (= (nav c!id) (obj root rt prev prv next nxt))
               ; recurse: subtree's "next-after" is c's own next; root carries down
               (self (ranked-kids c) c!id nxt rt))))))
     tops nil nil nil)
    nav))

(def cnav (c key (t comment-nav))
  (aand (comment-nav c!id) (it key)))

(def root-comment (c) (cnav c 'root))

(def prev-comment (c) (cnav c 'prev))

(def next-comment (c) (cnav c 'next))

(def clickylink (text (o url text))
  (tag (a href url class 'clicky aria-hidden t)
    (pr text)))

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
         whence (or (only&urldecode whence) "news"))
    (if (only&comments-active i)
        (if user
            (addcomment-page i whence)
            (login-page 'both "You have to be logged in to comment."
                        {do (ensure-news-user)
                            (newslog 'comment-login)
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
       (withs (g ((comment-color c) 'r)
               x (coerce g 'string 16))
         (string "c" (if (len< x 2) "0") x))))

; Threads

(def threads-url ((t user me)) (+ "threads?id=" user))

(newsop threads (id)
  (if id
      (threads-page id)
      (pr "No user specified.")))

(def threads-page (user)
  (if (profile user)
      (withs (title (+ user "'s comments")
              label (if (me user) "threads" title)
              here  (threads-url user))
        (longpage (msec) nil label title here
          (awhen (user-comments user)
            (display-threads it label title here))))
      (prn "No such user.")))

(def user-comments ((t user me))
  (keep [and (cansee _) (~subcomment _)]
        (comments user maxend*)))

(def display-threads (comments label title whence
                      (o start 0) (o end threads-perpage*))
  (tab
    (let cs (cut comments start end)
      (w/the comment-nav (comment-navs cs)
        (each c cs
          (display-comment-tree c whence 0 t t))))
    (when end
      (let newend (+ end threads-perpage*)
        (when (and (<= newend maxend*) (< end (len comments)))
          (spacerow 10)
          (row (tab (tr (td (hspace 0))
                        (td (hspace votewid*))
                        (tag (td class 'title)
                          (morelink display-threads
                                    comments label title end newend))))))))))

(def submissions (user (o limit)) 
  (map item (firstn limit (uvar user submitted))))

(def comments (user (o limit))
  (map item (retrieve limit acomment:item (uvar user submitted))))
  
(def subcomment (c)
  (some [and (acomment _) (is _!by c!by) (no _!deleted)]
        (ancestors c)))

(def ancestors (i)
  (accum a (trav i!parent a:item self:!parent:item)))


; Submitted

(def submitted-url (user) (+ "submitted?id=" user))
       
(newsop submitted (id)
  (if id
      (submitted-page id)
      (pr "No user specified.")))

(def submitted-page (user)
  (if (profile user)
      (with (label (+ user "'s submissions")
             here  (submitted-url user))
        (longpage (msec) nil label label here
          (if (or (~ignored user)
                  (me user)
                  (seesdead))
              (aif (keep [metastory&cansee _]
                         (submissions user))
                   (display-items it label label here 0 perpage* t)))))
      (pr "No such user.")))


; RSS

(newsop rss () (w/me nil (rsspage)))

(newscache rsspage 90 
  (rss-stories (retrieve perpage* live ranked-stories*)))

(def rss-stories (stories)
  (tag (rss version "2.0")
    (tag channel
      (tag title (pr this-site*))
      (tag link (pr site-url*))
      (tag description (pr site-desc*))
      (each s stories
        (tag item
          (let comurl (+ site-url* (item-url s!id))
            (tag title    (pr (eschtml s!title)))
            (tag link     (pr (if (blank s!url) comurl (eschtml s!url))))
            (tag comments (pr comurl))
            (tag description
              (cdata (link "Comments" comurl)))))))))


; User Stats

(newsop leaders () (leaderspage))

(= nleaders* 20)

(newscache leaderspage 1000
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


(= update-avg-threshold* 0)  ; redefined later

(defbg update-avg 45
  (unless (or (empty profs*) (no stories*))
    (update-avg (rand-user [and (only&> (car (uvar _ submitted)) 
                                        (- maxid* initload*))
                                (len> (uvar _ submitted) 
                                      update-avg-threshold*)]))))

(def update-avg (user)
  (= (uvar user avg) (comment-score user))
  (save-prof user))

(def rand-user ((o test idfn))
  (evtil (rand-key profs*) test))

; Ignore the most recent 5 comments since they may still be gaining votes.  
; Also ignore the highest-scoring comment, since possibly a fluff outlier.

(def comment-score (user)
  (aif (check (nthcdr 5 (comments user 50)) [len> _ 10])
       (avg (cdr (sort > (map !score (rem !deleted it)))))
       nil))


; Comment Analysis

; Instead of a separate active op, should probably display this info 
; implicitly by e.g. changing color of commentlink or by showing the 
; no of comments since that user last looked.

(newsop active () (active-page))

(newscache active-page 600
  (listpage (msec) (actives) "active" "Active Threads"))

(def actives ((o n maxend*) (o consider 2000))
  (visible (rank-stories n consider (memo active-rank))))

(= active-threshold* 1500)

(def active-rank (s)
  (sum [max 0 (- active-threshold* (item-age _))]
       (cdr (family s))))

(def family (i) (cons i (mappend family:item i!kids)))


(newsop newcomments () (newcomments-page))

(newscache newcomments-page 60
  (listpage (msec) (visible (firstn maxend* comments*))
            "comments" "New Comments" "newcomments" nil))


; Doc

(defop formatdoc
  (msgpage formatdoc* "Formatting Options"))

(= formatdoc-url* "formatdoc")

(= formatdoc* 
"Blank lines separate paragraphs.
<p> Text after a blank line that is indented by two or more spaces is 
reproduced verbatim.  (This is intended for code.)
<p> Text surrounded by asterisks is italicized, if the character after the 
first asterisk isn't whitespace.
<p> Urls become links, except in the text field of a submission.<br><br>")


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
        (blank (uvar (me) email))
         (do (pr "Before you do this, please add your email address to your ")
             (underlink "profile" (user-url (me)))
             (pr ". Otherwise you could lose your account if you mistype
                  your new password.")))
    (br2)
    (uform (try-resetpw arg!p)
      (single-input "New password: " 'p 20 "reset" t))))

(def try-resetpw (newpw)
  (if (no (<= 8 (len newpw) 72))
      (resetpw-page "Passwords should be between 8 and 72 characters long.
                     Please choose another.")
      (do (set-pw (me) newpw)
          (newspage))))


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
                                     nil (+ "killed at " site) "badsites"))))
            (tdr (when deads (pr (round (days-since ((car deads) 'time))))))
            (td site)
            (td (w/rlink (do (set-site-ban site nil) "badsites")
                  (fontcolor (if ban gray!220 black) (pr "x"))))
            (td (w/rlink (do (set-site-ban site 'kill) "badsites")
                  (fontcolor (case ban kill darkred gray!220) (pr "x"))))
            (td (w/rlink (do (set-site-ban site 'ignore) "badsites")
                  (fontcolor (case ban ignore darkred gray!220) (pr "x"))))
            (td (each u (dedup (map !by deads))
                  (userlink u nil)
                  (pr " "))))))))

(defcache killedsites 300
  (let bads (table [each-loaded-item i
                     (awhen (and i!dead (sitename i!url))
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
           (awhen (and i!dead (check (sitename i!url) banned-sites*))
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
            (tdr (when (or (goods ip) (bads ip))
                   (pr (round (days-since 
                                (max (aif (car (goods ip)) it!time 0) 
                                     (aif (car (bads  ip)) it!time 0)))))))
            (tdr (onlink (len (bads ip))
                         (listpage (msec) (bads ip)
                                   nil (+ "dead from " ip) "badips")))
            (tdr (onlink (len (goods ip))
                         (listpage (msec) (goods ip)
                                   nil (+ "live from " ip) "badips")))
            (td (each u (subs ip)
                  (userlink u nil) 
                  (pr " "))))))))

(defcache badips 300
  (with (bads (table) goods (table))
    (each-loaded-item s
      (if (and s!dead (commentable s))
          (push s (bads  s!ip))
          (push s (goods s!ip))))
    (each (k v) bads  (zap rev (bads  k)))
    (each (k v) goods (zap rev (goods k)))
    (list bads goods)))

(def sorted-badips (bads goods)
  (withs (ips  (let ips (rem [len< (bads _) 2] (keys bads))
                (+ ips (rem [mem _ ips] (keys banned-ips*))))
          subs (table 
                 [each ip ips
                   (= (_ ip) (dedup (map !by (+ (bads ip) (goods ip)))))]))
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
  (display-selected-items [retrieve maxend* !dead _] "killed"))

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
      (each c (dedup (map downcase (trues [uvar _ topcolor] (users))))
        (tr (td c) (tdcolor (hex>color c) (hspace 30)))))))

(when (main)
  (nsv))

