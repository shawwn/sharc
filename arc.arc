; Main Arc lib.  Ported to Scheme version Jul 06.

; don't like names of conswhen and consif

; need better way of generating strings; too many calls to string
;  maybe strings with escape char for evaluation
; make foo~bar equiv of foo:~bar (in expand-ssyntax)
; add sigs of ops defined in arc0.lisp
; get hold of error types within arc
; does macex have to be defined in scheme instead of using def below?
; write disp, read, write in arc
; could I get all of macros up into arc.arc?
; warn when shadow a global name
; some simple regexp/parsing plan

; compromises in this implementation: 
; no objs in code
;  (mac testlit args (listtab args)) breaks when called
; separate string type
;  (= (cdr (cdr str)) "foo") couldn't work because no way to get str tail
;  not sure this is a mistake; strings may be subtly different from 
;  lists of chars


(assign %brackets (annotate 'mac
                    (fn args `(fn (_) ,args))))

(assign %braces (annotate 'mac
                  (fn args `(fn () ,args))))

(assign do (annotate 'mac
             (fn args `(%do ,@args))))

(assign warnset (fn (var) nil))

(assign safeset (annotate 'mac
                  (fn (var val)
                    `(do (if (bound ',var)
                             (warnset ',var))
                         (assign ,var ,val)))))

(assign mac (annotate 'mac
              (fn (name parms . body)
                `(do (sref sig ',parms ',name)
                     (safeset ,name (annotate 'mac (fn ,parms ,@body)))))))

(mac com (e) (eval e))

(mac def (name x . body)
  (if (is body nil)
      `(safeset ,name ,x)
      `(do (sref sig ',x ',name)
           (safeset ,name (fn ,x ,@body)))))

(def caar (xs) (car (car xs)))
(def cadr (xs) (car (cdr xs)))
(def cddr (xs) (cdr (cdr xs)))

(def no (x) (is x nil))

(def anan (x) (no (is x x)))

; acons is an xdef in arc0.lisp; it used to be (is (type x) 'cons) here.

(def atom (x) (no (acons x)))

(def reduce (f xs)
  (if (no (cdr xs))
      (car xs)
      (f (car xs) (reduce f (cdr xs)))))

(def cons args
  (reduce join args))

(def snoc args
  (+ (car args) (cdr args)))

(def consif (x y) (if x (cons x y) y))

(def snocif (x y) (if y (snoc x y) x))

(def list args args)

(def copylist (x) (apply list x))

(def idfn (x) x)

(def only (x . args) x) ; (only&pr maybe-nil)

(def as (kind)
  (fn (x . args)
    (apply coerce x kind args)))

(def map0 (f xs)
  (if xs (do (f (car xs)) (map0 f (cdr xs)))))

(def rev (xs (o acc))
  (if (no xs)
      acc
      (rev (cdr xs) (cons (car xs) acc))))

; roughly 3x faster than rev

(def rev! (xs (o self))
  (assign self (fn (prev tail)
                 (if (no tail)
                     prev
                     ((fn (next)
                        (if (ex next xs) (err "Circular list"))
                        (scdr tail prev)
                        (self tail next))
                      (cdr tail)))))
  (self nil xs))

; Maybe later make this internal.  Useful to let xs be a fn?

(def map1 (f xs (o acc))
  (if (no xs) 
      (rev! acc)
      (map1 f (cdr xs) (cons (f (car xs)) acc))))

(def pair (xs (o f list) (o acc))
  (if (no xs)       (rev! acc)
      (no (cdr xs)) (rev! (cons (f (car xs)) acc))
                    (pair (cddr xs) f
                          (cons (f (car xs) (cadr xs))
                                acc))))

(mac and args
  (if (cdr args)
       `(if ,(car args) (and ,@(cdr args)))
      args
       (car args)
       't))

(def assoc (key al)
  (if (atom al)
       nil
      (and (acons (car al)) (is (caar al) key))
       (car al)
      (assoc key (cdr al))))

(def alref (al key) (cadr (assoc key al)))

(mac with (parms . body)
  `((fn ,(map1 car (pair parms))
     (do ,@body))
    ,@(map1 cadr (pair parms))))

(mac let (var val . body)
  `(with (,var ,val) ,@body))

(mac withs (parms . body)
  (if (no parms) 
      `(do ,@body)
      `(let ,(car parms) ,(cadr parms) 
         (withs ,(cddr parms) ,@body))))

(mac lets (var val . body)
  `(let ,var ,val
     ,@body
     ,var))

(mac rfn (name parms . body)
  `(let ,name nil
     (assign ,name (fn ,parms ,@body))))

(mac afn (parms . body)
  `(rfn self ,parms ,@body))

; Ac expands x:y:z into (compose x y z), ~x into (complement x)

; Only used when the call to compose doesn't occur in functional position.  
; Composes in functional position are transformed away by ac.

(mac compose args
  (let g (uniq 'g)
    `(fn ,g
       ,((afn (fs)
           (if (cdr fs)
               (list (car fs) (self (cdr fs)))
               `(apply ,(if (car fs) (car fs) 'idfn) ,g)))
         args))))

; Ditto: complement in functional position optimized by ac.

(mac complement (f)
  (let g (uniq 'g)
    `(fn ,g (no (apply ,f ,g)))))

(def isnt (x y) (no (is x y)))

(mac w/uniq (names . body)
  (if (acons names)
      `(with ,(apply + nil (map1 (fn (n) (list n `(uniq ',n)))
                             names))
         ,@body)
      `(let ,names (uniq ',names) ,@body)))

(mac or args
  (and args
       (w/uniq g
         `(let ,g ,(car args)
            (if ,g ,g (or ,@(cdr args)))))))

(mac check (x test (o alt))
  (w/uniq gx
    `(let ,gx ,x
       (if (,test ,gx) ,gx ,alt))))

(def alist (x) (or (no x) (is (type x) 'cons)))

(mac in (x . choices)
  (w/uniq g
    `(let ,g ,x
       (or ,@(map1 (fn (c) `(is ,g ,c)) choices)))))

(mac when (test . body)
  `(if ,test (do ,@body)))

(mac unless (test . body)
  `(if (no ,test) (do ,@body)))

(def accumulator ((o l))
  (fn xs
    (if (cdr xs) (assign l (cons xs l))
        xs       (assign l (cons (car xs) l))
                 (lets r l
                   (assign l nil)))))

(mac accumulate (accfn . body)
  `(let ,accfn (accumulator)
     ,@body
     (,accfn)))

(mac accum (accfn . body)
  `(rev! (accumulate ,accfn ,@body)))

(mac point-default (name default . body)
  (w/uniq (k val)
    `(ccc (fn (,k)
            (let ,name (fn ((o ,val ,default)) (,k ,val))
              ,@(snocif body default))))))

(mac point (name . body)
  `(point-default ,name nil ,@body))

(mac catch body
  `(point throw ,@body))

(mac w/break body
  `(let out (accumulator)
     (point-default break (rev! (out))
       ,@body)))

(mac loop (var init update test . body)
  (w/uniq v
    `(w/break
       ((rfn ,v (,var)
          (when ,test ,@body (,v ,update)))
        ,init))))

(mac for (var init max . body)
  (w/uniq (gi gm)
    `(withs (,gi ,init ,gm (+ ,max 1))
       (loop ,var ,gi (+ ,var 1) (< ,var ,gm)
         ,@body))))

(mac down (var init min . body)
  (w/uniq (gi gm)
    `(withs (,gi ,init ,gm (- ,min 1))
       (loop ,var ,gi (- ,var 1) (> ,var ,gm)
         ,@body))))

(mac repeat (n . body)
  `(for ,(uniq 'i) 1 ,n ,@body))

(mac forlen (var s . body)
  `(for ,var 0 (edge ,s) ,@body))

(mac on (var s . body)
  (if (is var 'index)
      (err "Can't use index as first arg to `on`")
      `(let index 0
         (each ,var ,s
           ,@body
           (assign index (+ index 1))))))

(mac each (var expr . body)
  `(w/break
     (across ,expr (fn (,var) ,@body))))

(def across (l f)
  (if (alist l)
       (map0 f l)
      (isa!table l)
       (maptable (fn args (f args)) l)
       (forlen i l
         (f (l i)))))

(def mapv (f seq)
  (if (isa!table seq)
      (lets h (table)
        (each (k v) seq
          (sref h (f v) k)))
      (map f seq)))

(def iso args (apply is args)) ; kept for backwards compatibility

(mac whilet (var test . body)
  (w/uniq gf
    `(w/break
       ((rfn ,gf (,var)
          (when ,var ,@body (,gf ,test)))
        ,test))))

(mac while (test . body)
  `(whilet ,(uniq 'while) ,test ,@body))

(def empty (seq) 
  (or (no seq) 
      (and (in (type seq) 'string 'table)
           (is (len seq) 0))))

(def reclist (f xs)
  (and xs (or (f xs) (reclist f (cdr xs)))))

(def recstring (test s (o start 0))
  ((afn (i)
     (and (< i (len s))
          (or (test i)
              (self (+ i 1)))))
   start))

(def testify (x (o same is))
  (if (and (is same is) (in (type x) 'fn 'table))
      x
      [same _ x]))

(def some (test seq (o same is))
  (let f (testify test same)
    (if (alist seq)
        (reclist f:car seq)
        (recstring f:seq seq))))

(def all (test seq (o same is))
  (~some (complement (testify test same)) seq))

(def mem (test seq (o same is))
  (let f (testify test same)
    (reclist f:car&idfn seq)))

(def find (test seq (o same is))
  (let f (testify test same)
    (if (alist seq)
        (reclist   f:car&car seq)
        (recstring f:seq&seq seq))))

(def isa (x . y)
  (if y
      (if (mem (type x) y) t) ; e.g. (isa x 'int 'string)
      [is (type _) x]))       ; e.g. (isa!int x)

; Possible to write map without map1, but makes News 3x slower.

;(def map (f . seqs)
;  (if (some1 no seqs)
;       nil
;      (no (cdr seqs))
;       (let s1 (car seqs)
;         (cons (f (car s1))
;               (map f (cdr s1))))
;      (cons (apply f (map car seqs))
;            (apply map f (map cdr seqs)))))


(def map (f . seqs)
  (if (some isa!string seqs)
       (withs (n   (apply min (map len seqs))
               new (newstring n))
         ((afn (i)
            (if (is i n)
                new
                (do (sref new (apply f (map [_ i] seqs)) i)
                    (self (+ i 1)))))
          0))
      (no (cdr seqs)) 
       (map1 f (car seqs))
      ((afn (seqs acc)
        (if (some no seqs)  
            (rev! acc)
            (self (map1 cdr seqs)
                  (cons (apply f (map1 car seqs))
                        acc))))
       seqs nil)))

(def zip args (apply map list args))

(def mappend (f . args)
  (apply + nil (apply map f args)))

(def firstn (n xs)
  (if (no n) xs
    ((afn (n xs acc)
       (if (and (> n 0) xs)
           (self (- n 1) (cdr xs) (cons (car xs) acc))
           (rev! acc)))
     n xs nil)))

(def lastn (n xs)
  (if (no n) xs
    ((afn (n xs)
       (if (and (> n 0) xs)
           (self (- n 1) (cdr xs))
           xs))
     (edge xs n) xs)))

(def nthcdr (n xs)
  (if (no n)  xs
      (> n 0) (nthcdr (- n 1) (cdr xs))
              xs))

; Generalization of pair: (tuples x) = (pair x)

(def tuples (xs (o n 2))
  ((afn (xs acc)
     (if (no xs)
         (rev! acc)
         (self (nthcdr n xs) (cons (firstn n xs) acc))))
   xs nil))

; If ok to do with =, why not with def?  But see if use it.

(mac defs args
  `(do ,@(map [cons 'def _] (tuples args 3))))

(def caris (x val) 
  (and (acons x) (is (car x) val)))

(def warn (msg . args)
  (disp (+ "Warning: " msg ". "))
  (map0 [do (write _) (disp " ")] args)
  (disp #\newline))

(mac atomic body
  `(atomic-invoke {do ,@body}))

(mac atlet args
  `(atomic (let ,@args)))

(mac atlets args
  `(atomic (lets ,@args)))
  
(mac atwith args
  `(atomic (with ,@args)))

(mac atwiths args
  `(atomic (withs ,@args)))

; lock priorities:
;
;  0    *arc-mutex*      atomic
; 10    submit-lock*     submitting items
; 11    vote-locks*      voting for items
; 12    rank-lock*       ranked-stories*
; 20    minid-lock*      decrementing minid*
; 21    maxuid-lock*     incrementing maxuid*
; 22    save-locks*      saving tables
; 23    ignore-log-lock* ignore log
; 24    fnid-lock*       fnids
; 25    queue-lock*      enq, deq, etc
; 30    scrape-lock*     last-fetch-time*
; 40    place-lock*      all setforms operations
; 5x    output locks     ero, srvlog, scrapelog
; 51    log-lock*        srvlog
; 52    scrapelog-lock*  scrapelog
; 59    ero-lock*        ero
; 99    table locks      implicit, leaf

(def make-lock ((o priority 99) (o name nil))
  (lets lock (table)
    (sref lock 'lock    'type)
    (sref lock name     'name)
    (sref lock priority 'priority)
    (set-lock-level lock priority)))

(def alock (x)
  (and (isa!table x) (is x!type 'lock)))

(def lockable (l)
  (check l alock (err "Not a lock" l)))

(mac w/lock (x . body)
  `(call-w/lock ,x {do ,@body}))

(def call-w/lock (x thunk)
  (call-w/locked-table (lockable x) thunk))

(mac w/lock-when (lock expr . body)
  `(when ,expr
     (w/lock ,lock
       (when ,expr
         ,@body))))

(mac w/lock-or (lock expr . body)
  `(or ,expr
       (w/lock ,lock
         (or ,expr ,@body))))

; setforms returns (vars get set) for a place based on car of an expr
;  vars is a list of gensyms alternating with expressions whose vals they
;   should be bound to, suitable for use as first arg to withs
;  get is an expression returning the current value in the place
;  set is an expression representing a function of one argument
;   that stores a new value in the place

; A bit gross that it works based on the *name* in the car, but maybe
; wrong to worry.  Macros live in expression land.

; seems meaningful to e.g. (push 1 (pop x)) if (car x) is a cons.
; can't in cl though.  could I define a setter for push or pop?

(assign setter (table))

(mac defset (name parms . body)
  (w/uniq gexpr
    `(sref setter 
           (fn (,gexpr)
             (let ,parms (cdr ,gexpr)
               ,@body))
           ',name)))

(mac defplace (name place)
  `(defset ,name args
     (list (list)
           (apply ,place args)
           `(fn (val) (= ,(apply ,place args) val)))))

(defset car (x)
  (w/uniq g
    (list (list g x)
          `(car ,g)
          `(fn (val) (scar ,g val)))))

(defset cdr (x)
  (w/uniq g
    (list (list g x)
          `(cdr ,g)
          `(fn (val) (scdr ,g val)))))

(defset caar (x)
  (w/uniq g
    (list (list g x)
          `(caar ,g)
          `(fn (val) (scar (car ,g) val)))))

(defset cadr (x)
  (w/uniq g
    (list (list g x)
          `(cadr ,g)
          `(fn (val) (scar (cdr ,g) val)))))

(defset cddr (x)
  (w/uniq g
    (list (list g x)
          `(cddr ,g)
          `(fn (val) (scdr (cdr ,g) val)))))

; Note: if expr0 macroexpands into any expression whose car doesn't
; have a setter, setforms assumes it's a data structure in functional 
; position.  Such bugs will be seen only when the code is executed, when 
; sref complains it can't set a reference to a function.

(def setforms (expr0)
  (let expr (macex expr0)
    (if (isa!sym expr)
         (if (ssyntax expr)
             (setforms (ssexpand expr))
             (w/uniq (g h)
               (list (list g expr)
                     g
                     `(fn (,h) (assign ,expr ,h)))))
        ; make it also work for uncompressed calls to compose
        (and (acons expr) (metafn (car expr)))
         (setforms (expand-metafn-call (ssexpand (car expr)) (cdr expr)))
        (and (acons expr) (acons (car expr)) (is (caar expr) 'get))
         (setforms (list (cadr expr) (cadr (car expr))))
         (let f (setter (car expr))
           (if f
               (f expr)
               ; assumed to be data structure in fn position
               (do (when (caris (car expr) 'fn)
                     (warn "Inverting what looks like a function call"
                           expr0 expr))
                   (w/uniq (g h)
                     (let argsyms (map [uniq 'arg] (cdr expr))
                        (list (+ (list g (car expr))
                                 (mappend list argsyms (cdr expr)))
                              `(,g ,@argsyms)
                              `(fn (,h) (sref ,g ,h ,(car argsyms))))))))))))

(def metafn (x)
  (or (ssyntax x)
      (and (acons x) (in (car x) 'compose 'complement))))

(def expand-metafn-call (f args)
  (if (is (car f) 'compose)
       ((afn (fs)
          (if (caris (car fs) 'compose)            ; nested compose
               (self (join (cdr (car fs)) (cdr fs)))
              (cdr fs)
               (list (car fs) (self (cdr fs)))
              (cons (car fs) args)))
        (cdr f))
      (is (car f) 'no)
       (err "Can't invert" (cons f args))
       (cons f args)))

(unless (bound 'place-lock*)
  (assign place-lock* (make-lock 40 "place")))

(mac w/place-lock body
  `(w/lock place-lock* ,@body))

(mac placewiths (binds . body)
  `(w/place-lock (withs ,binds ,@body)))

; Evaluate the place's subforms and the new value OUTSIDE place-lock*,
; and hold the lock only across the store.  Plain = performs no read of
; the place (note `prev`, the getter, is unused below), so there is no
; read-modify-write window to protect, unlike ++ / push / pop / swap /
; rotate, whose getters must stay inside the lock.
;
; This matters because `val` is arbitrary caller code.  Evaluating it
; under the lock meant any assignment whose value reached another lock
; below place-lock* in the hierarchy raised a lock-order violation, and
; any assignment whose value did I/O held place-lock* across it, blocking
; every other assignment in the image.  scrape.arc's
; (= (hn-lists* name) (scrape-hn-list name)) did both: it held the lock
; across a multi-second HTTP fetch and then tried to take scrape-lock*.

(def expand= (place val)
  (if (and (isa!sym place) (~ssyntax place))
      `(assign ,place ,val)
      (let (vars prev setter) (setforms place)
        (w/uniq g
          `(withs ,(+ vars (list g val))
             (w/place-lock (,setter ,g)))))))

(def expand=list (terms)
  `(do ,@(map (fn ((p v)) (expand= p v))  ; [apply expand= _]
                  (pair terms))))

(mac = args
  (expand=list args))

(def clamp (n lo hi)
  (if (< n lo) lo
      (> n hi) hi
      n))

; (nthcdr x y) = (cut y x).

(def cut1 (seq start (o end))
  (let end (or end (len seq))
    (if (isa!string seq)
        (lets s2 (newstring (- end start))
          (for i 0 (- end start 1)
            (= (s2 i) (seq (+ start i)))))
        (firstn (- end start) (nthcdr start seq)))))

; optimization at the expense of Arc purity

(def cut2 (seq start (o end))
  (let end (if end (min end (len seq)))
    (#'subseq seq start end)))

(def cut cut2) ; use the optimized version

(def edge (xs (o i 1) . n)
  (apply - (len xs) i n))

(def almost (xs) (cut xs 0 (edge xs)))

(def last (xs)
  (if (cdr xs)
      (last (cdr xs))
      (car xs)))

(def rem (test seq (o same is))
  (let f (testify test same)
    (if (alist seq)
        ((afn (s acc)
           (if (no s)       (rev! acc)
               (f (car s))  (self (cdr s) acc)
                            (self (cdr s) (cons (car s) acc))))
          seq nil)
        (coerce (rem test (as!cons seq) same) (type seq)))))

; Seems like keep doesn't need to testify-- would be better to
; be able to use tables as fns.  But rem does need to, because
; often want to rem a table from a list.  So maybe the right answer
; is to make keep the more primitive, not rem.

(def keep (test seq (o same is))
  (rem (complement (testify test same)) seq))

;(def trues (f seq) 
;  (rem nil (map f seq)))

(def trues (f xs)
  ((afn (xs acc)
     (if (no xs)
         (rev! acc)
         (let fx (f (car xs))
           (if fx
               (self (cdr xs) (cons fx acc))
               (self (cdr xs) acc)))))
   xs nil))

(mac do1 args
  (w/uniq g
    `(lets ,g ,(car args)
       ,@(cdr args))))

; Would like to write a faster case based on table generated by a macro,
; but can't insert objects into expansions in Mzscheme.

(mac caselet (var expr . args)
  (let ex (afn (args)
            (if (no (cdr args))
                (car args)
                `(if ,(if (acons (car args))
                          `(in ,var ,@(map [list 'quote _] (car args)))
                          `(is ,var ',(car args)))
                     ,(cadr args)
                     ,(self (cddr args)))))
    `(let ,var ,expr ,(ex args))))

(mac case (expr . args)
  `(caselet ,(uniq 'x) ,expr ,@args))

(mac push (x place)
  (w/uniq gx
    (let (binds val setter) (setforms place)
      `(let ,gx ,x
         (placewiths ,binds
           (,setter (cons ,gx ,val)))))))

(mac swap (place1 place2)
  (w/uniq (g1 g2)
    (with ((binds1 val1 setter1) (setforms place1)
           (binds2 val2 setter2) (setforms place2))
      `(placewiths ,(+ binds1 (list g1 val1)
                       binds2 (list g2 val2))
         (,setter1 ,g2)
         (,setter2 ,g1)))))

(mac rotate places
  (with (vars (map [uniq 'arg] places)
         forms (map setforms places))
    `(placewiths ,(mappend (fn (g (binds val setter))
                             (+ binds (list g val)))
                           vars
                           forms)
       ,@(map (fn (g (binds val setter))
                (list setter g))
              (+ (cdr vars) (list (car vars)))
              forms))))

(mac pop (place)
  (w/uniq g
    (let (binds val setter) (setforms place)
      `(placewiths ,(+ binds (list g val))
         (do1 (car ,g) 
              (,setter (cdr ,g)))))))

(def adjoin (x xs (o test is))
  (if (some x xs test)
      xs
      (cons x xs)))

(mac setmem (test x place . args)
  (w/uniq (gt gx)
    (let (binds val setter) (setforms place)
      `(placewiths ,(+ (list gt test gx x) binds)
         (,setter (if ,gt
                      (adjoin ,gx ,val ,@args)
                      (rem ,gx ,val ,@args)))))))

(defset mem (x place . args)
  (w/uniq h
    (list nil
          `(mem ,x ,place ,@args)
          `(fn (,h) (setmem ,h ,x ,place ,@args)))))

(mac pushnew (x place . args)
  `(set (mem ,x ,place ,@args)))

(mac pull (test place . args)
  `(wipe (mem ,test ,place ,@args)))

(mac togglemem (x place . args)
  (w/uniq (gx gargs)
    `(placewiths (,gx ,x ,@(if args `(,gargs ,@args)))
       (= (mem ,gx ,place ,@(if args (list gargs)))
         (~mem ,gx ,place ,@(if args (list gargs)))))))

(mac ++ (place (o i 1))
  (if (and (isa!sym:ssexpand place) (lex place))
      `(= ,place (+ ,place ,i))
      (w/uniq gi
        (let (binds val setter) (setforms place)
          `(placewiths ,(+ binds (list gi i))
             (,setter (+ ,val ,gi)))))))

(mac -- (place (o i 1))
  (if (and (isa!sym:ssexpand place) (lex place))
      `(= ,place (- ,place ,i))
      (w/uniq gi
        (let (binds val setter) (setforms place)
          `(placewiths ,(+ binds (list gi i))
             (,setter (- ,val ,gi)))))))

; E.g. (++ x) equiv to (zap + x 1)

(mac zap (op place . args)
  (with (gop    (uniq 'op)
         gargs  (map [uniq 'arg] args)
         mix    (afn seqs 
                  (if (some no seqs)
                      nil
                      (+ (map car seqs)
                         (apply self (map cdr seqs))))))
    (let (binds val setter) (setforms place)
      `(placewiths ,(+ binds (list gop op) (mix gargs args))
         (,setter (,gop ,val ,@gargs))))))

(def zaptable (f h)
  (each (k v) h
    (= (h k) (f v)))
  h)

(mac w/defs body
  (let names nil
    (each f body
      (if (caris f 'def)
          (push (cadr f) names)))
    `(with ,(mappend [list _ nil] (rev! names))
       ,@body)))

(mac or= args
  (w/defs
    (def or1 (place expr)
      (if (acons place)
           ; compound place: use setforms to eval subforms only once
           (let (binds val setter) (setforms place)
             `(withs ,binds (or ,val (,setter ,expr))))
          (lex place)
           ; lexical var: read/write directly
           `(or ,place (= ,place ,expr))
           ; plain global symbol: guard against unbound
           `(or (and (bound ',place) ,place)
                (= ,place ,expr))))
    `(do ,@(pair (map1 ssexpand args)
                 (fn (place expr) `(placewiths () ,(or1 place expr)))))))

; Can't simply mod pr to print strings represented as lists of chars,
; because empty string will get printed as nil.  Would need to rep strings
; as lists of chars annotated with 'string, and modify car and cdr to get
; the rep of these.  That would also require hacking the reader.  

(def pr args
  (map0 disp args)
  (car args))

(def prt args
  (map0 only&disp args)
  (car args))

(def prn args
  (do1 (apply pr args)
       (writec #\newline)))

(mac wipe args
  `(do ,@(map [do `(= ,_ nil)] args)))

(mac set args
  `(do ,@(map [do `(= ,_ t)] args)))

; Destructuring means ambiguity: are pat vars bound in else? (no)

(mac iflet (var expr then . rest)
  (w/uniq gv
    `(let ,gv ,expr
       (if ,gv (let ,var ,gv ,then) ,@rest))))

(mac whenlet (var expr . body)
  `(iflet ,var ,expr (do ,@body)))

(mac whenlets (var expr . body)
  `(lets ,var ,expr
     (when ,var ,@body)))

(mac aif (expr . args)
  `(let it ,expr
     (if it
         ,@(if (cddr args)
               `(,(car args) (aif ,@(cdr args)))
               args))))

(mac awhen (expr . body)
  `(let it ,expr (if it (do ,@body))))

(mac aand args
  (if (no args)
      't 
      (no (cdr args))
       (car args)
      `(let it ,(car args) (and it (aand ,@(cdr args))))))

; Repeatedly evaluates its body till it returns nil, then returns vals.

(mac drain (expr (o eof nil))
  (w/uniq (gdone gres)
    `(let ,gdone nil
       (while (no ,gdone)
         (let ,gres ,expr
           (if (is ,gres ,eof)
               (= ,gdone t)
               (out ,gres)))))))

; For the common C idiom while x = snarfdata != stopval.
; Rename this if use it often.

(mac whiler (var expr endval . body)
  (w/uniq gf
    `(withs (,var nil ,gf (testify ,endval ex))
       (while (no (,gf (= ,var ,expr)))
         ,@body))))

(mac evtil (expr test)
  (w/uniq gv
    `(lets ,gv ,expr
       (while (no (,test ,gv))
         (= ,gv ,expr)))))
  
;(def macex (e)
;  (if (atom e)
;      e
;      (let op (and (atom (car e)) (eval (car e)))
;        (if (isa!mac op)
;            (apply (rep op) (cdr e))
;            e))))

(def string args
  (if (~cdr args)
      (as!string (car args))
      (apply + "" (map as!string args))))

(def flat x
  ((afn (x acc)
     (if (no x)   acc
         (atom x) (cons x acc)
                  (self (car x) (self (cdr x) acc))))
   x nil))

(def pos (test seq (o start 0))
  (let f (testify test)
    (if (alist seq)
        ((afn (seq n)
           (if (no seq)   
                nil
               (f (car seq)) 
                n
               (self (cdr seq) (+ n 1))))
         (nthcdr start seq)
         start)
        (recstring f:seq&idfn seq start))))

(def positions (test seq (o start 0))
  (let f (testify test)
    (accum a
      (if (alist seq)
          ((afn (seq (o n start))
             (when seq
               (if (f (car seq)) (a n))
               (self (cdr seq) (+ n 1))))
           (nthcdr start seq))
          (for i start (edge seq)
            (f:seq&a i))))))

(def lastpos (test seq (o start 0))
  (last:positions test seq start))

(def even (n) (is (mod n 2) 0))

(def odd (n) (no (even n)))

(mac after (x . ys)
  `(protect {do ,x} {do ,@ys}))

(let expander 
     (fn (f var name body)
       `(let ,var (,f ,name)
          (after (do ,@body) (close ,var))))

  (mac w/infile (var name . body)
    (expander 'infile var name body))

  (mac w/outfile (var name . body)
    (expander 'outfile var name body))

  (mac w/instring (var str . body)
    (expander 'instring var str body))

  (mac w/socket (var port . body)
    (expander 'open-socket var port body))
  )

; Non-atomic, otherwise it would hold the lock during body

(mac w/assign (place newval . body)
  (w/uniq prev
    (let (binds getter setter) (setforms place)
      `(withs ,(+ binds (list prev getter))
         (,setter ,newval)
         (after (do ,@body)
           (,setter ,prev))))))

(mac w/outstring (var . body)
  `(let ,var (outstring) ,@body))

; what happens to a file opened for append if arc is killed in
; the middle of a write?

(mac w/appendfile (var name . body)
  `(let ,var (outfile ,name 'append)
     (after (do ,@body) (close ,var))))

; rename this simply "to"?  - prob not; rarely use

(mac w/stdout (str . body)
  `(call-w/stdout ,str {do ,@body}))

(mac w/stdin (str . body)
  `(call-w/stdin ,str {do ,@body}))

(mac tostring body
  (w/uniq gv
   `(w/outstring ,gv
      (w/stdout ,gv ,@body)
      (inside ,gv))))

(mac assert (expr (o msg "Assertion failed") . args)
  `(or ,expr (err ,msg ,@(or args (list `',expr)))))

(mac fromstring (str . body)
  (w/uniq gv
   `(w/instring ,gv ,str
      (w/stdin ,gv ,@body))))

(def readstring1 (s) (w/instring i s (read i)))

(def read ((o x (stdin)) (o eof nil))
  (if (isa!string x) (readstring1 x) (sread x eof)))

; inconsistency between names of readfile[1] and writefile

(def readfile (name) (w/infile s name (readall s)))

(def readfile1 (name) (w/infile s name (read s)))

(def readall ((o src (stdin)) (o n))
  (if (isa!string src) (zap instring src))
  (whiler expr (read src eof) eof
    (if (and n (< (-- n) 0))
        (break)
        (out expr))))

(def allchars ((o str (stdin)))
  (tostring (whilet c (readc str nil)
              (writec c))))

(def allbytes ((o str (stdin)))
  (let bs nil
    (whilet b (readb str nil)
      (push b bs))
    (as!vector (rev! bs))))

(def filechars (name)
  (w/infile s name (allchars s)))

(def filebytes (name)
  (w/infile s name (allbytes s)))

(def tmpname (file)
  ; unique tmp per write so concurrent writes to the same file don't
  ; clobber each other's tmp -- a shared "file.tmp" let one writer's
  ; rename consume the tmp out from under another's (mvfile -> ENOENT).
  ; the after clause removes the tmp if the write or rename throws.
  (+ file "." (rand-string 16) ".tmp"))

(def writefile (val file (o write write))
  (let tmpfile (tmpname file)
    (after (do (w/outfile o tmpfile (write val o))
               (mvfile tmpfile file))
      (when (file-exists tmpfile)
        (rmfile tmpfile))))
  val)

(def dispfile (val file)
  (writefile val file disp))

(def copyfile (old new)
  (let tmpfile (tmpname new)
    (cpfile old tmpfile)
    (mvfile tmpfile new)))

(def sym (x) (as!sym x))

(def int (x (o b 10)) (as!int x b))

(def keysym (x) (if (isa!key x) (sym x) x))

(mac rand-choice exprs
  `(case (rand ,(len exprs))
     ,@(let key -1 
         (mappend [list (++ key) _]
                  exprs))))

(mac n-of (n expr)
  (w/uniq ga
    `(let ,ga nil     
       (repeat ,n (push ,expr ,ga))
       (rev! ,ga))))

; will freeze unless expr can generate n unique values

(mac n-dedup (n expr)
  (w/uniq seen
    `(let ,seen (table)
       (n-of ,n (awhen (evtil ,expr (complement ,seen))
                  (set (,seen it))
                  it)))))

(def asnum (x)
  (case (type x)
    (num int) x
    string    (as!num x)
    char      (as!int x)
    (err "Can't convert to number" x)))

(def inc (x (o n 1))
  (coerce (+ (asnum x) n) (type x)))

(def range (start end . more)
  ((afn (start (o acc))
     (if (> start end)
         (rev! acc)
         (self (inc start) (cons start acc))))
   start))

(def digits ()
  (com:as!string (range #\0 #\9)))

(def alphadigits ()
  (com:as!string (+ (range #\0 #\9) (range #\a #\z) (range #\A #\Z))))

(def rand-elt (seq) 
  (let n (len seq)
    (when (> n 0)
      (if (isa!table seq)
          (seq (rand-key seq))
          (seq (rand n))))))

(def rand-elts (n seq)
  (n-of n (rand-elt seq)))

(def rand-string (n (o alphabet (alphadigits)))
  (as!string (rand-elts n alphabet)))

(def best (f seq)
  (if (no seq)
      nil
      (let wins (car seq)
        (each elt (cdr seq)
          (if (f elt wins) (= wins elt)))
        wins)))
              
(def max args (best > args))
(def min args (best < args))

; (mac max2 (x y)
;   (w/uniq (a b)
;     `(with (,a ,x ,b ,y) (if (> ,a ,b) ,a ,b))))

(def most (f seq (o cmp >))
  (unless (no seq)
    (withs (wins (car seq) topscore (f wins))
      (each elt (cdr seq)
        (let score (f elt)
          (if (cmp score topscore) (= wins elt topscore score))))
      wins)))

(def least (f seq)
  (most f seq <))

(def rev-onto (xs onto)
  (if (no xs) onto (rev-onto (cdr xs) (cons (car xs) onto))))

; Insert so that list remains sorted.  Don't really want to expose
; these but seem to have to because can't include a fn obj in a 
; macroexpansion.
  
(def insert-sorted (test elt seq)
  ((afn (seq (o acc))
     (if (no seq)             (rev-onto acc (list elt))
         (test elt (car seq)) (rev-onto acc (cons elt seq))
                              (self (cdr seq) (cons (car seq) acc))))
   seq))

(mac insort (test elt seq)
  `(zap [insert-sorted ,test ,elt _] ,seq))

(def reinsert-sorted (test elt seq (o same ex))
  ((afn (seq (o acc))
     (if (no seq)             (rev-onto acc (list elt))
         (same elt (car seq)) (self (cdr seq) acc)
         (test elt (car seq)) (rev-onto acc (cons elt (rem elt seq same)))
                              (self (cdr seq) (cons (car seq) acc))))
   seq))

(mac insortnew (test elt seq . same)
  `(zap [reinsert-sorted ,test ,elt _ ,@same] ,seq))

; Could make this look at the sig of f and return a fn that took the 
; right no of args and didn't have to call apply (or list if 1 arg).

(def memo (f)
  (with (cache (table) nilcache (table))
    (fn args
      (or (cache args)
          (and (no (nilcache args))
               (aif (apply f args)
                    (= (cache args) it)
                    (do (set (nilcache args))
                        nil)))))))


(mac defmemo (name parms . body)
  `(safeset ,name (memo (fn ,parms ,@body))))

(def <= (x y . zs)
  (and (no (> x y)) (if zs (apply <= y zs) t)))

(def >= (x y . zs)
  (and (no (< x y)) (if zs (apply >= y zs) t)))

(def whitec (c)
  (in c #\space #\newline #\tab #\return))

(def nonwhite (c) (no (whitec c)))

(def letter (c) (or (<= #\a c #\z) (<= #\A c #\Z)))

(def digit (c) (<= #\0 c #\9))

(def alphadig (c) (letter|digit c))

(def punc (c)
  (in c #\. #\, #\; #\: #\! #\?))

(def readline ((o str (stdin)))
  (awhen (readc str)
    (tostring 
      (writec it)
      (whiler c (readc str) [in _ nil #\newline]
        (writec c)))))

; Don't currently use this but suspect some code could.

(mac summing (sumfn . body)
  (w/uniq (gc gt)
    `(let ,gc 0
       (let ,sumfn (fn (,gt) (if ,gt (++ ,gc)))
         ,@body)
       ,gc)))

(def sum (f xs)
  (lets n 0
    (each x xs (++ n (f x)))))

(def treewise (f base tree)
  (if (atom tree)
      (base tree)
      (f (treewise f base (car tree)) 
         (treewise f base (cdr tree)))))

(def carif (x) (if (atom x) x (car x)))

; Could prob be generalized beyond printing.

(def prall (elts (o init "") (o sep ", "))
  (when elts
    (pr init (car elts))
    (map0 [pr sep _] (cdr elts))
    elts))

(def prs args     
  (prall args "" #\space))

(def tree-subst (old new tree)
  (if (is tree old)
       new
      (atom tree)
       tree
      (cons (tree-subst old new (car tree))
            (tree-subst old new (cdr tree)))))

(def ontree (f tree)
  (f tree)
  (unless (atom tree)
    (ontree f (car tree))
    (ontree f (cdr tree))))

(def dotted (x)
  (aand (~atom x) (cdr x) (atom|dotted it)))

(def fill-table (table data)
  (each (k v) (pair data) (= (table k) v))
  table)

(def keys (h (o test idfn))
  (if (is test idfn)
      (tabkeys h)
      (keep test (tabkeys h))))

(def vals (h (o test idfn))
  (if (is test idfn)
      (tabvals h)
      (keep test (tabvals h))))

; These two should really be done by coerce.  Wrap coerce?

(def tablist (h)
  (tabpairs h))

(def listtab (al)
  (lets h (table)
    (each (k v) al
      (= (h k) v))))

(mac obj args
  `(listtab (list ,@(map (fn ((k v))
                           `(list ',(keysym k) ,v))
                         (pair args)))))

(def load-table (file (o eof (table)))
  (w/infile i file (read-table i eof)))

(def read-table ((o i (stdin)) (o eof nil))
  (let e (read i eof)
    (if (is e eof) e
        (alist e)  (listtab e)
                   e)))

(def load-tables (file)
  (w/infile i file
    (drain (read-table i eof) eof)))

(= save-stripes* 64)

(or= save-locks* (table))

(def string-hash (name)
  (sum as!int name))

(def save-lock (file)
  (let key (mod (string-hash file) save-stripes*)
    (or (save-locks* key)
        (or= (save-locks* key)
             (make-lock 22 "savefile")))))

; A file can't regress to an older snapshot. Writes to the same path
; are serialized, and each tablist happens inside the critical
; section, so every write lands a snapshot taken after the previous
; write finished.

(def save-table (h file)
  (w/lock (save-lock file)
    (writefile (tablist h) file)))

(def write-table (h (o o (stdout)))
  (write (tablist h) o))

(def copy (x . args)
  (let x2 (case (type x)
            sym    x
            cons   (copylist x)
            string (lets new (newstring (len x))
                     (forlen i x
                       (= (new i) (x i))))
            table  (lets new (table)
                     (each (k v) x 
                       (= (new k) v)))
            vector (as!vector:as!cons x)
                   (err "Can't copy" x))
    (each (k v) (pair args)
      (= (x2 k) v))
    x2))

; like copy, but returns a new empty seq

(def fresh (x)
  (case (type x)
    sym    x
    cons   nil
    string ""
    table  (table)
    vector (as!vector nil)
           (err "Can't make a fresh type" (type x))))

(def abs (n)
  (if (< n 0) (- n) n))

; The problem with returning a list instead of multiple values is that
; you can't act as if the fn didn't return multiple vals in cases where
; you only want the first.  Not a big problem.

(def round (n)
  (withs (base (trunc n) rem (abs (- n base)))
    (if (> rem 1/2) ((if (> n 0) + -) base 1)
        (< rem 1/2) base
        (odd base)  ((if (> n 0) + -) base 1)
                    base)))

(def roundup (n)
  (withs (base (trunc n) rem (abs (- n base)))
    (if (>= rem 1/2) 
        ((if (> n 0) + -) base 1)
        base)))

(def nearest (n quantum)
  (* (roundup (/ n quantum)) quantum))

(def avg (ns) (/ (apply + ns) (len ns)))

; numerical median

(def med (ns)
  (with (xs (sort > ns) n (len ns))
    (if (odd n)
        (xs (trunc (/ n 2)))
        (/ (+ (xs    (/ n 2))
              (xs (- (/ n 2) 1)))
           2))))

; positional median

(def median (ns (o test >))
  ((sort test ns) (trunc (/ (len ns) 2))))

(def cov (xs ys)
  (avg (map * (subtract (avg xs) xs)
              (subtract (avg ys) ys))))

(def subtract (x ns)
  (map [- _ x] ns))

(def var (xs)
  (cov xs xs))

; population standard deviation.

(def std (ns)
  (sqrt (var ns)))

; Use mergesort on assumption that mostly sorting mostly sorted lists
; benchmark: (let td (n-of 10000 (rand 100)) (time (sort < td)) 1) 

(def sort (test seq)
  (if (alist seq)
      (mergesort test (copy seq))
      (coerce (mergesort test (as!cons seq)) (type seq))))

; Destructive stable merge-sort, adapted from slib and improved 
; by Eli Barzilay for MzLib; re-written in Arc.

(def mergesort1 (less? lst)
  (let n (len lst)
    (if (<= n 1) lst
        ; check if the list is already sorted
        ; (which can be a common case, eg, directory lists).
        ((afn ((o last (car lst)) (o next (cdr lst)))
           (or (no next)
               (and (~less? (car next) last)
                    (self (car next) (cdr next))))))
        lst
        ((afn (n)
           (if (> n 2)
                ; needs to evaluate L->R
                (withs (j (/ (if (even n) n (- n 1)) 2) ; faster than round
                        a (self j)
                        b (self (- n j)))
                  (merge1 less? a b))
               ; the following case just inlines the length 2 case,
               ; it can be removed (and use the above case for n>1)
               ; and the code still works, except a little slower
               (is n 2)
                (with (x (car lst) y (cadr lst) p lst)
                  (= lst (cddr lst))
                  (when (less? y x) (scar p y) (scar (cdr p) x))
                  (scdr (cdr p) nil)
                  p)
               (is n 1)
                (lets p lst
                  (= lst (cdr lst))
                  (scdr p nil))
               nil))
         n))))

; Also by Eli. Merges two lists that are already sorted.

(def merge1 (less? x y)
  (if (no x) y
      (no y) x
      (w/defs
        (def lup (r x y r-x?) ; r-x? for optimization -- is r connected to x?
          (if (less? (car y) (car x))
              (do (if r-x? (scdr r y))
                  (if (cdr y) (lup y x (cdr y) nil) (scdr y x)))
              ; (car x) <= (car y)
              (do (if (no r-x?) (scdr r x))
                  (if (cdr x) (lup x (cdr x) y t) (scdr x y)))))
        (if (less? (car y) (car x))
          (do (if (cdr y) (lup y x (cdr y) nil) (scdr y x))
              y)
          ; (car x) <= (car y)
          (do (if (cdr x) (lup x (cdr x) y t) (scdr x y))
              x)))))

; CL-optimized versions of the sorting functions above.
; Speedup is ~1.7x to ~3x, but sacrifices Arc purity.

(def mergesort2 (less? lst)
  (#'stable-sort lst less?))

(def merge2 (less? x y)
  (#'merge #''list x y less?))

; use the optimized versions.

(def mergesort mergesort2)
(def merge     merge2)

(def bestn (n f seq)
  (firstn n (sort f seq)))

(def split (seq pos (o keepdelim t))
  (if pos
      (let mid (if keepdelim pos (+ pos 1))
        (list (cut seq 0 pos) (cut seq mid)))
      (list seq (fresh seq))))

(def cleave (seq pos (o keepdelim nil))
  (split seq pos keepdelim))

(mac time (expr)
  (w/uniq (t1 t2)
    `(let ,t1 (msec)
       (do1 ,expr
            (let ,t2 (msec)
              (prn "time: " (- ,t2 ,t1) " msec."))))))

(mac jtime (expr)
  `(do1 'ok (time ,expr)))

(mac time10 (expr)
  `(time (repeat 10 ,expr)))

(def union (f xs ys)
  (+ xs (rem (fn (y) (some [f _ y] xs))
             ys)))

(or= templates* (table))

(mac deftem (tem . fields)
  (withs (name (carif tem) includes (if (acons tem) (cdr tem)))
    `(= (templates* ',name) 
        (+ (mappend templates* ',(rev includes))
           (list ,@(map (fn ((k v)) `(list ',k {do ,v}))
                        (pair fields)))))))

(mac addtem (name . fields)
  `(= (templates* ',name) 
      (union (compare is car)
             (list ,@(map (fn ((k v)) `(list ',k {do ,v}))
                          (pair fields)))
             (templates* ',name))))

(def inst (tem . args)
  (lets x (table)
    (each (k v) (if (acons tem) tem (templates* tem))
      (unless (no v) (= (x k) (v))))
    (each (k v) (pair args)
      (= (x k) v))))

; Converts the read-time symbols 't/'T to t and 'nil to nil.
; Applied in templatize (so field values read back from disk get
; real t/nil instead of bare symbols). Fixes a bug where the json
; api was giving "deleted": "t" instead of "deleted": true.
;
; No need for deep comparison unless someday lists containing t are
; serialized to disk.

(def temquote (x)
  (if (isa!sym x)
      (case (string x)
        ("t" "T") t
        "nil" nil
        x)
      x))

; The membership test used to be (assoc k fields), a linear scan of the
; whole template for every field read back.  temload runs this once per
; item on disk, so a full (load-items) did it hundreds of thousands of
; times.  Cache one key set per template instead; the cache is keyed on
; the field list itself, so redefining a template with deftem or addtem
; installs a fresh list and misses the stale entry rather than reading
; through it.

(or= template-keys* (table))

; Cached under the template's name -- a symbol, so it hashes well; the
; fields list itself would be a cons full of closures.  The list is kept
; beside the key set and compared by identity, so redefining a template
; (deftem and addtem both install a fresh list) misses rather than
; reading through a stale entry.  An inline template list isn't cached.

(def template-keys (tem fields)
  (if (acons tem)
      (memtable (map car fields))
      (aif (check (template-keys* tem) [ex (car _) fields])
           (cadr it)
           (cadr (= (template-keys* tem)
                    (list fields (memtable (map car fields))))))))

; Converts alist to inst; ugly; maybe should make this part of coerce.
; Note: discards fields not defined by the template.

(def templatize (tem raw)
  (lets x (inst tem)
    (with (fields (if (acons tem) tem (templates* tem)))
      (let known (template-keys tem fields)
        (each (k v) raw
          (when (known k)
            (= (x k) (temquote v))))))))

; To write something to be read by temread, (write (tablist x))

(def temread (tem (o str (stdin)))
  (templatize tem (read str)))

(def temload (tem file)
  (w/infile i file (temread tem i)))

(def temloadall (tem file)
  (map (fn (pairs) (templatize tem pairs))
       (w/infile in file (readall in))))

(def serialize (x)
  (if (acons x) (map serialize x)
      (isa!table x) `(%table ,(map serialize (tablist x)))
      x))

(def deserialize (x)
  (if (caris x '%table) (listtab (cadr (map deserialize x)))
      (acons x) (map deserialize x)
      (temquote x)))


(= sec*  1)
(= min*  (com (* 60 sec*)))
(= hour* (com (* 60 min*)))
(= day*  (com (* 24 hour*)))
(= year* (com (* 365 day*)))

(def minutes-since (t1) (/ (since t1) min*))
(def hours-since (t1)   (/ (since t1) hour*))
(def days-since (t1)    (/ (since t1) day*))

(def since (t1) (- (seconds) t1))

(def cache (timef valf)
  (let store (table) ; args -> (list cached-value gentime)
    (fn args
      (aif (timef)
           (let cell (or= (store args) (list nil nil))
             ; key freshness on gentime, not the value, so a nil result
             ; is cached for the interval instead of recomputed each call
             (unless (and (cadr cell) (< (since (cadr cell)) it))
               (= (car cell)  (apply valf args)
                  (cadr cell) (seconds)))
             (car cell))
           (apply valf args)))))

(mac defcache (name lasts . body)
  `(safeset ,name (cache {do ,lasts}
                         {do ,@body})))

(mac errsafe (expr)
  `(on-err (fn (c) nil)
           {do ,expr}))

(def saferead (arg)
  (if (isa!string arg) (errsafe:read arg) arg))

(def safe-load-table (filename) 
  (or (errsafe:load-table filename)
      (table)))

(def dirs (path)
  (aand (dir path)
        ; can't use endmatch, strings.arc isn't loaded yet
        ;(keep [endmatch "/" _] it)
        (keep [is #\/ (_ (edge _))] it)))

(def files (path)
  (aand (dir path)
        ; can't use endmatch, strings.arc isn't loaded yet
        ;(rem [endmatch "/" _] it)
        (rem [is #\/ (_ (edge _))] it)))

(def ensure-dir (path)
  (unless (dir-exists path)
    (system:list "mkdir" "-p" path)))

(def date ((o s (seconds)))
  (rev (nthcdr 3 (timedate s))))

(def zeropad (i (o n 2))
  (lets s (string i)
    (while (< (len s) n)
      (= s (+ "0" s)))))

(def datestring ((o s (seconds)))
  (let (y m d) (date s)
    (string y "-" (zeropad m) "-" (zeropad d))))

(def count (test x)
  (with (n 0 testf (testify test))
    (each elt x
      (if (testf elt) (++ n)))
    n))

(def ellipsize (str (o limit 80))
  (if (<= (len str) limit)
      str
      (+ (cut str 0 limit) "...")))

(mac until (test . body)
  `(while (no ,test) ,@body))

(def before (x y seq (o i 0))
  (with (xp (pos x seq i) yp (pos y seq i))
    (and xp (or (no yp) (< xp yp)))))

(def orf fns
  (fn args
    ((afn (fs)
       (and fs (or (apply (car fs) args) (self (cdr fs)))))
     fns)))

(def andf fns
  (fn args
    ((afn (fs)
       (if (no fs)       t
           (no (cdr fs)) (apply (car fs) args)
                         (and (apply (car fs) args) (self (cdr fs)))))
     fns)))

(def atend (i s)
  (>= i (edge s)))

(def multiple (x y)
  (is 0 (mod x y)))

(mac nor args `(no (or ,@args))) 

; Consider making the default sort fn take compare's two args (when do 
; you ever have to sort mere lists of numbers?) and rename current sort
; as prim-sort or something.

; Could simply modify e.g. > so that (> len) returned the same thing
; as (compare > len).

(def compare (comparer scorer)
  (fn (x y) (comparer (scorer x) (scorer y))))

; Cleaner thus, but may only ever need in 2 arg case.

;(def compare (comparer scorer)
;  (fn args (apply comparer (map scorer args))))

(mac conswhen (f x y)
  (w/uniq (gf gx)
   `(with (,gf ,f ,gx ,x)
      (if (,gf ,gx) (cons ,gx ,y) ,y))))

; Could combine with firstn if put f arg last, default to (fn (x) t).

(def retrieve (n f xs)
  (if (no n)                 (keep f xs)
      (or (<= n 0) (no xs))  nil
      (f (car xs))           (cons (car xs) (retrieve (- n 1) f (cdr xs)))
                             (retrieve n f (cdr xs))))

(def dedup (xs (o key idfn))
  (with (h (isotable) acc nil)
    (each x xs
      (unless (h:key x)
        (push x acc)
        (set (h:key x))))
    (rev! acc)))

(def single (x) (and (acons x) (no (cdr x))))

(def intersperse (x ys)
  (and ys (cons (car ys)
                (mappend [list x _] (cdr ys)))))

(def counts (seq (o c (table)))
  (if (no seq)
      c
      (do (++ (c (car seq) 0))
          (counts (cdr seq) c))))

(def commonest (seq)
  (with (winner nil n 0)
    (each (k v) (counts seq)
      (when (> v n) (= winner k n v)))
    (list winner n)))

(let argsym (uniq 'args)

  (def parse-format (str)
    (accum a
      (withs (chars nil  i -1
              flush {do (a (as!string:rev chars))
                        (wipe chars)})
        (w/instring s str
          (whilet c (readc s)
            (case c 
              #\# (do (flush) (a:read s))
              #\~ (do (flush) (a:list argsym (++ i)))
                  (push c chars))))
         (if chars (flush)))))
  
  (mac prf (str . args)
    `(let ,argsym (list ,@args)
       (pr ,@(parse-format str))))
)

(or= loaded-files* nil
     loaded-file-times* (table)
     reloading* nil)

(def notetime (file)
  (= (loaded-file-times* file) (modtime file))
  (pushnew file loaded-files*))

(notetime "arc.arc")

(def file-changed (file)
  (awhen (loaded-file-times* file)
    (> (modtime file) it)))

(def loaded-files-changed ()
  (some file-changed loaded-files*))

; arc0.lisp and arc1.lisp never go through `load`, so nothing ever gives
; them a notetime.  Track them next to the .arc files, so that editing
; only the lisp half still trips maybe-reload.  They are kept out of
; loaded-files* on purpose: `reload` walks that list with `load`, and
; these two are reloaded by reload-runtime instead.

(def note-runtime-times ()
  (each file (runtime-files)
    (= (loaded-file-times* file) (modtime file))))

(def runtime-changed ()
  (some file-changed (runtime-files)))

(note-runtime-times)

(def load (file)
  (w/infile f file
    (notetime file)
    (w/assign script-file* file
      (whiler e (read f eof) eof
        (eval e)))))

(def reload ()
  (w/assign reloading* t
    ; Note the times before reloading, not after: reload-runtime can
    ; refuse (a struct changed shape) or fail to compile, and a caller
    ; polling maybe-reload must not then retry on every tick.  Wait for
    ; the next edit instead.
    (note-runtime-times)
    (reload-runtime)
    (each file (rev loaded-files*)
      (call-quietly {load file}))))

(def maybe-reload ()
  (when (or (loaded-files-changed) (runtime-changed))
    ; reload runs unsynchronized on the accept thread, and requests in
    ; flight may observe half-redefined definitions.
    (call-reporting reload)))

; True iff the current file is the toplevel script (last .arc file
; passed on the sharc command line). Analogous to Python's
;   if __name__ == "__main__":
;
; Use as:
;   (when (main) (do-toplevel-stuff))
;
; The (no reloading*) clause keeps these effects from re-firing when
; (reload) re-loads the toplevel script, so a hot-reload swaps code
; without restarting the server or re-entering the repl.

(def main ()
  (and main-file* (is script-file* main-file*) (no reloading*)))

(def number (n) (in (type n) 'int 'num))

(def positive (x)
  (and (number x) (> x 0)))

(mac w/table (var . body)
  `(lets ,var (table) ,@body))

(or= ero-lock* (make-lock 59 "ero"))

(def ero args
  (w/lock ero-lock*
    (w/stdout (stderr) 
      (each a args 
        (write a)
        (writec #\space))
      (writec #\newline)
      (flushout)))
  (car args))

(or= queue-lock* (make-lock 25 "queue"))

(mac w/queue-lock body
  `(w/lock queue-lock* ,@body))

(def queue () (list nil nil 0))

(def enq (obj q)
  (w/queue-lock
    (++ (q 2))
    (if (no (car q))
        (= (cadr q) (= (car q) (list obj)))
        (= (cdr (cadr q)) (list obj)
           (cadr q)       (cdr (cadr q))))
    (car q)))

(def deq (q)
  (w/queue-lock
    (unless (is (q 2) 0) (-- (q 2)))
    (pop (car q))))

; Should redef len to do this, and make queues lists annotated queue.

(def qlen (q) (q 2))

(def qlist (q) (car q))

(def enq-limit (val q (o limit 1000))
  (w/queue-lock
    (unless (< (qlen q) limit)
      (deq q))
    (enq val q)))

; The dots go to stderr, but the "load items: " style labels that
; introduce them are printed to stdout by the caller.  Both land on the
; terminal, so flush stdout before switching over or the labels sit in
; the buffer until something writes a newline and turn up after their
; own progress dots.

(def noisy-report (n noisy)
  (when noisy
    (when (main-thread)
      (flushout)
      (w/stdout (stderr)
        (when (multiple n noisy)
          (pr ".") (flushout))
        (when (multiple n (* noisy 10))
          (pr " ") (flushout))
        (when (multiple n (* noisy 100))
          (prn) (flushout))
        (when (multiple n (* noisy 1000))
          (prn) (flushout))))))

(def noisy-flush (noisy)
  (when (main-thread)
    (flushout)
    (w/stdout (stderr)
      (when noisy (prn) (flushout)))))

(def noisy-iter (noisy)
  (let i 0 {noisy-report (++ i) noisy}))

(mac w/noisy (var noisy . body)
  (w/uniq n
    `(withs (,n ,noisy ,var (noisy-iter ,n))
       (do1 (do ,@body)
            (noisy-flush ,n)))))

(mac w/noisy-loop (noisy body)
  (w/uniq iter
    `(w/noisy ,iter ,noisy
       ,(+ body (list (list iter))))))

(mac noisy-each (n var val . body)
  `(w/noisy-loop ,n
     (each ,var ,val
       ,@body)))

(def downcase (x)
  (case (type x)
    string    (#'string-downcase x)
    char      (#'char-downcase x)
    (sym key) x ; symbols and keywords are always lowercase
              (err "Can't downcase" x)))

(def upcase (x)
  (case (type x)
    string    (#'string-upcase x)
    char      (#'char-upcase x)
    (sym key) x ; symbols and keywords are always lowercase
              (err "Can't upcase" x)))

(def mismatch (s1 s2)
  (catch
    (on c s1
      (when (isnt c (s2 index))
        (throw index)))))

(def memtable (ks)
  (lets h (table)
    (each k ks (set (h k)))))

(= bar* " | ")

(mac w/bars body
  (w/uniq (out needbars)
    `(let ,needbars nil
       (do ,@(map (fn (e)
                    `(let ,out (tostring ,e)
                       (unless (is ,out "")
                         (if ,needbars
                             (pr bar* ,out)
                             (do (set ,needbars)
                                 (pr ,out))))))
                  body)))))

(def len< (x n) (< (len x) n))

(def len> (x n) (> (len x) n))

(mac trav (x . fs)
  (w/uniq g
    `(w/break
       ((afn (,g)
          (when ,g
            ,@(map [list _ g] fs)))
        ,x))))

(or= hooks* (table))

(def hook (name . args)
  (aif (hooks* name) (apply it args)))

(mac defhook (name . rest)
  `(= (hooks* ',name) (fn ,@rest)))
  
; if renamed this would be more natural for (map [_ user] pagefns*)

(def get (index) [_ index])

(or= savers* (table))

(mac fromdisk (var file init load save)
  (w/uniq (gf gv)
    `(do (= (savers* ',var) (fn (,gv) (,save ,gv ,file)))
         (unless (bound ',var)
           (= ,var (iflet ,gf (file-exists ,file)
                          (,load ,gf)
                          ,init))))))

(mac diskvar (var file (o init 'nil))
  `(fromdisk ,var ,file ,init readfile1 writefile))

(mac disktable (var file)
  `(fromdisk ,var ,file (table) load-table save-table))

(mac todisk (var (o expr var))
  `((savers* ',var) 
    ,(if (is var expr) var `(= ,var ,expr))))


(def rand-key (h)
  (if (empty h)
      nil
      (let n (rand (len h))
        (catch
          (each (k v) h
            (when (is (-- n) -1)
              (throw k)))))))

(def ratio (test xs)
  (if (empty xs)
      0
      (/ (count test xs) (len xs))))

(def readenv (name (o default))
  (aif (saferead:getenv name)
       (unless (in it 0 'false) it)
       default))

; https://en.wikipedia.org/wiki/Fisher%E2%80%93Yates_shuffle#The_modern_algorithm

(def shuffle! (xs)
  (down i (edge xs) 1
    (let j (rand (+ i 1))
      (swap (xs j) (xs i))))
  xs)

(def shuffle (xs) (shuffle! (copy xs)))

; ---- Thread-local variables ---------------------------------------
;
; A per-thread key-value store, with two ergonomic affordances:
;
;   (the var)          --- read the current thread's binding for var
;   (= (the var) val)  --- set it
;   (w/the var val ...) --- bind for the duration of body, restore after
;
;   (def f ((t me)) ...)        --- me defaults to (the me) if not passed
;   (def f ((t local var)) ...) --- local defaults to (the var)
;
; Modeled on dang's news.arc thread-local trick
; (https://news.ycombinator.com/item?id=11242977) for passing
; per-request context like the current user without threading it
; through every function signature.
;
; (the var) is a macro so the var name is taken literally (no quote at
; the call site). It expands to a call to the underlying `thread-local`
; function, which is what setforms-and-friends actually hook into.

(or= thread-locals* (table))

(def thread-locals ((o th (current-thread)))
  (or (thread-locals* th)
      (or= (thread-locals* th) (table))))

(def thread-local (k) ((thread-locals) k))

(defset thread-local (var-form)
  (let var (cadr var-form)  ; '(quote me) -> me
    (w/uniq (g h)
      (list (list g '(thread-locals))
            `(,g ',var)
            `(fn (,h) (sref ,g ,h ',var))))))

(mac the (var)
  `(thread-local ',var))

(mac w/the (var val . body)
  `(w/assign (the ,var) ,val
     ,@body))

(mac w/the-if (var val . body)
  `(w/the ,var (or ,val (the ,var))
     ,@body))

(def start-thread (f (o name "arc"))
  (new-thread {after (f) (cleanup-thread)} name))

(def cleanup-thread ((o th (current-thread)))
  (wipe (thread-locals* th)))

(mac thread body
  `(start-thread {do ,@body}))

(mac named-thread (name . body)
  `(start-thread {do ,@body} ,name))

(def stop-thread (th)
  (when th
    (unless (dead-thread th)
      (kill-thread th))
    (after (join-thread th)
      (cleanup-thread th))))

(or= main-thread* (current-thread))

(def main-thread ((o th (current-thread)))
  (is th main-thread*))

(def main-repl ()
  ;; not (repl): see boot.lisp.  Calling it here would run the prompt
  ;; inside load's read-eval loop, and exiting it would resume reading
  ;; this file at a now-stale offset.
  (= main-repl* t))

; > (= (list a b c) (list 1 2 3))
; (1 2 3)
; > (list a b c)
; (1 2 3)

(defset list vars
  (list (list)
        `(list ,@vars)
        `(fn (val)
           ,@(accum a
               (forlen i vars
                 (let var (vars i)
                   (a `(= ,var (val ,i))))))
           val)))

(def yesno ((o question) (o default))
  (if question (prn question))
  (pr "Continue? " (if default "[Y/n]" "[y/N]") " ")
  (flushout)
  (let it (read (stdin) eof)
    (if (is it eof)
        default
        (in it 'Y 'YES))))

; Referencing the bare symbol `scope` (or `scope%`) compiles to
; (%scope env), where ac splices in its compile-time lexical environment.
; For each distinct lexical in scope, emit (name (fn () name) (fn (v) ...))
; so you can read and mutate the live binding at runtime (handy for
; debugging from a breakpoint).  Non-symbols (the fn-name markers ac keeps
; in env) are skipped, and a shadowed name appears once, innermost binding.
; Two spellings: a lexical named `scope` shadows the trigger (lex-p wins),
; so `scope%` is a less-collidable fallback to reach the reflection.

(mac %scope (env)
  `(list ,@(accum a
             (each x (dedup:keep isa!sym env)
               (w/uniq h
                 (a `(list ',x
                           (fn () ,x)
                           (fn (,h) (assign ,x ,h)))))))))

; re-enable redef warning

(def warnset (var)
  (w/lock ero-lock*
    (w/stdout (stderr)
      (prn "*** redefining " var)
      (flushout))))

; any logical reason I can't say (push x (if foo y z)) ?
;   eval would have to always ret 2 things, the val and where it came from
; idea: implicit tables of tables; setf empty field, becomes table
;   or should setf on a table just take n args?

; idea: use constants in functional position for currying?
;       (1 foo) would mean (fn args (apply foo 1 args))
; another solution would be to declare certain symbols curryable, and 
;  if > was, >_10 would mean [> _ 10]
;  or just say what the hell and make _ ssyntax for currying
; idea: make >10 ssyntax for [> _ 10]
; solution to the "problem" of improper lists: allow any atom as a list
;  terminator, not just nil.  means list recursion should terminate on 
;  atom rather than nil, (def empty (x) (or (atom x) (is x "")))
; table should be able to take an optional initial-value.  handle in sref.
; warn about code of form (if (= )) -- probably mean is
; warn when a fn has a parm that's already defined as a macro.
;   (def foo (after) (after))
; idea: a fn (nothing) that returns a special gensym which is ignored
;  by map, so can use map in cases when don't want all the vals
; idea: anaph macro so instead of (aand x y) say (anaph and x y)
; idea: foo.bar!baz as an abbrev for (foo bar 'baz)
;  or something a bit more semantic?
; could uniq be (def uniq () (annotate 'symbol (list 'u))) again?
; idea: use x- for (car x) and -x for (cdr x)  (but what about math -?)
; idea: get rid of strings and just use symbols
; could a string be (#\a #\b . "") ?
; better err msg when , outside of a bq
; idea: parameter (p foo) means in body foo is (pair arg)
; idea: make ('string x) equiv to (coerce x 'string) ?  or isa?
;   quoted atoms in car valuable unused semantic space
; idea: if (defun foo (x y) ...), make (foo 1) return (fn (y) (foo 1 y))
;   probably would lead to lots of errors when call with missing args
;   but would be really dense with . notation, (foo.1 2)
; or use special ssyntax for currying: (foo@1 2)
; remember, can also double; could use foo::bar to mean something
; wild idea: inline defs for repetitive code
;  same args as fn you're in
; variant of compose where first fn only applied to first arg?
;  (> (len x) y)  means (>+len x y)
; use ssyntax underscore for a var?
;  foo_bar means [foo _ bar]
;  what does foo:_:bar mean?
; matchcase
; idea: atable that binds it to table, assumes input is a list
; crazy that finding the top 100 nos takes so long:
;  (let bb (n-of 1000 (rand 50)) (time10 (bestn 100 > bb)))
;  time: 2237 msec.  -> now down to 850 msec

