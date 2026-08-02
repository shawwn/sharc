(defmemo sitename (url)
  (when (valid-url url)
    (let (:path netloc: host) (parse-url url)
      (zap downcase   host) ; hosts are case-insensitive
      (zap prune-port host) ; omit port number
      (if (ipv4-addr host) host (build-sitename host path)))))

(def prune-port (host)
  (car (cleave host (pos #\: host))))

(def ipv4-addr (host)
  (aand (all [or (digit _) (is _ #\.)] host)
        (tokens host #\.)
        (and (is (len it) 4)
             (all [len< _ 4] it))))

(def build-sitename (host path)
  (let (tld domain . subs) (split-host host)
    ; single-label hosts ("localhost", "http://foo/bar") have no
    ; sitename.  (+ nil "." tld) would be a list append, and error.
    (when domain
      (let site (parse-site-subdomain tld domain subs)
        (unless (match-site site exact-sites*)
          (= site (parse-site-username site path)))
        (unless (invalid-sitename site)
          site)))))

(def invalid-sitename (site)
  (is site "index.html")) ; https://news.ycombinator.com/item?id=29129111

(def split-host (host)
  (lets toks (rev (tokens host #\.))
    ; combine multi tld extension
    (when (match-site (car toks) multi-tld-countries*)
      (unless (match-site (+ (cadr toks) "." (car toks)) exact-sites*) ; "gob.ar"
        (let (t1 t2) (list (pop toks) (pop toks))
          (push (+ t2 "." t1) toks))))
    ; omit "www."
    (when (in (last toks) "www" nil)
      (zap almost toks))
    ; some domains like "dhan360.in" are incorrectly processed as
    ; multi-tld, so just split it back apart.  (toks can be empty for
    ; degenerate hosts like "http://www./x" or "https:///x".)
    (when (and toks (len< toks 2))
      (= toks (rev:tokens (car toks) #\.)))))

(def parse-site-subdomain (tld domain subs)
  (lets site (+ domain "." tld)
    (for i 0 1 ; to parse "colab.research.google.com"
      (unless (match-site site exact-sites*) ; exclude "gio.blog.archive.org"
        (when (and (car subs)
                   (or (and (is i 0) (match-site site long-domains*))
                       (match-site site subdomain-sites*)
                       (match-site (+ (car subs) "." site) subdomain-sites*)))
          (= site (+ (pop subs) "." site)))))))

(def parse-site-username (site path)
  (whenlet toks (tokens path #\/)
    (if (match-site site username-sites*)
         (when (valid-site-username (car toks))
           (= site (+ site "/" (trim-site-username (pop toks)))))
        (and (cadr toks) (match-site (+ site "/" (car toks)) username-sites*))
         (when (valid-site-username (cadr toks))
           (= site (+ site "/" (pop toks) "/" (trim-site-username (pop toks)))))))
  site)

(def trim-site-username (name)
   ; strip a leading @ or ~ from the username and downcase it
   (downcase (if (in (name 0) #\@ #\~) (cut name 1) name)))

(def valid-site-username (name)
  (or (is (name 0) #\@) ; https://medium.com/@inner.space/...
      ; see https://i.imgur.com/ROJwUYU.png
      ; and https://i.imgur.com/oX1oOz9.png
      (~pos [in _ #\. #\%] name)))

; to verify sitename matches scraped sitenames:
; arc> (time (verify-sitenames))

(def verify-sitenames ((o sitenames (urls-sites)))
  (let i 0 (find (fn ((url site))
                   (aand (sitename url)
                         (do1 (isnt it site)
                              (ero (list (++ i) it)))))
                 (rem ~cadr|ellipsized:cadr sitenames))))

(def urls-sites ()
  (accum a
    (each (name xs) hn-lists*
      (each i xs
        (unless (blank i!url)
          (a (list i!url i!site)))))))

(def ellipsized (s)
  (endmatch "..." s))

; --------------- sitename data ---------------------

(def match-site (site seq)
  ;(mem site seq) ; seq is a cons
  (seq site))     ; seq is a memtable

(def make-sites (seq)
  ;seq            ; as a cons
  (memtable seq)) ; as a memtable

(= multi-tld-countries*
   (make-sites
     '("uk" "jp" "au" "in" "ph" "tr" "za" "my" "nz" "br" 
       "mx" "th" "sg" "id" "pk" "eg" "il" "at" "pl" "ar"
       "uy" "np")))

(= long-domains*
   (make-sites
     '("blogspot" "wordpress" "livejournal" "blogs" "typepad" 
       "weebly" "posterous" "blog-city" "supersized" "dreamhosters"
       ; "sampasite"  "multiply" "wetpaint" ; all spam, just ban
       "eurekster" "blogsome" "edogo" "blog" "com")))


; sites where the exact match should pass through verbatim
(= exact-sites*
   (make-sites
     '("blog.archive.org" ; exclude "gio.blog.archive.org"
       "gob.ar" ; "http://en.mincyt.gob.ar/news/an-argentine-leap-forward-in-the-fight-against-cancer-9406"
       )))

; sites where the first path segment (a username) is part of the name
(= username-sites*
   (make-sites
     '("devblogs.microsoft.com"
       "github.com"
       "gitlab.com"
       "medium.com"
       "twitter.com"
       ;"x.com" ; breaks for "https://money.x.com/en"
       "buttondown.email"
       "codeberg.org"  ; see https://i.imgur.com/ROJwUYU.png
       "every.to"
       "bitbucket.org"
       "buttondown.com"
       "getrevue.co/profile"
       "forbes.com/sites"
       )))

; sites where the subdomain matters (name.github.io, not just github.io)
(= subdomain-sites*
   (make-sites
     '("apple.com"
       "substack.com"
       "google.com"
       "ycombinator.com"
       "openai.com"
       "wordpress.com"
       "wordpress.org"
       "blogspot.com"
       "twitter.com"
       "blogs.com"
       "livejournal.com"
       "google.dev"
       "com.ua" ; "https://iot-devices.com.ua/en/ggreg20-v3-j305-tube-mounting-dimensions/"
       "weebly.com"
       "com.cn" ; "https://www.chinadaily.com.cn/a/202510/18/WS68f3170ea310f735438b5bf2.html" "chinadaily.com.cn"
       "com.tw" ; "https://www.terasic.com.tw/cgi-bin/page/archive.pl?Language=English&No=1384" "terasic.com.tw"
       "ns.ca" ; "http://www.chebucto.ns.ca/~ak621/DOS/" "chebucto.ns.ca"
       "research.google.com"
       "typepad.com"
       "blog.gov.uk" ; "https://designnotes.blog.gov.uk/2022/12/12/making-the-gov-uk-frontend-typography-scale-more-accessible/" "designnotes.blog.gov.uk"
       "org.ru" ; "https://notes.valdikss.org.ru/linux-for-old-pc-from-2007/en/#Linux%20for%20PC%20from%202007" "valdikss.org.ru"
       "com.gh" ; "https://www.pulse.com.gh/bi/tech/activists-created-a-125-million-block-digital-library-in-minecraft-to-bypass/bn4gpcc" "pulse.com.gh"
       "google.nl"
       "blogspot.ca"
       "google.se"
       "dreamhosters.com"
       "google.fi"
       "blog.com"
       "google.org"
       "posterous.com"

       ; -----

       "ac.be"
       "ac.kr"
       "algolia.com"
       "altervista.org"
       "appspot.com"
       "blog.archive.org"
       "ashbyhq.com"
       "azurewebsites.net"
       "baidu.com"
       "bc.ca"
       "berkeley.edu"
       "bitbucket.org"
       "bittacklr.be"
       ; "blog.gov.uk"
       ; "blogspot.co.uk"
       "co.kr"
       "codeberg.org"
       "dataguru.hk"
       "deno.dev"
       "discourse.group"
       "edu.cn"
       "edu.hk"
       "edu.tw"
       "eth.limo"
       "eu.org"
       "eyer.be"
       "fandom.com"
       "fly.dev"
       "fmt.kr"
       "framer.app"
       "framer.website"
       "free.fr"
       "freehostia.com"
       "gc.ca"
       "ghost.io"
       "github.com"
       "gitlab.com"
       "glitch.me"
       "gnu.org"
       "go.com"
       "google.co.jp"
       "google.com"
       "google.com.au"
       "googleapis.com"
       "gov.uk"
       "gumroad.com"
       "herokuapp.com"
       "hey.com"
       "homeip.net"
       "icio.us"
       "iki.fi"
       "instagram.com"
       "jimdo.com"
       "js.org"
       "justletit.be"
       "kikirpa.be"
       "kuleuven.be"
       "locals.com"
       "logonfail.tw"
       "macrumors.com"
       "madewithlove.be"
       "meteor.com"
       "micro.blog"
       "mirror.xyz"
       "miso.kr"
       "mozilla.ai"
       "mozilla.com"
       "mozilla.org"
       "neocities.org"
       "netlify.com"
       ;"northeastern.edu"
       "news.northeastern.edu"
       "obsidian.md"
       "okno.be"
       "or.ke"
       "orange.tw"
       "org.tw"
       "oughta.be"
       "plaetinck.be"
       "popho.be"
       "posthaven.com"
       "priv.no"
       "prose.sh"
       "replit.app"
       "sci-hub.tw"
       "sciencemag.org"
       "sdf.org"
       "sebrechts.be"
       "squarespace.com"
       "srht.site"
       "strikingly.com"
       "svbtle.com"
       "teldap.tw"
       "telenet.be"
       "ttias.be"
       "tumblr.com"
       "twitter.com"
       "typepad.co.uk"
       "uantwerpen.be"
       ;"ucla.edu" ; "http://classes.dma.ucla.edu/Spring16/104/Banham_Gizmo.pdf" "ucla.edu"
       "newsroom.ucla.edu" ; "https://newsroom.ucla.edu/releases/owning-a-cell-phone-associated-with-poorer-reading-comprehension-schoolchildren" "newsroom.ucla.edu"
       ;"utoronto.ca"
       "utcc.utoronto.ca"
       "vidbuchanan.co.uk"
       "web.app"
       "webflow.io"
       ;"wolfram.com"
       "mathworld.wolfram.com"
       "wpcomstaging.com"
       "writeas.com"
       "xploregroup.be"
       "yobi.be"
       "yp.to"
       "yusu.ke"

       ; -----

       "vercel.app"
       "netlify.app"
       "ugent.be"
       "home.blog"
       "blogspot.co.uk"
       "beehiiv.com"
       "github.com"
       "medium.com"
       "microsoft.com"
       "onrender.com"
       "stackexchange.com"
       "workers.dev"
       "bearblog.dev"
       "pages.dev"
       "harvard.edu"
       "mit.edu"
       "bitbucket.io"
       "github.io"
       "gitlab.io"
       "itch.io"
       "readthedocs.io"
       "sourceforge.io"
       "glitch.me"
       "dreamwidth.org"
       "surge.sh"
       "notion.site"
       )))

