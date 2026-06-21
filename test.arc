#!./sharc

; adapted from test.l in https://github.com/sctb/lumen

(= true 't false nil)

(or= tests* (table))

(mac test! (x msg)
  `(if (no ,x)
       (do (= failed* (+ failed* 1))
           (return ,msg))
     (++ passed*)))

(def writes (x)
  (tostring (write x)))

(def equal? (a b)
  (is (writes a) (writes b)))

(mac test? (a b)
  (w/uniq (x y)
    `(withs (,x ,a ,y ,b)
       (test! (equal? ,x ,y)
              (+ "failed: expected " (writes ,x) ", was " (writes ,y)
                 " for " (writes '(test? ,a ,b)))))))

(mac define-test (name . body)
  (let label (coerce (string "test-" name) 'sym)
    `(do (def ,label ()
           (point return ,@body))
         (= (tests* ',name) ,label))))

(def run-tests ()
  (= passed* 0 failed* 0)
  (each (name f) tests*
    (let result (f)
      (when (isa result 'string)
        (prn (+ " " name " " result)))))
  (prn (+ " " passed* " passed, " failed* " failed")))

(define-test no
  (test? true (no nil))
  ;(test? true (no unset))
  ;(test? true (no (void)))
  (test? false (no true))
  (test? true (no false))
  (test? false (no (obj)))
  (test? false (no 0)))

;(define-test yes
;  (test? false (yes nil))
;  (test? false (yes unset))
;  (test? false (yes (void)))
;  (test? true (yes true))
;  (test? false (yes false))
;  (test? true (yes (obj)))
;  (test? true (yes 0)))

(define-test boolean
  (test? true (or true false))
  (test? false (or false false))
  (test? true (or false false true))
  (test? true (no false))
  (test? true (no (and false true)))
  (test? false (no (or false true)))
  (test? true (and true true))
  (test? false (and true false))
  (test? false (and true true false)))

(define-test identity
  (test? true (is 'a 'a))
  (test? false (is 'a "a"))
  (test? true (is "a" "a"))
  (test? true (id "a" "a"))
  (test? true (is (join) (join)))
  (test? false (id (join) (join)))
  (test? true (is (list 'a) (list 'a)))
  (test? false (id (list 'a) (list 'a)))
  (test? true (is (obj) (obj)))
  (test? false (id (obj) (obj)))
  (test? true (is (obj a t) (obj a t)))
  (test? false (id (obj a t) (obj a t)))
  (test? true (is -0.0 0.0))
  (test? true (id -0.0 0.0)))

(define-test short
  (test? true (or true (err 'bad)))
  (test? false (and false (err 'bad)))
  (let a true
    (test? true (or true (do (= a false) false)))
    (test? true a)
    (test? false (and false (do (= a false) true)))
    (test? true a))
  (let b true
    (test? true (or (do (= b false) false) (do (= b true) b)))
    (test? true b)
    (test? true (or (do (= b true) b) (do (= b true) b)))
    (test? true b)
    (test? true (and (do (= b false) true) (do (= b true) b)))
    (test? true b)
    (test? false (and (do (= b false) b) (do (= b true) b)))
    (test? false b)))

(define-test numeric
  (test? 4 (+ 2 2))
  (test? 0 (apply * '(0 0)))
  (test? 4 (apply + '(2 2)))
  (test? 0 (apply + ()))
  (test? 4 (- 7 3))
  (test? 4 (apply - '(7 3)))
  ;(test? 0 (apply - ()))
  (test? 5 (/ 10 2))
  (test? 5 (apply / '(10 2)))
  ;(test? 1 (apply / ()))
  (test? 6.0 (* 2 3.00))
  (test? 6.0 (apply * '(2 3.00)))
  ;(test? 1 (apply * ()))
  (test? true (> 2.01 2))
  (test? true (>= 5.0 5.0))
  (test? true (> 2.1e3 2000))
  (test? true (< 2e-3 0.0021))
  (test? false (< 2 2))
  (test? true (<= 2 2))
  ;(test? true (is 2 2.0))
  (test? true (is -0.0 +0.0))
  (test? -7 (- 7)))

(define-test math
  (test? 3 (max 1 3))
  (test? 2 (min 2 7))
  (let n (rand)
    (test? true (and (> n 0) (< n 1))))
  (test? 4 (trunc 4.78)))

(define-test med
  (test? 2   (med '(3 1 2)))      ; odd: middle element
  (test? 3   (med '(1 2 3 4 5)))  ; odd, longer
  (test? 5/2 (med '(4 1 2 3)))    ; even: average of the two middles
  (test? 15  (med '(10 20)))      ; even pair
  (test? 7   (med '(7))))         ; single element

(define-test precedence
  (test? -3 (- (+ 1 2)))
  (test? 10 (- 12 (+ 1 1)))
  (test? 11 (- 12 (* 1 1)))
  (test? 10 (+ (/ 4 2) 8)))

(define-test infix
  (withs (l '(1 1 2 3)
          (a b c d) l)
    (test? true (apply <= l))
    (test? false (apply < l))
    (test? false (apply is l))
    (test? true ((do is) 1 a b))
    (test? false (apply > (rev l)))
    (test? true (apply >= (rev l)))
    (test? true (<= a b c d))
    (test? true (<= a b c d))
    (test? false (< a b c d))
    (test? false (is a b c d))
    (test? true (is 1 a b))
    (test? false (> d c b a))
    (test? true (>= d c b a))))

;(define-test standalone
;  (test? 10 (do (+ illegal) 10))
;  (let x nil
;    (test? 9 (do (list nothing fooey (= x 10)) 9))
;    (test? 10 x))
;  (test? 12 (do (get but zz) 12))
;  (let y nil
;    (let ignore (do (%literal y | = 10;|) 42)
;      (test? 10 y))))

(define-test string
  (test? 3 (len "foo"))
  (test? 3 (len "\"a\""))
  ;(test? 'a "a")
  (test? #\a ("bar" 1))
  ;(test? #\a (coerce "a" 'char))
  (test? '(#\a #\b #\c) (coerce "abc" 'cons))
  (let s "a
b"
    (test? 3 (len s)))
  (let s "a
b
c"
    (test? 5 (len s)))
  (test? 3 (len "a\nb"))
  (test? 3 (len "a\\b"))
  ;(test? "x3" (cat "x" (+ 1 2)))
  )

(define-test atstrings
  (let a 'foo
    (test? "barfoo" "bar@a")
    (test? "foobar" "@{a}bar")
    ;(test? "" "@unset")
    (test? "" "@nil")
    (test? "" "@(list)")
    (test? "T" "@t")
    ;(test? "false" "@false")
    )
  ; nested strings inside @(...): bare and backslash-escaped quotes
  ; both work, and \" inside a nested string is preserved for arc-read.
  (test? "3" "@(len "abc")")
  (test? "3" "@(len \"abc\")")
  (test? "ab" "@(+ "a" "b")")
  (test? "a\"b" "@(+ "a\"b" "")"))

(define-test quote
  (test? 7 (quote 7))
  (test? t (quote t))
  (test? nil (quote nil))
  ;(test? true (quote true))
  ;(test? false (quote false))
  (test? (quote a) 'a)
  (test? (quote (quote a)) ''a)
  (test? "a" '"a")
  (test? "\n" (quote "\n"))
  (test? "\r\n" (quote "\r\n"))
  (test? "\\" (quote "\\"))
  (test? '(quote "a") ''"a")
  (test? t (isnt '|(| '|)|))
  (test? (quote unquote) 'unquote)
  (test? (quote (unquote)) '(unquote))
  (test? (quote (unquote a)) '(unquote a))
  ;(let x '(10 20 a: 33 1a: 44)
  ;  (test? 20 (at x 1))
  ;  (test? 33 (get x 'a))
  ;  (test? 44 (get x '1a)))
  )

(define-test list
  (test? '() (list))
  (test? () (list))
  (test? '(a) (list 'a))
  ;(test? '(false) (list false)) ; todo
  (test? '(a) (quote (a)))
  (test? '(()) (list (list)))
  (test? 0 (len (list)))
  (test? 2 (len (list 1 2)))
  (test? '(1 2 3) (list 1 2 3))
  ;(test? 17 (get (list foo: 17) 'foo))
  ;(test? 17 (get (list 1 foo: 17) 'foo))
  ;(test? true (get (list :foo) 'foo))
  ;(test? true (get '(:foo) 'foo))
  ;(test? true (get (hd '((:foo))) 'foo))
  ;(test? '(:a) (list :a))
  ;(test? '(b: false) (list b: false))
  ;(test? '(c: 0) (list c: 0))
  ;(let d 42
  ;  (test? `(d: ,d) (list :d)))
  )

(define-test testify
  ; non-fn test => (is _ x) by default
  (test? t   ((testify 5) 5))
  (test? nil ((testify 5) 4))
  ; a fn test is returned unchanged (used as-is)
  (test? t   ((testify [> _ 0]) 5))
  (test? nil ((testify [> _ 0]) -1))
  ; optional cmp replaces is
  (test? t   ((testify 5 >) 6))
  (test? nil ((testify 5 >) 4)))

(define-test iso
  ; iso is kept as an alias for is (which is a deep compare here)
  (test? t   (iso '(1 2 (3)) '(1 2 (3))))
  (test? nil (iso '(1 2) '(1 3) '(1 3)))
  (test? t   (iso "ab" "ab" "ab")))

(define-test some
  ; default is, list branch
  (test? t   (some 2 '(1 2 3)))
  (test? nil (some 9 '(1 2 3)))
  ; default is, string branch
  (test? t   (some #\c "abc"))
  (test? nil (some #\z "abc"))
  ; with cmp, list branch
  (test? t   (some 2 '(1 2 3) >))
  (test? nil (some 5 '(1 2 3) >))
  ; with cmp, string branch (cmp always true => first char matches)
  (test? t   (some #\z "abc" (fn (a b) t))))

(define-test all
  (test? t   (all 0 '(1 2 3) >))
  (test? nil (all 2 '(1 2 3) >))
  (test? t   (all 1 '(1 1 1)))
  (test? nil (all 1 '(1 2 1))))

(define-test find
  ; default is, list branch
  (test? 2   (find 2 '(1 2 3)))
  (test? nil (find 9 '(1 2 3)))
  ; default is, string branch (returns the matching char)
  (test? #\c (find #\c "abc"))
  (test? nil (find #\z "abc"))
  ; with cmp, list branch (first elt > 2)
  (test? 3   (find 2 '(1 2 3 4) >))
  ; with cmp, string branch
  (test? #\a (find #\z "abc" (fn (a b) t))))

(define-test mem
  ; mem (the function) returns the tail starting at the first match
  (test? '(2 3)   (mem 2 '(1 2 3)))
  (test? nil      (mem 9 '(1 2 3)))
  ; with cmp: tail from first elt > 2
  (test? '(3 4)   (mem 2 '(1 2 3 4) >)))

(define-test rem
  ; default is, list branch
  (test? '(1 3)   (rem 2 '(1 2 3 2)))
  ; default is, string branch
  (test? "ac"     (rem #\b "abcb"))
  ; with cmp, list branch (remove elts > 2)
  (test? '(1 2)   (rem 2 '(1 2 3 4) >))
  ; with cmp, string branch (cmp always true => remove everything)
  (test? ""       (rem #\a "abc" (fn (x y) t))))

(define-test keep
  (test? '(2 2)   (keep 2 '(1 2 3 2)))
  ; with cmp: keep elts > 2
  (test? '(3 4)   (keep 2 '(1 2 3 4) >)))

(define-test adjoin
  ; default test is is
  (test? '(1 2 3)   (adjoin 2 '(1 2 3)))   ; already present, no dup
  (test? '(9 1 2 3) (adjoin 9 '(1 2 3)))   ; absent, prepend
  ; with custom test: some elt > 2 already, so 2 is "present"
  (test? '(1 2 3)   (adjoin 2 '(1 2 3) >))
  ; none > 9, so 9 is added
  (test? '(9 1 2 3) (adjoin 9 '(1 2 3) >)))

(define-test setmem
  ; truthy test => adjoin
  (with (s (list 1 2 3))
    (setmem t 9 s)
    (test? '(9 1 2 3) s))
  (with (s (list 1 2 3))
    (setmem t 2 s)             ; already present, no dup
    (test? '(1 2 3) s))
  ; nil test => rem
  (with (s (list 1 2 3 2))
    (setmem nil 2 s)
    (test? '(1 3) s))
  ; with cmp arg
  (with (s (list 1 2 3 4))
    (setmem nil 2 s >)         ; remove elts > 2
    (test? '(1 2) s)))

(define-test mem-place
  ; mem is a settable place via defset; (= (mem x lst) t/nil) adds/removes
  (with (s (list 1 2 3))
    (= (mem 9 s) t)
    (test? '(9 1 2 3) s)
    (= (mem 9 s) nil)
    (test? '(1 2 3) s)))

(define-test pushnew
  (with (s (list 1 2 3))
    (pushnew 2 s)              ; present, no change
    (test? '(1 2 3) s)
    (pushnew 9 s)              ; absent, prepend
    (test? '(9 1 2 3) s))
  ; with test arg
  (with (s (list 1 2 3))
    (pushnew 9 s >)            ; none > 9 => add
    (test? '(9 1 2 3) s)
    (pushnew 0 s >)            ; some > 0 => no add
    (test? '(9 1 2 3) s)))

(define-test pull
  (with (s (list 1 2 3 2))
    (pull 2 s)
    (test? '(1 3) s))
  ; with test arg
  (with (s (list 1 2 3 4))
    (pull 2 s >)               ; remove elts > 2
    (test? '(1 2) s)))

(define-test togglemem
  (with (s (list 1 2 3))
    (togglemem 9 s)            ; absent => add
    (test? '(9 1 2 3) s)
    (togglemem 9 s)            ; present => remove
    (test? '(1 2 3) s))
  ; with test arg
  (with (s (list 1 2 3))
    (togglemem 9 s >)          ; none > 9 => add
    (test? '(9 1 2 3) s)
    (togglemem 0 s >)          ; some > 0 => remove elts > 0
    (test? nil s)))

(define-test fn-names
  ; A fn compiles to a named lambda whose arc name shows up in SBCL
  ; backtraces; sb-kernel::%fun-name reads it back.  Names combine with
  ; enclosing fns -- these defs sit inside test-fn-names, so they get a
  ; test-fn-names-- prefix.
  (def fn-names-simple (x) x)
  (test? 'test-fn-names--fn-names-simple
         (sb-kernel::%fun-name fn-names-simple))
  ; complex arglists (optionals) are named too
  (def fn-names-opt (x (o y 1)) x)
  (test? 'test-fn-names--fn-names-opt
         (sb-kernel::%fun-name fn-names-opt))
  ; a let-bound fn value is named after its variable (let expands to an
  ; immediately-applied fn, and ac names the value arg after the param)
  (let g (fn (x) x)
    (test? 'test-fn-names--g (sb-kernel::%fun-name g)))
  ; an otherwise-anonymous fn inherits the enclosing name
  (test? 'test-fn-names (sb-kernel::%fun-name (fn (x) x))))

(define-test byte-vectors
  ; ar-apply indexes a vector, len/type understand it
  (let v (coerce '(104 105 106) 'vector)
    (test? 104 (v 0))
    (test? 106 (v 2))
    (test? 3   (len v))
    (test? 'vector (type v)))
  ; coerce round-trips list <-> byte vector (ints in [0..255])
  (test? '(1 2 255) (coerce (coerce '(1 2 255) 'vector) 'cons))
  (test? 0          (len (coerce nil 'vector)))    ; empty list -> empty vec
  ; is compares byte vectors elementwise
  (test? t   (is (coerce '(1 2 3) 'vector) (coerce '(1 2 3) 'vector)))
  (test? nil (is (coerce '(1 2 3) 'vector) (coerce '(1 2 4) 'vector)))
  (test? nil (is (coerce '(1 2)   'vector) (coerce '(1 2 3) 'vector))))

(define-test table
  ; flat keys (string/symbol/int), absent key, and default for absent
  (let h (table)
    (= (h "a") 1  (h 'b) 2  (h 3) 'three)
    (test? 1      (h "a"))
    (test? 2      (h 'b))
    (test? 'three (h 3))
    (test? nil    (h "missing"))
    (test? 'd     (h "missing" 'd))
    (test? 3      (len h)))
  ; the optional init fn is called on the new table
  (test? 1 ((table [sref _ 1 'x]) 'x))
  ; cons keys match by content (equal deep-compares conses)
  (let h (table)
    (= (h '(1 2)) 'x)
    (test? 'x (h (list 1 2)))
    (test? 1  (len h)))
  ; but a table key compares by identity under equal: a distinct
  ; equal-content table is a different key
  (let h (table)
    (let k (obj a 1)
      (= (h k) 'same)
      (test? 'same (h k)))            ; same object -> found
    (test? nil (h (obj a 1)))         ; distinct equal table -> not found
    (test? 1   (len h))))

(define-test isotable
  ; table keys are compared structurally (deep), unlike a regular table
  (let h (isotable)
    (= (h (obj a 1 b 2)) 'foo)
    (test? 'foo (h (obj a 1 b 2)))    ; distinct table, same content -> found
    (test? nil  (h (obj a 1)))        ; different content -> not found
    (test? 1    (len h)))
  ; vector and cons keys also match by content
  (let h (isotable)
    (= (h (coerce '(1 2 3) 'vector)) 'vec
       (h '(9 8))                     'lst)
    (test? 'vec (h (coerce '(1 2 3) 'vector)))
    (test? 'lst (h (list 9 8)))
    (test? nil  (h (coerce '(1 2) 'vector)))
    (test? 2    (len h)))
  ; equality stays case-sensitive (arc-is2 is the test; psxhash, which is
  ; case-insensitive, only shares a bucket -- it doesn't merge the keys)
  (let h (isotable)
    (= (h "Foo") 'u  (h "foo") 'l)
    (test? 'u (h "Foo"))
    (test? 'l (h "foo"))
    (test? 2  (len h))))

(define-test utf8
  ; string <-> utf-8 bytes (λ = U+03BB = ce bb, é = c3 a9)
  (test? '(206 187)     (coerce (utf8-encode "λ") 'cons))
  (test? "λ"            (utf8-decode (coerce '(206 187) 'vector)))
  (test? '(104 195 169) (coerce (utf8-encode "hé") 'cons))
  (test? "héllo"        (utf8-decode (utf8-encode "héllo")))
  ; string->bytes / bytes->string default to utf-8 and take a format
  (test? '(206 187) (coerce (string->bytes "λ") 'cons))
  (test? "λ"        (bytes->string (coerce '(206 187) 'vector)))
  (test? '(233)     (coerce (string->bytes "é" :latin-1) 'cons)))

(define-test utf8-file
  ; writefile/readfile1 (the profile save path) must round-trip codepoints
  ; >255 now that outfile/infile are utf-8.  U+2019 (the curly ' that
  ; crashed profiles) is utf-8 e2 80 99; also test lambda and a CJK char.
  (let s (+ "I" (utf8-decode (coerce '(226 128 153) 'vector)) "m happy λ 日")
    (let f "test-utf8-roundtrip.tmp"
      (writefile s f)
      (test? s (readfile1 f))
      (rmfile f))))

(define-test binary-file
  ; a :default stream round-trips raw bytes verbatim (readb/writeb bypass
  ; the utf-8 external-format): read a real png, which has high bytes like
  ; the 0x89 signature, rewrite it, and confirm the bytes are identical.
  (with (src (w/infile i "static/arc.png" (drain (readb i)))
         f   "test-binary-roundtrip.tmp")
    (w/outfile o f (each b src (writeb b o)))
    (test? src (w/infile i f (drain (readb i))))
    (rmfile f)))

(define-test urlencode
  ; ascii unreserved passes through; space and reserved are %-escaped
  (test? "abc-._~"    (urlencode "abc-._~"))
  (test? "a%20b"      (urlencode "a b"))
  (test? "a%2bb"      (urlencode "a+b"))        ; literal + -> %2b
  ; non-ascii becomes its utf-8 bytes
  (test? "h%c3%a9llo" (urlencode "héllo"))
  (test? "x%ce%bbx"   (urlencode "xλx"))
  ; urldecode inverts; + and %XX both denote a byte
  (test? "héllo" (urldecode "h%c3%a9llo"))
  (test? "xλx"   (urldecode "x%ce%bbx"))         ; the doc example
  (test? "a b"   (urldecode "a+b"))
  (test? "a b"   (urldecode "a%20b"))
  (test? "a+b"   (urldecode "a%2bb"))
  ; round-trips, including multibyte and empty
  (test? "日本語" (urldecode (urlencode "日本語")))
  (test? "" (urlencode ""))
  (test? "" (urldecode "")))

(define-test quasiquote
  (test? (quote a) (quasiquote a))
  (test? 'a `a)
  (test? () `())
  (test? 2 `,2)
  (test? nil `(,@nil))
  (let a 42
    (test? 42 `,a)
    (test? 42 (quasiquote (unquote a)))
    (test? '(quasiquote (unquote a)) ``,a)
    (test? '(quasiquote (unquote 42)) ``,,a)
    (test? '(quasiquote (quasiquote (unquote (unquote a)))) ```,,a)
    (test? '(quasiquote (quasiquote (unquote (unquote 42)))) ```,,,a)
    (test? '(a (quasiquote (b (unquote c)))) `(a `(b ,c)))
    (test? '(a (quasiquote (b (unquote 42)))) `(a `(b ,,a)))
    (let b 'c
      (test? '(quote c) `',b)
      (test? '(42) `(,a))
      (test? '((42)) `((,a)))
      (test? '(41 (42)) `(41 (,a)))))
  (let c '(1 2 3)
    (test? '((1 2 3)) `(,c))
    (test? '(1 2 3) `(,@c))
    (test? '(0 1 2 3) `(0 ,@c))
    (test? '(0 1 2 3 4) `(0 ,@c 4))
    (test? '(0 (1 2 3) 4) `(0 (,@c) 4))
    (test? '(1 2 3 1 2 3) `(,@c ,@c))
    (test? '((1 2 3) 1 2 3) `((,@c) ,@c)))
  (let a 42
    (test? '(quasiquote ((unquote-splicing (list a)))) ``(,@(list a)))
    (test? '(quasiquote ((unquote-splicing (list 42)))) ``(,@(list ,a))))
  ;(test? true (get `(:foo) 'foo))
  ;(let (a 17
  ;      b '(1 2)
  ;      c (obj a: 10)
  ;      d (list a: 10))
  ;  (test? 17 (get `(foo: ,a) 'foo))
  ;  (test? 2 (# `(foo: ,a ,@b)))
  ;  (test? 17 (get `(foo: ,@a) 'foo))
  ;  (test? '(1 a: 10) `(1 ,@c))
  ;  (test? '(1 a: 10) `(1 ,@d))
  ;  (test? true (get (hd `((:foo))) 'foo))
  ;  (test? true (get (hd `(,(list :foo))) 'foo))
  ;  (test? true (get `(,@(list :foo)) 'foo))
  ;  (test? true (get `(1 2 3 ,@'(:foo)) 'foo)))
  ;(let-macro ((a keys `(obj ,@keys)))
  ;  (test? true (get (a :foo) 'foo))
  ;  (test? 17 (get (a bar: 17) 'bar)))
  ;(let-macro ((a () `(obj baz: (fn () 17))))
  ;  (test? 17 ((get (a) 'baz))))
  )

(define-test quasiexpand
  (withs (x 'x z 'z)
    (test? 'a (macex 'a))
    (test? '(17) (macex '(17)))
    (test? '(1 z) (macex '(1 z)))
    (test? '(quasiquote (1 z)) (macex '`(1 z)))
    (test? '(quasiquote ((unquote 1) (unquote z))) (macex '`(,1 ,z)))
    (test? '(1 z) `(1 z))
    (test? '(1 z) `(,1 ,z))
    (let z '(z)
      (test? '(z) `(,@z)))
    ;(test? '(join (%array 1) z) (macex '`(,1 ,@z)))
    ;(test? '(join (%array 1) x y) (macex '`(,1 ,@x ,@y)))
    ;(test? '(join (%array 1) z (%array 2)) (macex '`(,1 ,@z ,2)))
    ;(test? '(join (%array 1) z (%array "a")) (macex '`(,1 ,@z a)))
    ;(test? '"x" (macex '`x))
    ;(test? '(%array "quasiquote" "x") (macex '``x))
    ;(test? '(%array "quasiquote" (%array "quasiquote" "x")) (macex '```x))
    ;(test? 'x (macex '`,x))
    ;(test? '(%array "quote" x) (macex '`',x))
    ;(test? '(%array "quasiquote" (%array "x")) (macex '``(x)))
    ;(test? '(%array "quasiquote" (%array "unquote" "a")) (macex '``,a))
    ;(test? '(%array "quasiquote" (%array (%array "unquote" "x")))
    ;       (macex '``(,x)))))
    ))

(define-test calls
  (withs (f (fn () 42)
          l (list f)
          ;t (obj f f) ; todo
          )
    (f)
    ((fn ()
      (test? 42 (f))))
    (test? 42 ((l 0)))
    ;(test? 42 ((t 'f)))
    ;(test? 42 (t!f))
    (test? nil ((fn ())))
    (test? 10 ((fn (x) (- x 2)) 12))
    ;(= plus '+)
    ;(test? 3 (plus 1 2))
    ;(test? 3 ('plus 1 2))
    ;(= p 'pr)
    ;(test? "1,2,3" (tostring:p 1 2 3 sep: ","))
    ))

;(define-test identifier
;  (let (a 10
;        b (obj x: 20)
;        f (fn () 30))
;    (test? 10 a)
;    (test? 10 (%literal a))
;    (test? 20 (%literal b |.x|))
;    (test? 30 (%literal f |()|))))

(define-test names
  (withs (a! 0
          b? 1
          -% 2
          ** 3
          break 4)
    (test? 0 a!)
    (test? 1 b?)
    (test? 2 -%)
    (test? 3 **)
    (test? 4 break)))

(define-test =
  (test? 1 (= xx 1))
  (test? 1 xx)
  (test? 2 (= yy 1 zz 2))
  (test? 1 yy)
  (test? 2 zz)
  (let a 42
    (= a 'bar)
    (test? 'bar a)
    (let x (= a 10)
      (test? 10 x)
      (test? 10 a))
    (= a false)
    (test? false a)
    (= a)
    (test? nil a)))

(define-test wipe
  (let x (obj a t b t c t)
    (wipe (x 'a))
    (test? nil (x 'a))
    (test? true (x 'b))
    (wipe (x 'c))
    (test? nil (x 'c))
    (test? true (x 'b))
    (wipe (x 'b))
    (test? nil (x 'b))
    ;(test? (obj) x) ; todo
    ))

(define-test do
  (let a 17
    (do (= a 10)
        (test? 10 a))
    (test? 10 (do a))
    (let b (do (= a 2) (+ a 5))
      (test? a 2)
      (test? b 7))
    (do (= a 10)
        (do (= a 20)
            (test? 20 a)))
    (test? 20 (do (= a 10)
                  (do (= a 20) a))))
  (test? '(%do) (macex '(do))))

(define-test if
  (test? '(if a) (macex '(if a)))
  (test? '(if a b) (macex '(if a b)))
  (test? '(if a b c) (macex '(if a b c)))
  (test? '(if a b c d) (macex '(if a b c d)))
  (test? '(if a b c d e) (macex '(if a b c d e)))
  (if true
      (test? true true)
    (test? true false))
  (if false (test? true false)
      false (test? false true)
    (test? true true))
  (if false (test? true false)
      false (test? false true)
      false (test? false true)
    (test? true true))
  (if false (test? true false)
      true (test? true true)
      false (test? false true)
    (test? true true))
  (test? false (if false true false))
  (test? 1 (if true 1 2))
  (test? 1 (if (let a 10 a) 1 2))
  (test? 1 (if true (do1 1) 2))
  (test? 1 (if false 2 (let a 1 a)))
  (test? 1 (if false 2 true (do1 1)))
  (test? 1 (if false 2 false 3 (let a 1 a)))
  (test? 0 (if false 1 0)))

(define-test case
  (let x 10
    (test? 2 (case x 9 9 10 2 4))
    (test? 2 (case x 9 9 (10) 2 4))
    (test? 2 (case x 9 9 (10 20) 2 4)))
  (let x 'z
    (test? 9 (case x z 9 10))
    (test? 7 (case x a 1 b 2 7))
    (test? 2 (case x a 1 (z) 2 7))
    (test? 2 (case x a 1 (b z) 2 7)))
  (withs (n 0 f (fn () (++ n))) ; no multiple eval
    (test? 'b (case (f) 0 'a 1 'b 'c)))
  (test? 'b ((fn () (case 2 0 (do) 1 'a 2 'b)))))

(define-test or=
  ;; sets a global that's currently nil
  (= or=g1* nil)
  (or= or=g1* 'default)
  (test? 'default or=g1*)
  ;; keeps an already-truthy global
  (= or=g2* 99)
  (or= or=g2* 7)
  (test? 99 or=g2*)
  ;; unbound global: assigns instead of erroring (idempotent across reruns)
  (or= or=unbound* 'set)
  (test? 'set or=unbound*)
  ;; lexical bound to nil gets set; truthy lexical kept
  (test? 5 (let v nil (or= v 5) v))
  (test? 3 (let v 3   (or= v 5) v))
  ;; variadic: sets the unset ones, keeps the set ones
  (= or=a* nil or=b* 10 or=c* nil)
  (or= or=a* 1 or=b* 20 or=c* 3)
  (test? 1  or=a*)
  (test? 10 or=b*)
  (test? 3  or=c*)
  ;; compound place: assign then keep
  (let h (table)
    (or= (h 'k) (list 1 2))
    (test? '(1 2) (h 'k))
    (or= (h 'k) (list 9 9))
    (test? '(1 2) (h 'k)))
  ;; the default expr is not evaluated when the place is already truthy
  (with (evaled nil)
    (= or=e* 1)
    (or= or=e* (do (= evaled t) 2))
    (test? nil evaled))
  ;; eval-once: a place's subforms run exactly once, slot empty
  (withs (h (table) n 0 key (fn () (++ n) 'k))
    (or= (h (key)) 'v)
    (test? 'v (h 'k))
    (test? 1 n))
  ;; eval-once: a place's subforms run exactly once, slot already set
  (withs (h (obj k 'present) n 0 key (fn () (++ n) 'k))
    (or= (h (key)) 'v)
    (test? 'present (h 'k))
    (test? 1 n)))

(define-test w/assign
  ;; temporarily set a place, restore afterward
  (= w/assign-g* 'orig)
  (w/assign w/assign-g* 'temp
    (test? 'temp w/assign-g*))
  (test? 'orig w/assign-g*)
  ;; restores even when the body errors
  (= w/assign-g* 'orig)
  (errsafe (w/assign w/assign-g* 'temp (err "boom")))
  (test? 'orig w/assign-g*)
  ;; returns the body's last value
  (= w/assign-g* 'orig)
  (test? 'result (w/assign w/assign-g* 'temp 'ignored 'result))
  ;; nested: restores the enclosing value, not a fixed default
  (= w/assign-g* 'a)
  (w/assign w/assign-g* 'b
    (test? 'b w/assign-g*)
    (w/assign w/assign-g* 'c
      (test? 'c w/assign-g*))
    (test? 'b w/assign-g*))
  (test? 'a w/assign-g*)
  ;; compound place (table slot)
  (let h (obj k 'orig)
    (w/assign (h 'k) 'temp
      (test? 'temp (h 'k)))
    (test? 'orig (h 'k)))
  ;; double-eval protection: a place's subforms evaluate exactly once
  (withs (h (obj k 'orig) n 0 key (fn () (++ n) 'k))
    (w/assign (h (key)) 'temp
      (test? 'temp (h 'k)))
    (test? 'orig (h 'k))
    (test? 1 n)))

(define-test thread-local-the
  ;; (the var) returns nil when unset; (= (the var) val) sets it
  (= (the test-tl) nil)
  (test? nil (the test-tl))
  (= (the test-tl) 42)
  (test? 42 (the test-tl))
  (= (the test-tl) "hello")
  (test? "hello" (the test-tl))
  ;; isolation between different keys
  (= (the test-tl) 1  (the test-tl2) 2)
  (test? 1 (the test-tl))
  (test? 2 (the test-tl2)))

(define-test thread-local-w/the
  ;; w/the binds for the body, restores on exit (including on error)
  (= (the test-tl) 'outer)
  (w/the test-tl 'inner
    (test? 'inner (the test-tl)))
  (test? 'outer (the test-tl))
  ;; restoration on error
  (errsafe
    (w/the test-tl 'errored
      (err "boom")))
  (test? 'outer (the test-tl))
  ;; nested
  (w/the test-tl 'a
    (test? 'a (the test-tl))
    (w/the test-tl 'b
      (test? 'b (the test-tl)))
    (test? 'a (the test-tl)))
  (test? 'outer (the test-tl)))

(define-test thread-local-w/the-me
  (= (the me) 'baseline)
  (w/the me 'overridden
    (test? 'overridden (the me)))
  (test? 'baseline (the me)))

(define-test thread-local-t-param
  ;; (t var) -- arg defaults to (the var) if caller omits it
  (def get-tl-me ((t me)) me)
  (= (the me) 'thread-default)
  (test? 'thread-default (get-tl-me))
  (test? 'explicit (get-tl-me 'explicit))
  ;; (t local var) -- local name differs from thread-local key
  (def get-as-u ((t u me)) u)
  (test? 'thread-default (get-as-u))
  (test? 'override (get-as-u 'override))
  ;; mixing positional + (t var)
  (def greet (g (t me)) (+ g " " (string me)))
  (test? "hi thread-default" (greet "hi"))
  (test? "hi bob" (greet "hi" 'bob)))

(define-test thread-local-isolation
  ;; each thread sees its own bindings
  (= (the test-tl) 'main)
  (with (done (sb-thread::make-semaphore)
         child-saw nil)
    (thread
      (= (the test-tl) 'child)
      (= child-saw (the test-tl))
      (sb-thread::signal-semaphore done))
    (sb-thread::wait-on-semaphore done)
    (test? 'child child-saw)
    ;; main's value is unchanged by child's mutation
    (test? 'main (the test-tl))))

(define-test ssyntax-with-cl-packages
  (test? '(complement sb-thread::make-mutex) (ssexpand '~sb-thread::make-mutex))
  (test? '(compose a sb-thread::make-mutex) (ssexpand 'a:sb-thread::make-mutex))
  (test? '(andf a sb-thread::make-mutex) (ssexpand 'a&sb-thread::make-mutex))
  (test? nil (~sb-thread::make-mutex))
  (test? 1 (len:accum a (a:sb-thread::make-mutex))))

(define-test quasisyntax
  ;; CL `let` is a special form and needs ((var val) ...) unevaluated;
  ;; without quasisyntax, ac would compile ((y 7)) as a function call.
  (test? 7 #`(cl::let ((y 7)) y))
  ;; Bare operators (no cl:: prefix) work too: ac-qs uppercases arc
  ;; symbols to their CL symbols, like #' does, so `let`/`+`/etc. resolve
  ;; to the CL ones.
  (test? 7    #`(let ((y 7)) y))
  (test? 6    #`(+ 1 2 3))
  (test? "hi" #`(with-output-to-string (s) (princ "hi" s)))
  ;; #, substitutes an arc-evaluated expression into the hole.
  (let v 41
    (test? 41 #`(cl::let ((y #,v)) y)))
  ;; The hole can be any arc expression.
  (test? 6 #`(cl::let ((s #,(apply + '(1 2 3)))) s))
  ;; Multiple holes in one form.
  (with (a 10 b 32)
    (test? 42 #`(cl::let ((x #,a) (y #,b)) (cl::+ x y))))
  ;; Symbols not inside #, are passed through literally to CL --
  ;; here `s` is a stream binding consumed by with-output-to-string.
  (test? "hi 42" #`(cl::with-output-to-string (s)
                     (cl::princ "hi " s)
                     (cl::princ #,(+ 40 2) s)))
  ;; unsyntax outside quasisyntax errors at compile time.
  (test? nil (errsafe (eval (list 'unsyntax ''foo))))
  ;; unsyntax-splicing inside quasisyntax is rejected.
  (test? nil (errsafe (eval (list 'quasisyntax
                                  (list 'foo (list 'unsyntax-splicing
                                                   ''(1 2))))))))

(define-test table-destructure
  ;; basic: (:a :b :c) binds locals a, b, c by table lookup.
  (test? '(1 2 3)
         ((fn ((:a :b :c)) (list a b c))
          (obj a 1 b 2 c 3)))
  ;; missing keys yield nil.
  (test? '(1 nil 3)
         ((fn ((:a :b :c)) (list a b c))
          (obj a 1 c 3)))
  ;; (o :k default) supplies a default when the key is absent.
  (test? '(1 2 42)
         ((fn ((:a :b (o :c 42))) (list a b c))
          (obj a 1 b 2)))
  (test? '(1 2 3)
         ((fn ((:a :b (o :c 42))) (list a b c))
          (obj a 1 b 2 c 3)))
  ;; defaults are lazily evaluated (only when missing).
  (let count* 0
    ((fn (((o :x (do (++ count*) 99)))) x)
     (obj x 7))
    (test? 0 count*))
  ;; foo: and :foo both denote the key foo (reader produces :FOO).
  (test? '(1 2)
         ((fn ((a: :b)) (list a b))
          (obj a 1 b 2)))
  ;; remap: keyword followed by a symbol uses the symbol as the local.
  (test? '(7 8 9)
         ((fn ((foo: x bar: y :baz)) (list x y baz))
          (obj foo 7 bar 8 baz 9)))
  ;; nested table destructuring: keyword + sub-pattern.
  (test? '(10 20)
         ((fn ((:outer (:x :y))) (list x y))
          (obj outer (obj x 10 y 20))))
  ;; table pattern interleaved with positional args.
  (test? '(99 1 2)
         ((fn (n (:a :b)) (list n a b))
          99 (obj a 1 b 2)))
  ;; two table patterns at distinct positional slots.
  (test? '(1 2 3 4)
         ((fn ((:a :b) (:c :d)) (list a b c d))
          (obj a 1 b 2) (obj c 3 d 4))))

(define-test json-encode-primitives
  (test? "null"  (tostring (to-json nil)))
  (test? "true"  (tostring (to-json t)))
  (test? "0"     (tostring (to-json 0)))
  (test? "42"    (tostring (to-json 42)))
  (test? "-7"    (tostring (to-json -7)))
  (test? "\"hi\"" (tostring (to-json "hi")))
  (test? "\"x\"" (tostring (to-json #\x)))
  (test? "\"sym\"" (tostring (to-json 'sym))))

(define-test json-encode-escapes
  (test? "\"a\\\"b\""           (tostring (to-json "a\"b")))
  (test? "\"a\\\\b\""           (tostring (to-json "a\\b")))
  (test? "\"a\\nb\""            (tostring (to-json "a\nb")))
  (test? "\"a\\tb\""            (tostring (to-json "a\tb")))
  (test? "\"\\u0001\""          (tostring (to-json (string (coerce 1 'char))))))

(define-test json-encode-array
  ; nil encodes as JSON null, not [] (Arc conflates nil + empty list)
  (test? "[1,2,3]"   (tostring (to-json '(1 2 3))))
  (test? "[\"a\",\"b\"]" (tostring (to-json '("a" "b"))))
  (test? "[1,[2,3]]" (tostring (to-json '(1 (2 3))))))

(define-test json-encode-object
  (test? "{}"                  (tostring (to-json (table))))
  (test? "{\"a\":1}"           (tostring (to-json (obj a 1))))
  ; keys are sorted lexicographically for determinism
  (test? "{\"a\":1,\"b\":2}"   (tostring (to-json (obj b 2 a 1))))
  (test? "{\"nest\":[1,2]}"    (tostring (to-json (obj nest '(1 2))))))

(define-test json-decode-primitives
  (test? nil   (from-json "null"))
  (test? t     (from-json "true"))
  (test? nil   (from-json "false"))
  (test? 42    (from-json "42"))
  (test? -7    (from-json "-7"))
  (test? "hi"  (from-json "\"hi\"")))

(define-test json-decode-escapes
  (test? "a\"b"   (from-json "\"a\\\"b\""))
  (test? "a\\b"   (from-json "\"a\\\\b\""))
  (test? "a/b"   (from-json "\"a\\/b\""))
  (test? "a\nb"   (from-json "\"a\\nb\""))
  (test? "a\tb"   (from-json "\"a\\tb\""))
  (test? "A"      (from-json "\"\\u0041\"")))

(define-test json-decode-array
  (test? nil       (from-json "[]"))
  (test? '(1 2 3)  (from-json "[1,2,3]"))
  (test? '(1 (2 3) "x")  (from-json "[1,[2,3],\"x\"]"))
  ; whitespace
  (test? '(1 2)    (from-json "[ 1 , 2 ]")))

(define-test json-decode-object
  (let h (from-json "{\"a\":1,\"b\":\"two\"}")
    (test? 1     h!a)
    (test? "two" h!b))
  (let h (from-json "{}")
    (test? 0 (len (keys h)))))

(define-test json-roundtrip
  (let h (from-json "{\"id\":\"pg\",\"karma\":157316,\"about\":\"hi\",\"submitted\":[1,2,3],\"flag\":true}")
    (test? "{\"about\":\"hi\",\"flag\":true,\"id\":\"pg\",\"karma\":157316,\"submitted\":[1,2,3]}"
           (tostring (to-json h)))))

(when (main)
  (run-tests))
