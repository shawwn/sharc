; HTML Utils. 


(def color (r g b)
  (let (r g b) (map [clamp _ 0 255] (list r g b))
    (obj r r g g b b)))

(defmemo hex>color (str)
  (and (is (len str) 6)
       (with (r (errsafe:dehex (cut str 0 2))
              g (errsafe:dehex (cut str 2 4))
              b (errsafe:dehex (cut str 4 6)))
         (and r g b
              (color r g b)))))

(defmemo gray (n) (color n n n))

(= white    (gray 255) 
   black    (gray 0)
   linkblue (color 0 0 190)
   orange   (color 255 102 0)
   darkred  (color 180 0 0)
   darkblue (color 0 0 120)
   )

(or= opmeths* (table))

(def opmeth (spec opt)
  (or (opmeths* (list spec opt))
      (case opt
        (id align valign) opsym
        (name type title) opstring
        (class style src) opstring
        (onclick onfocus) opstring
        (color bgcolor)   opcolor
        (width height)    opnum
        tabindex          opnum
        aria-hidden       opyesno
        spellcheck        opyesno
        autofocus         opyesno
        autocorrect       oponoff
        autocomplete      oponoff
        autocapitalize    oponoff)))

(mac attribute (tag opt f)
  `(= (opmeths* (list ',tag ',opt)) ,f))

(or= hexreps (table))

(for i 0 255 (= (hexreps i) (zeropad:hex i)))

(defmemo hexrep (col)
  (+ (hexreps (col 'r)) (hexreps (col 'g)) (hexreps (col 'b))))

(def opcolor (key val) 
  (w/uniq gv
    `(whenlet ,gv ,val
       (pr ,(string " " key "=\"#") (hexrep ,gv) #\"))))

(def opstring (key val)
  `(aif ,val (pr ,(+ " " key "=\"") (sanitize it) #\")))

(def opnum (key val)
  `(aif ,val (pr ,(+ " " key "=\"") (sanitize it) #\")))

(def opsym (key val)
  `(aif ,val (pr ,(+ " " key "=\"") (sanitize it) #\")))

(def opyesno (key val)
  `(case (downcase:string ,val)
     ("true" "t") (pr ,(+ " " key "=\"true\""))
     ("false")    (pr ,(+ " " key "=\"false\""))))

(def oponoff (key val)
  `(case (downcase:string ,val)
     ("on" "t") (pr ,(+ " " key "=\"on\""))
     ("off")    (pr ,(+ " " key "=\"off\""))))

(def opsel (key val)
  `(if ,val (pr " selected")))

(def opcheck (key val)
  `(if ,val (pr " checked")))

(def opesc (key val)
  `(awhen ,val (pr ,(string " " key "=\"")) (presc it) (pr  #\")))

(def uneschtml (str)
  (multisubst '(("&lt;"   "<")
                ("&gt;"   ">")
                ("&amp;"  "&")
                ("&quot;" "\"")
                ("&#x27;" "'")
                ("&#x2F;" "/")
                ("&#x3D;" "=")
                ("&nbsp;" " "))
              str))

(def uneschtml-char (s (o i))
  (if (litmatch "&lt;" s i)   (list #\< (+ i 4))
      (litmatch "&gt;" s i)   (list #\> (+ i 4))
      (litmatch "&amp;" s i)  (list #\& (+ i 5))
      (litmatch "&quot;" s i) (list #\" (+ i 6))
      (litmatch "&#x27;" s i) (list #\' (+ i 6))
      (litmatch "&#x2F;" s i) (list #\/ (+ i 6))
                              (list (s i) (+ i 1))))

(def eschtml-char (c)
  (case c
    #\<  "&lt;"
    #\>  "&gt;"
    #\&  "&amp;"
    #\"  "&quot;"
    #\'  "&#x27;"
    #\/  "&#x2F;"
    c))

(def eschtml (str)
  (tostring
    (each c str
      (pr (eschtml-char c)))))

(def sanitize (val)
  (case (type val)
    string (eschtml val)
    char   (eschtml-char val)
    sym    (sym:sanitize:string val)
           val))

(def presc args
  (apply pr (map sanitize args)))

(attribute a          href           opstring)
(attribute a          rel            opstring)
(attribute a          class          opstring)
(attribute a          id             opsym)
(attribute a          onclick        opstring)
(attribute a          n              opnum)
(attribute html       op             opstring)
(attribute body       alink          opcolor)
(attribute body       bgcolor        opcolor)
(attribute body       leftmargin     opnum)
(attribute body       link           opcolor)
(attribute body       marginheight   opnum)
(attribute body       marginwidth    opnum)
(attribute body       topmargin      opnum)
(attribute body       vlink          opcolor)
(attribute font       color          opcolor)
(attribute font       face           opstring)
(attribute font       size           opnum)
(attribute form       action         opstring)
(attribute form       method         opsym)
(attribute img        align          opsym)
(attribute img        border         opnum)
(attribute img        height         opnum)
(attribute img        width          opnum)
(attribute img        vspace         opnum)
(attribute img        hspace         opnum)
(attribute img        src            opstring)
(attribute input      name           opstring)
(attribute input      size           opnum)
(attribute input      type           opsym)
(attribute input      value          opesc)
(attribute input      checked        opcheck)
(attribute select     name           opstring)
(attribute option     selected       opsel)
(attribute table      bgcolor        opcolor)
(attribute table      border         opnum)
(attribute table      cellpadding    opnum)
(attribute table      cellspacing    opnum)
(attribute table      width          opstring)
(attribute textarea   cols           opnum)
(attribute textarea   name           opstring)
(attribute textarea   rows           opnum)
(attribute textarea   wrap           opsym)
(attribute td         align          opsym)
(attribute td         bgcolor        opcolor)
(attribute td         colspan        opnum)
(attribute td         width          opnum)
(attribute td         valign         opsym)
(attribute td         class          opstring)
(attribute td         timestamp      opnum)
(attribute td         indent         opnum)
(attribute tr         bgcolor        opcolor)
(attribute hr         color          opcolor)
(attribute span       class          opstring)
(attribute span       align          opstring)
(attribute span       id             opsym)
(attribute rss        version        opstring)
(attribute link       rel            opsym)
(attribute link       type           opsym)
(attribute link       href           opstring)


(mac gentag args (start-tag args))
     
(mac tag (spec . body)
  `(do ,(start-tag spec)
       ,@body
       ,(end-tag spec)))
     
(mac tag-if (test spec . body)
  `(if ,test
       (tag ,spec ,@body)
       (do ,@body)))

(def start-tag (spec)
  (if (atom spec)
      `(pr ,(string "<" spec ">"))
      (let opts (tag-options (car spec) (pair (cdr spec)))
        (if (all isa!string opts)
            `(pr ,(string "<" (car spec) (apply string opts) ">"))
            `(do (pr ,(string "<" (car spec)))
                 ,@(map [if (isa!string _) `(pr ,_) _] opts)
                 (pr ">"))))))

(def end-tag (spec)
  `(pr ,(string "</" (carif spec) ">")))

(def literal (x) 
  (case (type x)
    sym   (in x nil t)
    cons  (caris x 'quote)
          t))

; Returns a list whose elements are either strings, which can 
; simply be printed out, or expressions, which when evaluated
; generate output.

(def tag-options (spec options)
  (if (no options)
      '()
      (let ((opt val) . rest) options
        (if (isa opt 'key) (zap sym opt))
        (iflet meth (opmeth spec opt)
          (if val
              (cons (if (precomputable-tagopt val)
                        (tostring (eval (meth opt val)))
                        (meth opt val))
                    (tag-options spec rest))
              (tag-options spec rest))
          (do
            (pr "<!-- ignoring " opt " for " spec "-->")
            (tag-options spec rest))))))

(def precomputable-tagopt (val)
  (and (literal val) 
       (no (and (is (type val) 'string) (find #\@ val)))))

(def br ((o n 1))
  (repeat n (pr "<br>"))
  (prn))

(def br2 () (prn "<br><br>"))

(mac center    body         `(tag center ,@body))
(mac underline body         `(tag u ,@body))
(mac tab       body         `(tag (table border 0) ,@body))
(mac tr        body         `(tag tr ,@body))

(let pratoms (fn (body)
               (if (or (no body) 
                       (all [and (acons _) (isnt (car _) 'quote)]
                            body))
                   body
                   `((pr ,@body))))

  (mac td       body         `(tag td ,@(pratoms body)))
  (mac trtd     body         `(tr (td ,@(pratoms body))))
  (mac tdr      body         `(tag (td align 'right) ,@(pratoms body)))
  (mac tdcolor  (col . body) `(tag (td bgcolor ,col) ,@(pratoms body)))
)

(mac row args
  `(tr ,@(map [list 'td _] args)))

(mac prrow args
  (w/uniq (g x)
    `(tr ,@(map (fn (a) 
                  `(withs (,g nil ,x (tostring (= ,g ,a)))
                     (if (~empty ,x)
                          (td (pr ,x))
                         (number ,g)
                          (tdr (pr ,g))
                          (td (pr ,g)))))
                 args))))

(mac prbold body `(tag b (pr ,@body)))

(def para args 
  (gentag p)
  (when args (apply pr args)))

(def menu (name items (o sel nil))
  (tag (select name name)
    (each i items
      (tag (option selected (is i sel))
        (presc i)))))

(mac whitepage body
  `(tag html 
     (tag (body bgcolor white alink linkblue) ,@body)))

(def errpage args (whitepage (apply prn args)))

(def blank-url () "s.gif")

; Could memoize these.

; If h = 0, doesn't affect table column widths in some Netscapes.

(def hspace (n)    (gentag img src (blank-url) height 1 width n))
(def vspace (n)    (gentag img src (blank-url) height n width 0))
(def vhspace (h w) (gentag img src (blank-url) height h width w))

(mac new-hspace (n)
  (if (number n)
      `(pr ,(string "<span style=\"padding-left:" n "px\" />"))
      `(pr "<span style=\"padding-left:" ,n "px\" />")))

;(def spacerow (h) (tr (td (vspace h))))

(def spacerow (h (o class))
  (tag (tr class class style "height:@{h}px")))

; For use as nested table.

(mac zerotable body
  `(tag (table border 0 cellpadding 0 cellspacing 0)
     ,@body))

; was `(tag (table border 0 cellpadding 0 cellspacing 7) ,@body)

(mac sptab body
  `(tag (table style "border-spacing: 7px 0px;") ,@body))

(mac widtable (w . body)
  `(tag (table width ,w) (tr (td ,@body))))

(def cellpr (x) (pr (or x "&nbsp;")))

(def but ((o text "submit") (o name nil))
  (gentag input type 'submit name name value text))

(def submit ((o val "submit"))
  (gentag input type 'submit value val))

(def buts (name . texts)
  (if (no texts)
      (but)
      (do (but (car texts) name)
          (each text (cdr texts)
            (pr " ")
            (but text name)))))

(mac spanrow (n . body)
  `(tr (tag (td colspan ,n) ,@body)))

(mac form (action . body)
  `(tag (form method "post" action ,action) ,@body))

(mac textarea (name rows cols . body)
  `(tag (textarea name ,name rows ,rows cols ,cols) ,@body))

(def input (name (o val "") (o size 10) (o type 'text))
  (gentag input type type name name value val size size))

(mac inputs args
  `(tag (table border 0)
     ,@(map (fn ((name label len text . options))
              (w/uniq gl
                `(let ,gl ,len
                   (tr (td (pr ',label ":"))
                       (if (isa!cons ,gl)
                           (td (textarea ',name (car ,gl) (cadr ,gl)
                                 (aif ,text (pr it))))
                           (td (gentag input type ',(if (is label 'password) 
                                                    'password 
                                                    'text)
                                         name ',name 
                                         size ,len 
                                         value ,text
                                         ,@options)))))))
            args)))

(def single-input (label name chars btext (o pwd))
  (pr label)
  (gentag input type (if pwd 'password 'text) name name size chars)
  (sp)
  (submit btext))

(def hidden-input (name value)
  (gentag input type 'hidden name name value value))

(mac cdata body
  `(do (pr "<![CDATA[") 
       ,@body
       (pr "]]>")))

(def nbsp () (pr "&nbsp;"))

(def link (text (o dest text) (o id))
  (tag (a id id href dest)
    (presc text)))

(def underlink (text (o dest text))
  (tag (a href dest) (tag u (presc text))))

(def striptags (s)
  (let intag nil
    (tostring
      (each c s
        (if (is c #\<) (set intag)
            (is c #\>) (wipe intag)
            (no intag) (pr c))))))

(def shortlink (url)
  (unless (or (no url) (< (len url) 7))
    (link (cut url 7) url)))

; this should be one regexp

(def parafy (str)
  (let ink nil
    (tostring
      (each c str
        (pr c)
        (unless (whitec c) (set ink))
        (when (is c #\newline)
          (unless ink (pr "<p>"))
          (wipe ink))))))

(mac spanclass (name . body)
  `(tag (span class ',name) ,@body))

(def pagemessage (text)
  (when text (prn text) (br2)))

; Could be stricter.  Memoized because looking for chars in Unicode
; strings is terribly inefficient in Mzscheme.

(defmemo valid-url (url)
  (and (len> url 10)
       (or (begins url "http://")
           (begins url "https://"))))

(def parse-url (url (o allow-fragments t))
  (let (scheme netloc url query fragment) (urlsplit url allow-fragments)
    (obj scheme   (or scheme "")
         netloc   (or netloc "")
         path     (or url "")
         query    (or query "")
         fragment (or fragment ""))))

(def urlsplit (url (o allow-fragments t))
  (let (scheme netloc query fragment) nil
    (whenlet i (pos #\: url)
      (when (and (> i 0) (letter (url 0)))
        (= scheme (downcase (cut url 0 i))
           url    (cut url (+ i 1)))))
    (when (begins url "//")
      (= (list netloc url) (split-netloc url 2)))
    (when allow-fragments
      (whenlet p (pos #\# url)
        (= (list url fragment) (cleave url p))))
    (whenlet p (pos #\? url)
      (= (list url query) (cleave url p)))
    (list scheme netloc url query fragment)))

(def split-netloc (url (o start 0))
  (iflet delim (pos [in _ #\/ #\? #\#] url start)
         (list (cut url start delim) (cut url delim))
         (list (cut url start) "")))

(mac fontcolor (c . body)
  (w/uniq g
    `(let ,g ,c
       (if ,g
           (tag (font color ,g) ,@body)
           (do ,@body)))))
