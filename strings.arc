; Matching.  Spun off 29 Jul 06.

; arc> (tostring (writec (coerce 133 'char)))
;
;> (define ss (open-output-string))
;> (write-char (integer->char 133) ss)
;> (get-output-string ss)
;"\u0085"

(def chars (s)
  (assert (in (type s) 'string 'vector))
  (coerce s 'cons))

(def hex (s)
  (assert (isa!int s))
  (coerce s 'string 16))

(def dehex (s)
  (assert (isa!string s))
  (coerce s 'int 16))

(def tokens (s (o sep whitec))
  (let test (testify sep)
    (let rec (afn (cs toks tok)
               (if (no cs)         (consif tok toks)
                   (test (car cs)) (self (cdr cs) (consif tok toks) nil)
                                   (self (cdr cs) toks (cons (car cs) tok))))
      (rev (map [coerce _ 'string]
                (map rev (rec (chars s) nil nil)))))))

; names of cut, split, halve not optimal

(def halve (s (o sep whitec))
  (let test (testify sep)
    (let rec (afn (cs tok)
               (if (no cs)         (list (rev tok))
                   (test (car cs)) (list cs (rev tok))
                                   (self (cdr cs) (cons (car cs) tok))))
      (rev (map [coerce _ 'string]
                (rec (chars s) nil))))))

; maybe promote to arc.arc, but if so include a list clause

(def positions (test seq)
  (accum a
    (let f (testify test)
      (forlen i seq
        (if (f (seq i)) (a i))))))

(def lines (s)
  (accum a
    ((afn ((p . ps))
       (if ps
           (do (a (rem #\return (cut s (+ p 1) (car ps))))
               (self ps))
           (a (cut s (+ p 1)))))
     (cons -1 (positions #\newline s)))))

(def slices (s test)
  (accum a
    ((afn ((p . ps))
       (if ps
           (do (a (cut s (+ p 1) (car ps)))
               (self ps))
           (a (cut s (+ p 1)))))
     (cons -1 (positions test s)))))

; > (require (lib "uri-codec.ss" "net"))
;> (form-urlencoded-decode "x%ce%bbx")
;"xλx"

; urlencode/urldecode operate on UTF-8 *bytes*, not characters: each
; %XX escape is one byte, and a non-ascii character spans several (e.g.
; λ is %ce%bb).  So we encode the string to its utf-8 bytes first, and
; decode by gathering the bytes back into a vector and utf8-decoding it.
; > (urldecode "x%ce%bbx") => "xλx"

(def urldecode (s)
  (bytes->utf8
    (accum a
      (forlen i s
        (caselet c (s i)
          #\+ (a 32)                             ; space
          #\% (do (when (> (edge s i) 2)
                    (a (int (cut s (+ i 1) (+ i 3)) 16)))
                  (++ i 2))
          (a (int c)))))))                       ; literal byte

(def bytes->utf8 (cs)
  (utf8-decode (coerce cs 'vector)))

(def urlencode (s)
  (tostring
    (each b (chars:utf8-encode s)
      (let c (coerce b 'char)
        (if (and (< b 128) (unreserved c))
            (writec c)
            (do (writec #\%)
                (if (< b 16) (writec #\0))
                (pr (coerce b 'string 16))))))))

(def unreserved (c)
  (or (alphadig c) (in c #\- #\. #\_ #\~)))

(mac litmatch (pat string (o start 0))
  (w/uniq (gstring gstart)
    `(with (,gstring ,string ,gstart ,start)
       (unless (> (+ ,gstart ,(len pat)) (len ,gstring))
         (and ,@(let acc nil
                  (forlen i pat
                    (push `(is ,(pat i) (,gstring (+ ,gstart ,i)))
                           acc))
                  (rev acc)))))))

; litmatch would be cleaner if map worked for string and integer args:

;             ,@(map (fn (n c)  
;                      `(is ,c (,gstring (+ ,gstart ,n))))
;                    (len pat)
;                    pat)

(mac endmatch (pat string)
  (w/uniq (gstring glen)
    `(withs (,gstring ,string ,glen (len ,gstring))
       (unless (> ,(len pat) (len ,gstring))
         (and ,@(let acc nil
                  (forlen i pat
                    (push `(is ,(pat (edge pat 1 i))
                               (,gstring (- ,glen 1 ,i)))
                           acc))
                  (rev acc)))))))

(def posmatch (pat seq (o start 0))
  (catch
    (if (isa!fn pat)
        (for i start (edge seq)
          (when (pat (seq i)) (throw i)))
        (for i start (edge seq (len pat))
          (when (headmatch pat seq i) (throw i))))
    nil))

(def headmatch (pat seq (o start 0))
  (let p (len pat) 
    ((afn (i)      
       (or (is i p) 
           (and (is (pat i) (seq (+ i start)))
                (self (+ i 1)))))
     0)))

(def begins (seq pat (o start 0))
  (unless (len> pat (edge seq start))
    (headmatch pat seq start)))

(def subst (new old seq)
  (let boundary (edge seq (len old) -1)
    (tostring 
      (forlen i seq
        (if (and (< i boundary) (headmatch old seq i))
            (do (++ i (edge old))
                (pr new))
            (pr (seq i)))))))

(def multisubst (pairs seq)
  (tostring 
    (forlen i seq
      (iflet (old new) (find [begins seq (car _) i] pairs)
        (do (++ i (edge old))
            (pr new))
        (pr (seq i))))))

; not a good name

(def findsubseq (pat seq (o start 0))
  (if (< (edge seq start) (len pat))
       nil
      (if (headmatch pat seq start)
          start
          (findsubseq pat seq (+ start 1)))))

(def blank (s) (~find ~whitec s))

(def nonblank (s) (unless (blank s) s))

(def trim (s (o where 'both) (o test whitec))
  (withs (f   (testify test)
           p1 (pos ~f s))
    (if p1
        (cut s 
             (if (in where 'front 'both) p1 0)
             (when (in where 'end 'both)
               (let i (edge s)
                 (while (and (> i p1) (f (s i)))
                   (-- i))
                 (+ i 1))))
        "")))

(def num (n (o digits 2) (o trail-zeros nil) (o init-zero nil) (o nocomma nil))
  (withs (comma
          (fn (i)
            (if nocomma
                (string i)
                (tostring
                  (map [apply pr (rev _)]
                       (rev (intersperse '(#\,)
                                         (tuples (rev (chars:string i))
                                                 3)))))))
          abrep
          (let a (abs n)
            (if (< digits 1)
                 (comma (roundup a))
                (exact a)
                 (string (comma a)
                         (when (and trail-zeros (> digits 0))
                           (string "." (newstring digits #\0))))
                 (withs (d (expt 10d0 digits)
                         m (/ (roundup (* a d)) d)
                         i (trunc m)
                         r (abs (trunc (- (* m d) (* i d)))))
                   (+ (if (is i 0) 
                          (if (or init-zero (is r 0)) "0" "") 
                          (comma i))
                      (withs (rest   (string r)
                              padded (+ (newstring (- digits (len rest)) #\0)
                                        rest)
                              final  (if trail-zeros
                                         padded
                                         (trim padded 'end [is _ #\0])))
                        (string (unless (empty final) ".")
                                final)))))))
    (if (and (< n 0) (find [and (digit _) (isnt _ #\0)] abrep))
        (+ "-" abrep)
        abrep)))

; Natural sort: order strings so that embedded numbers compare by value
; rather than by digit, e.g. "img2" before "img10".  The key splits a
; string into alternating chunks -- maximal digit runs become ints (compared
; numerically), everything else becomes a downcased string (so text compares
; case-insensitively).  E.g. "Img10a" -> ("img" 10 "a").

(def nat-chunks (cs)
  (when cs
    (let d (digit (car cs))
      (withs (n     (or (pos [isnt d (digit _)] cs) (len cs))
              chunk (coerce (cut cs 0 n) 'string)
              rest  (cut cs n))
        (cons (if d (int chunk) (downcase chunk))
              (nat-chunks rest))))))

(def nat-key (s) (nat-chunks:chars s))

; Compare two chunks.  Two ints compare numerically, two strings
; lexicographically; a number sorts before text when the types differ.

(def nat-chunk (cmp x y)
  (if (and (isa!int x) (isa!int y)) (cmp x y)
      (isa!int x)                   t
      (isa!int y)                   nil
                                    (cmp x y)))

(def natlist (cmp a b)
  (if (no a)  (if b t nil)          ; shorter key sorts first when otherwise equal
      (no b)  nil
      (nat-chunk cmp (car a) (car b)) t
      (nat-chunk cmp (car b) (car a)) nil
                                      (natlist cmp (cdr a) (cdr b))))

; Total order: fall back to a plain string compare so keys that are equal
; ignoring case (e.g. "A" and "a") still order deterministically.

(def nat (cmp a b)
  (if (natlist cmp (nat-key a) (nat-key b)) t
      (natlist cmp (nat-key b) (nat-key a)) nil
                                            (cmp a b)))

(def nat< (a b) (nat < a b))
(def nat> (a b) (nat > a b))

(def natsort  (xs) (sort nat< xs))
(def natsort> (xs) (sort nat> xs))

; English

(def pluralize (n str (o end "s"))
  (if (or (is n 1) (single n))
      str
      (string str end)))

(def plural (n x (o end "s"))
  (string n " " (pluralize n x end)))


; http://www.eki.ee/letter/chardata.cgi?HTML4=1
; http://jrgraphix.net/research/unicode_blocks.php?block=1
; http://home.tiscali.nl/t876506/utf8tbl.html
; http://www.fileformat.info/info/unicode/block/latin_supplement/utf8test.htm
; http://en.wikipedia.org/wiki/Utf-8
; http://unicode.org/charts/charindex2.html
