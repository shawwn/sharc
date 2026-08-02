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
  (let label (sym:string "test-" name)
    `(do (def ,label ()
           (point return ,@body))
         (= (tests* ',name) ,label))))

(def run-tests ()
  (= passed* 0 failed* 0)
  (each (name f) tests*
    (let result (f)
      (when (isa!string result)
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
  (test? 2   (med '(3 1 2))) ; odd: middle element
  (test? 3   (med '(1 2 3 4 5))) ; odd, longer
  (test? 5/2 (med '(4 1 2 3))) ; even: average of the two middles
  (test? 15  (med '(10 20))) ; even pair
  (test? 7   (med '(7)))) ; single element

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
  (test? #\a (as!char "a"))
  (test? '(#\a #\b #\c) (chars "abc"))
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

; (+ "" x ...) and (string x ...) agree on atoms but diverge on lists:
; string-coercing a list concatenates the coerced *elements*, while +
; (dispatching on the leading string) uses the list's printed form.
(define-test string-coerce
  ; atoms: identical
  (test? "123"  (+ "" 123))       (test? "123"  (string 123))
  (test? "sym"  (+ "" 'sym))      (test? "sym"  (string 'sym))
  (test? "a"    (+ "" #\a))       (test? "a"    (string #\a))
  (test? ""     (+ "" nil))       (test? ""     (string nil))
  (test? "xy"   (+ "" "x" "y"))   (test? "xy"   (string "x" "y"))
  ; lists diverge: + prints the whole list, string concatenates elements
  (test? "(a b c)" (+ "" '(a b c)))
  (test? "abc"     (string '(a b c)))
  ; a list of chars is the case string is meant for
  (test? "(a b)" (+ "" '(#\a #\b)))
  (test? "ab"    (string '(#\a #\b)))
  ; nested lists: + keeps structure; string keeps only the inner list's parens
  (test? "(1 2 (3 4))" (+ "" '(1 2 (3 4))))
  (test? "12(3 4)"     (string '(1 2 (3 4))))
  ; the reported example (note: (+ "" ...) keeps the trailing 123 too)
  (test? "(a b c)123" (+ "" '(a b c) 123))
  (test? "abc123"     (string '(a b c) 123)))

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

; ssyntax: syntax embedded in a symbol's name, expanded by the compiler.
; Operators, loosest to tightest binding: &  |  (: ~)  (. !)
; ssexpand does one level; inner operators (e.g. ~bar) stay as symbols.
(define-test ssyntax
  ; compose (:), complement (~)
  (test? '(compose car cdr) (ssexpand 'car:cdr))
  (test? '(complement odd)  (ssexpand '~odd))
  (test? 3     (car:cdr:cdr '(1 2 3 4)))
  (test? true  (~odd 4))
  (test? false (~odd 3))
  ; sexpr: a.b calls, a!b passes a quoted arg
  (test? '(a b)         (ssexpand 'a.b))
  (test? '(a (quote b)) (ssexpand 'a!b))
  ; andf (&) and orf (|); ssyntax resolves lexical predicates too
  (test? '(andf a b) (ssexpand 'a&b))
  (test? '(orf  a b) (ssexpand 'a|b))
  (withs (small [< _ 10] big [> _ 100])
    (test? true  (small&odd 7))
    (test? false (small&odd 4))    ; even
    (test? false (small&odd 13))   ; not small
    (test? true  (small|big 5))
    (test? false (small|big 50))   ; neither
    (test? true  (small|big 200)))
  ; priority: ~ binds tighter than &, so foo&~bar = (andf foo (complement bar))
  (test? '(andf foo ~bar) (ssexpand 'foo&~bar))
  (test? '(andf ~bar foo) (ssexpand '~bar&foo))
  (test? true  (odd&~even 3))
  (test? false (odd&~even 4))      ; ~ applies to even, not the whole andf
  (test? true  (~even&odd 3))
  ; composition mixed with andf: ~atom & (odd . len)
  (test? '(andf ~atom odd:len) (ssexpand '~atom&odd:len))
  (test? true  (~atom&odd:len '(1 2 3)))   ; non-atom of odd length
  (test? false (~atom&odd:len '(1 2)))     ; even length
  (test? false (~atom&odd:len 5))          ; atom
  ; OR with a negated operand, e.g. admin|~editor
  (test? '(orf admin ~editor) (ssexpand 'admin|~editor))
  (withs (admin [is _ 'a] editor [is _ 'e])
    (test? true  (admin|~editor 'a))
    (test? false (admin|~editor 'e))
    (test? true  (admin|~editor 'x)))
  ; precedence between operators: | is outermost, then &, then :
  (test? '(orf a&b c)    (ssexpand 'a&b|c))   ; (a AND b) OR c
  (test? '(orf a b&c)    (ssexpand 'a|b&c))   ; a OR (b AND c)
  (test? '(orf a:b c)    (ssexpand 'a:b|c))   ; (a:b) OR c
  (test? '(compose a b c) (ssexpand 'a:b:c)))

; Keywords: read from a leading OR trailing colon -- foo: and :foo are the
; SAME keyword -- case-insensitive.  A keyword is its own type (key), NOT a
; sym.  Gotcha: a colon *between* names (foo:bar) is compose ssyntax, not a
; keyword.
(define-test keyword
  (test? 'key  (type 'foo:))
  (test? 'key  (type ':foo))
  (test? true  (isa 'foo: 'key))
  (test? false (isa 'foo: 'sym))            ; a keyword is not a sym
  ; leading and trailing colon read to the same keyword; case-insensitive
  (test? true  (is 'foo: ':foo))
  (test? true  (is 'foo: 'FOO:))
  ; coerce both directions; names fold to lowercase as strings/syms
  (test? "foo" (coerce 'foo: 'string))
  (test? 'foo  (coerce 'foo: 'sym))
  (test? true  (is 'foo: (coerce "foo" 'key)))
  (test? true  (is 'foo: (coerce 'foo 'key)))
  (test? true  (is (coerce "FOO" 'key) (coerce "foo" 'key)))
  ; prints as :foo (lowercase, leading colon) and round-trips through read
  (test? ":foo"      (tostring:write 'foo:))
  (test? ":foo"      (tostring:disp 'foo:))
  (test? "(:a :b c)" (tostring:write '(a: b: c)))   ; a plain sym has no colon
  (test? true  (is 'foo: (readstring1 (tostring:write 'foo:))))
  ; a colon *between* names is compose ssyntax, not a keyword
  (test? 'sym               (type 'foo:bar))
  (test? '(compose foo bar) (ssexpand 'foo:bar))
  ; coerce is permissive on names but strict on the target type: the type
  ; you ask for is the type you get, colons and all.  A ':' in the string
  ; never silently promotes a sym to a keyword (you can build odd names --
  ; e.g. for ssyntax -- and they stay whatever type you requested).
  (test? true (isa (coerce ":foo" 'sym) 'sym))    ; NOT a keyword
  (test? true (isa (sym ":foo")        'sym))
  (test? true (isa (coerce ":foo" 'key) 'key))
  (test? true (isa (coerce "foo"  'sym) 'sym))
  (test? true (isa (coerce "foo"  'key) 'key)))

; Syms: case-insensitive, folded to lowercase (the opposite internal case
; from keywords).  t and nil are syms.
(define-test sym
  (test? 'sym  (type 'foo))
  (test? 'sym  (type nil))
  (test? 'sym  (type t))
  (test? true  (isa 'foo 'sym))
  (test? true  (is 'FOO 'foo))              ; case-insensitive
  (test? 'foo  (sym "FOO"))                 ; folded to lowercase
  (test? "foo" (coerce 'foo 'string))
  (test? 'foo  (coerce "foo" 'sym))
  ; (sym "t") is the bindable symbol named t, not the truth value
  (test? 'sym  (type (sym "t"))))

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
  (test? '(1 2 3)   (adjoin 2 '(1 2 3))) ; already present, no dup
  (test? '(9 1 2 3) (adjoin 9 '(1 2 3))) ; absent, prepend
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
    (setmem t 2 s) ; already present, no dup
    (test? '(1 2 3) s))
  ; nil test => rem
  (with (s (list 1 2 3 2))
    (setmem nil 2 s)
    (test? '(1 3) s))
  ; with cmp arg
  (with (s (list 1 2 3 4))
    (setmem nil 2 s >) ; remove elts > 2
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
    (pushnew 2 s) ; present, no change
    (test? '(1 2 3) s)
    (pushnew 9 s) ; absent, prepend
    (test? '(9 1 2 3) s))
  ; with test arg
  (with (s (list 1 2 3))
    (pushnew 9 s >) ; none > 9 => add
    (test? '(9 1 2 3) s)
    (pushnew 0 s >) ; some > 0 => no add
    (test? '(9 1 2 3) s)))

(define-test pull
  (with (s (list 1 2 3 2))
    (pull 2 s)
    (test? '(1 3) s))
  ; with test arg
  (with (s (list 1 2 3 4))
    (pull 2 s >) ; remove elts > 2
    (test? '(1 2) s)))

(define-test togglemem
  (with (s (list 1 2 3))
    (togglemem 9 s) ; absent => add
    (test? '(9 1 2 3) s)
    (togglemem 9 s) ; present => remove
    (test? '(1 2 3) s))
  ; with test arg
  (with (s (list 1 2 3))
    (togglemem 9 s >) ; none > 9 => add
    (test? '(9 1 2 3) s)
    (togglemem 0 s >) ; some > 0 => remove elts > 0
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
  (let v (as!vector '(104 105 106))
    (test? 104 (v 0))
    (test? 106 (v 2))
    (test? 3   (len v))
    (test? 'vector (type v)))
  ; coerce round-trips list <-> byte vector (ints in [0..255])
  (test? '(1 2 255) (as!cons:as!vector '(1 2 255)))
  (test? 0 (len (as!vector nil))) ; empty list -> empty vec
  ; is compares byte vectors elementwise
  (test? t   (is (as!vector '(1 2 3)) (as!vector '(1 2 3))))
  (test? nil (is (as!vector '(1 2 3)) (as!vector '(1 2 4))))
  (test? nil (is (as!vector '(1 2))   (as!vector '(1 2 3)))))

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
      (test? 'same (h k))) ; same object -> found
    (test? nil (h (obj a 1))) ; distinct equal table -> not found
    (test? 1   (len h))))

(define-test isotable
  ; table keys are compared structurally (deep), unlike a regular table
  (let h (isotable)
    (= (h (obj a 1 b 2)) 'foo)
    (test? 'foo (h (obj a 1 b 2))) ; distinct table, same content -> found
    (test? nil  (h (obj a 1))) ; different content -> not found
    (test? 1    (len h)))
  ; vector and cons keys also match by content
  (let h (isotable)
    (= (h (as!vector '(1 2 3))) 'vec
       (h '(9 8))               'lst)
    (test? 'vec (h (as!vector '(1 2 3))))
    (test? 'lst (h (list 9 8)))
    (test? nil  (h (as!vector '(1 2))))
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
  (test? '(206 187)     (as!cons (utf8-encode "λ")))
  (test? "λ"            (utf8-decode (as!vector '(206 187))))
  (test? '(104 195 169) (as!cons (utf8-encode "hé")))
  (test? "héllo"        (utf8-decode (utf8-encode "héllo")))
  ; string->bytes / bytes->string default to utf-8 and take a format
  (test? '(206 187) (as!cons (string->bytes "λ")))
  (test? "λ"        (bytes->string (as!vector '(206 187))))
  (test? '(233)     (as!cons (string->bytes "é" :latin-1))))

(define-test utf8-file
  ; writefile/readfile1 (the profile save path) must round-trip codepoints
  ; >255 now that outfile/infile are utf-8.  U+2019 (the curly ' that
  ; crashed profiles) is utf-8 e2 80 99; also test lambda and a CJK char.
  (let s (+ "I" (utf8-decode (as!vector '(226 128 153))) "m happy λ 日")
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

; ----- strings.arc -----

(define-test tokens
  (test? '("a" "b" "c") (tokens "a b  c")) ; runs of sep collapse
  (test? '("abc")       (tokens "abc"))
  (test? nil            (tokens ""))
  (test? nil            (tokens "  "))
  (test? '("a" "b" "c") (tokens "a,b,,c" #\,))) ; custom separator

(define-test halve
  (test? '("key" ": value") (halve "key: value" #\:)) ; splits on first sep only
  (test? '("a" " b c")      (halve "a b c"))
  (test? '("novalue")       (halve "novalue"))) ; no sep -> single elt

; cut takes a subsequence.  An end past the last element is clamped to the
; length rather than erroring, so callers computing an end by arithmetic --
; paging with (cut items start (+ start perpage*)), where the last page
; overruns -- don't have to bound it themselves.

(define-test cut
  ; the ordinary cases
  (test? "bcde"  (cut "abcde" 1))
  (test? "bcde"  (cut "abcde" 1 nil)) ; an explicit nil end means "the rest"
  (test? "bc"    (cut "abcde" 1 3))
  (test? "abcde" (cut "abcde" 0 5))   ; end at len exactly
  (test? ""      (cut "abcde" 2 2))   ; empty when end is start
  (test? ""      (cut "abcde" 5))     ; start at len is in range, and empty
  ; an end past the end is clamped, not an error
  (test? "bcde"  (cut "abcde" 1 10))
  (test? "abcde" (cut "abcde" 0 1000000000))
  (test? ""      (cut "abcde" 5 10))
  (test? ""      (cut "" 0 5))
  (test? nil     (cut nil 0 5))
  ; ...for any sequence, and the type is still preserved
  (test? '(2 3)   (cut '(1 2 3) 1 99))
  (test? '#(1 2 3) (cut (as!vector '(1 2 3)) 0 99))
  (test? 'string  (type (cut "abcde" 1 10)))
  ; the paging case that motivates the clamp: the last page asks for more
  ; items than are left
  (test? '(c d) (let items '(a b c d) (cut items 2 (+ 2 30))))
  ; only end is clamped.  A start past len, a negative index, or an end
  ; before start are all still errors
  (test? nil (errsafe (cut "abcde" 6 10)))
  (test? nil (errsafe (cut "abcde" 6)))
  (test? nil (errsafe (cut "abcde" 3 1)))
  (test? nil (errsafe (cut "abcde" 1 -1)))
  (test? nil (errsafe (cut "abcde" -1 2)))
  ; cut1, the pure-Arc version cut2 replaced, only needed the clamp on its
  ; string branch: the list branch is firstn, which already stops at the end
  (test? '(2 3 4 5) (cut1 '(1 2 3 4 5) 1 10))
  (test? (cut '(1 2 3 4 5) 1 10) (cut1 '(1 2 3 4 5) 1 10)) ; agrees with cut2
  ; the string branch fills a newstring by indexing seq, so it runs off the
  ; end where cut2 now clamps -- the one case the two still disagree on
  (test? nil    (errsafe (cut1 "abcde" 1 10)))
  (test? "bcde" (cut1 "abcde" 1))
  (test? "bc"   (cut1 "abcde" 1 3))
  ; (vectors are outside cut1 entirely -- nthcdr/firstn don't take them --
  ; so this is unrelated to the bounds)
  (test? nil (errsafe (cut1 (as!vector '(1 2 3)) 0 2)))
  ; almost is cut to (edge xs), so it stays in range
  (test? "abcd" (almost "abcde"))
  (test? '(1 2) (almost '(1 2 3))))

; split and cleave (both from arc.arc, but tested here next to the string
; functions that use them) cut a sequence in two at an index.  Both halves
; are fresh subsequences of the same type as the input.  A non-nil index
; must be a valid one; nil means "no split point" and is handled specially.

(define-test split
  ; keepdelim defaults to t: nothing is dropped, so the halves rejoin
  (test? '("ab" "cde")   (split "abcde" 2))
  (test? "abcde"         (apply + (split "abcde" 2)))
  (test? '("hello" " world") (split "hello world" 5))
  ; keepdelim nil drops the element at pos -- the second half starts at pos+1
  (test? '("ab" "de")        (split "abcde" 2 nil))
  (test? '("hello" "world")  (split "hello world" 5 nil))
  ; the edges: 0 and len both work, yielding one empty half
  (test? '("" "abcde") (split "abcde" 0))
  (test? '("abcde" "") (split "abcde" 5))
  ; ...but pos must index the sequence: len is only in range because the
  ; keepdelim cut is [0,pos)+[pos,len).  Dropping needs a pos+1 that exists.
  (test? nil (errsafe (split "abcde" 5 nil)))
  (test? nil (errsafe (split "abcde" 6)))
  (test? nil (errsafe (split "abcde" -1)))
  ; a nil pos is not an error but a miss -- it's what (pos ...) returns when
  ; it finds nothing -- so the whole seq comes back with an empty remainder
  (test? '("abcde" "") (split "abcde" nil))
  (test? '("abcde" "") (split "abcde" (pos #\: "abcde"))) ; how it arises
  (test? '("" "")      (split "" nil))
  ; the "" filler is only for strings; other sequences get nil
  (test? '("123" "")      (split "123" nil))
  (test? '((1 2 3) ())    (split '(1 2 3) nil))
  (test? '(#(1 2 3) #())  (split (as!vector '(1 2 3)) nil))
  (test? '(nil nil)       (split nil nil))
  ; keepdelim is moot when pos is nil: there is no element to keep or drop
  (test? (split "abcde" nil) (split "abcde" nil nil))
  (test? (split '(1 2 3) nil) (split '(1 2 3) nil nil))
  ; the nil guard has to come first.  Arc's + treats a nil left operand as
  ; the empty list, so the dropping branch's (+ pos 1) would quietly compute
  ; 1 rather than erroring, and split would cut at the wrong place.
  (test? 1 (+ nil 1))
  (test? nil (errsafe (cut "abcde" nil))) ; the keeping branch would error
  ; any sequence, and the halves keep the input's type
  (test? '((1 2) (3 4 5)) (split '(1 2 3 4 5) 2))
  (test? '((1 2) (4 5))   (split '(1 2 3 4 5) 2 nil))
  (test? '(#(1) #(2 3))   (split (as!vector '(1 2 3)) 1))
  (test? 'string (type (car (split "ab" 1))))
  (test? '("" "") (split "" 0))
  (test? '(nil (a b c)) (split '(a b c) 0)) ; an empty list half is nil
  ; the halves are copies, so mutating one leaves the original alone
  (test? "abc" (let s (string "abc")
                 (= ((car (split s 2)) 0) #\z)
                 s))
  (test? '(1 2 3) (let xs (list 1 2 3)
                    (= ((cadr (split xs 1)) 0) 99)
                    xs))
  ; srv.arc harvests fnids by destructuring the two halves
  (test? '((1) (2 3)) (let (kill keep) (split '(1 2 3) 1)
                        (list kill keep))))

; cleave is split with the keepdelim default flipped to nil, so the element
; at i is dropped unless you ask for it.  Everything else, including the nil
; index, is split's behaviour and is tested above.

(define-test cleave
  ; the delimiter at i is dropped by default...
  (test? '("a" "b")   (cleave "a:b" (pos #\: "a:b")))
  (test? '("a" "b:c") (cleave "a:b:c" (pos #\: "a:b:c"))) ; only the first
  ; ...but kept, leading the second half, with keepdelim -- which is
  ; plain split's behaviour (split defaults keepdelim to t)
  (test? '("a" ":b")  (cleave "a:b" (pos #\: "a:b") t))
  (test? (split "a:b" 1) (cleave "a:b" 1 t))
  (test? (split "a:b" 1 nil) (cleave "a:b" 1)) ; the flip, stated directly
  ; a nil index passes straight through to split
  (test? '("abc" "")    (cleave "abc" (pos #\: "abc")))
  (test? '("" "")       (cleave "" (pos #\: "")))
  (test? '("abc" "")    (cleave "abc" nil t)) ; keepdelim is moot here too
  (test? '((1 2 3) nil) (cleave '(1 2 3) nil))
  (test? (split "abc" nil) (cleave "abc" nil))
  ; splitting at the edges
  (test? '("" "bc")  (cleave "abc" 0))   ; leading delimiter -> empty head
  (test? '("" "abc") (cleave "abc" 0 t))
  (test? '("abc" "") (cleave "abc" 3 t)) ; i at the end -> empty tail
  ; i past the last element is only legal with keepdelim; without it
  ; cleave cuts from i+1, which is out of bounds
  (test? nil (errsafe (cleave "abc" 3)))
  ; not string-specific
  (test? '((1) (3))   (cleave '(1 2 3) 1))
  (test? '((1) (2 3)) (cleave '(1 2 3) 1 t)))

(define-test positions
  (test? '(1 3 5) (positions #\a "banana"))
  (test? '(0 2 4) (positions odd '(1 2 3 4 5))) ; predicate form
  (test? nil      (positions #\z "banana")))

(define-test lines
  (test? '("a" "b" "c") (lines "a\nb\nc"))
  (test? '("a" "b" "")  (lines "a\r\nb\r\n")) ; \r stripped, trailing ""
  (test? '("")          (lines "")))

(define-test slices
  (test? '("a" "b" "c") (slices "a-b-c" #\-))
  (test? '("abc")       (slices "abc" #\-)))

(define-test unreserved
  (test? true  (unreserved #\a))
  (test? true  (unreserved #\-))
  (test? false (unreserved #\/)))

(define-test urlencode
  ; ascii unreserved passes through; space and reserved are %-escaped
  (test? "abc-._~"    (urlencode "abc-._~"))
  (test? "a%20b"      (urlencode "a b"))
  (test? "a%2bb"      (urlencode "a+b")) ; literal + -> %2b
  ; non-ascii becomes its utf-8 bytes
  (test? "h%c3%a9llo" (urlencode "héllo"))
  (test? "x%ce%bbx"   (urlencode "xλx"))
  ; urldecode inverts; + and %XX both denote a byte
  (test? "héllo" (urldecode "h%c3%a9llo"))
  (test? "xλx"   (urldecode "x%ce%bbx")) ; the doc example
  (test? "a b"   (urldecode "a+b"))
  (test? "a b"   (urldecode "a%20b"))
  (test? "a+b"   (urldecode "a%2bb"))
  ; round-trips, including multibyte and empty
  (test? "日本語" (urldecode (urlencode "日本語")))
  (test? "" (urlencode ""))
  (test? "" (urldecode "")))

; ----- http-fetch -----
;
; only the cases reachable without a network: the interesting ones
; (stalled peer, a server that never closes) need a listener, and live
; in the manual checks noted in the http-timeouts handoff.

(define-test http-fetch-errors
  ; unsupported scheme
  (test? nil (errsafe (http-fetch "ftp://example.com/")))
  ; connection refused fails fast rather than hanging
  (test? nil (errsafe (http-fetch "http://127.0.0.1:1/"))))

; ----- cookies.arc -----

(def jar-line args
  (apply + (intersperse #\tab args)))

; a fixture jar covering the cases that bite: the #HttpOnly_ prefix, an
; include-subdomains cookie, an expired one, an empty value (trailing
; tab), a real comment, and a malformed line.
(= test-jar*
   (+ "# Netscape HTTP Cookie File\n"
      (jar-line "#HttpOnly_news.ycombinator.com" "FALSE" "/" "TRUE"
                "2147368447" "user" "hnscraper&tok") "\n"
      (jar-line "example.com" "TRUE"  "/a" "FALSE" "0" "sess"  "abc") "\n"
      (jar-line "example.com" "FALSE" "/"  "FALSE" "1" "old"   "gone") "\n"
      (jar-line "example.com" "FALSE" "/"  "FALSE" "0" "empty" "") "\n"
      "# a comment\n"
      "garbage\n"))

(def with-test-jar (f)
  ; write the fixture, run f on its path, always clean up
  (let path "test-cookies.tmp"
    (after (do (dispfile test-jar* path) (f path))
           (rmfile path))))

(define-test url-parts
  (test? '("https" "news.ycombinator.com" "/item?id=1")
         (url-parts "https://news.ycombinator.com/item?id=1"))
  (test? '("http" "example.com" "/")     (url-parts "http://example.com"))
  (test? '("https" "example.com" "/a/b") (url-parts "https://example.com:8443/a/b"))
  (test? nil (url-parts "news.ycombinator.com/x"))) ; no scheme

(define-test read-cookie-jar
  (with-test-jar
    (fn (path)
      (let cs (read-cookie-jar path)
        (test? 4 (len cs))                        ; comment + garbage skipped
        (test? "news.ycombinator.com" ((car cs) 'domain)) ; #HttpOnly_ stripped
        (test? "hnscraper&tok"        ((car cs) 'value))  ; & not decoded
        (test? t                      ((car cs) 'httponly))
        (test? "empty" ((last cs) 'name))
        (test? ""      ((last cs) 'value)))))     ; empty value keeps its column
  (test? nil (read-cookie-jar "no-such-jar.tmp")))

(define-test cookies-for
  (with-test-jar
    (fn (path)
      (let cs (read-cookie-jar path)
        ; longest path first, and the expired cookie is dropped
        (test? '("sess" "empty")
               (map [_ 'name] (cookies-for cs "http://example.com/a/b")))
        (test? nil (cookies-for cs "http://other.org/"))))))

(define-test cookie-header
  (with-test-jar
    (fn (path)
      (let cs (read-cookie-jar path)
        (test? "user=hnscraper&tok"
               (cookie-header cs "https://news.ycombinator.com/item?id=1"))
        ; secure cookies don't go over plain http
        (test? nil (cookie-header cs "http://news.ycombinator.com/x"))
        ; the subdomains flag matches a subdomain; host-only cookies don't
        (test? "sess=abc" (cookie-header cs "http://sub.example.com/a/b"))
        (test? "sess=abc; empty=" (cookie-header cs "http://example.com/a/b"))
        ; /a doesn't match /ab
        (test? "empty=" (cookie-header cs "http://example.com/ab"))))))

; litmatch/endmatch unroll a literal pattern at macroexpansion and hand
; anything else to litmatch2/endmatch2 at runtime, so both paths need
; covering -- and they need to agree.

(define-test litmatch
  (test? true  (litmatch "ab" "abcdef"))
  (test? true  (litmatch "cd" "abcdef" 2)) ; match at offset
  (test? false (litmatch "cd" "abcdef"))
  (test? false (litmatch "xyz" "ab"))      ; pattern longer than string
  (test? true  (litmatch "abcdef" "abcdef")) ; whole string
  (test? true  (litmatch "" "abc"))          ; empty pattern always matches
  (test? true  (litmatch "" "abc" 3))        ; ... even at the end
  (test? false (litmatch "a" "abc" 3))       ; start at end
  (test? false (litmatch "a" "abc" 10)))     ; start past end, no error

(define-test litmatch-runtime
  ; a non-literal pattern can't be unrolled, so it goes to litmatch2
  (let p "cd"
    (test? true  (litmatch p "abcdef" 2))
    (test? false (litmatch p "abcdef")))
  (let p "xyz"
    (test? false (litmatch p "ab")))
  ; litmatch2 is not string-only: `is` compares sequences elementwise
  (test? true  (litmatch '(a b) '(a b c)))
  (test? true  (litmatch2 "" "abc" 3))
  (test? false (litmatch2 "a" "abc" 10))
  ; both paths agree
  (test? (litmatch "cd" "abcdef" 2) (litmatch2 "cd" "abcdef" 2))
  (test? (litmatch "cd" "abcdef")   (litmatch2 "cd" "abcdef")))

(define-test endmatch
  (test? true  (endmatch "def" "abcdef"))
  (test? false (endmatch "abc" "abcdef"))
  (test? true  (endmatch "abcdef" "abcdef"))  ; whole string
  (test? true  (endmatch "" "abc"))           ; empty pattern always matches
  (test? false (endmatch "abcdefg" "abcdef"))) ; pattern longer than string

(define-test endmatch-runtime
  ; the shape real callers use (srv.arc, scrape.arc): literal pattern,
  ; variable string.  dispatches to endmatch2.
  (let s "abc/"
    (test? true  (endmatch "/" s)))
  (let s "abc"
    (test? false (endmatch "/" s)))
  (let s "ab"
    (test? false (endmatch "abcd" s)))       ; pattern longer than string
  (test? true  (endmatch2 "" "abc"))
  (test? true  (endmatch2 "abc" "abc"))
  (test? false (endmatch2 "abcd" "ab"))
  ; both paths agree
  (test? (endmatch "def" "abcdef") (endmatch2 "def" "abcdef"))
  (test? (endmatch "abc" "abcdef") (endmatch2 "abc" "abcdef")))

(define-test posmatch
  (test? 2   (posmatch "cd" "abcdef"))
  (test? nil (posmatch "zz" "abcdef"))
  (test? 2   (posmatch odd '(2 4 5 6)))) ; predicate form

(define-test headmatch
  (test? true  (headmatch "abc" "abcdef"))
  (test? false (headmatch "bcd" "abcdef"))
  (test? true  (headmatch "cd" "abcdef" 2)))

(define-test begins
  (test? true  (begins "abcdef" "abc"))
  (test? false (begins "abcdef" "xyz"))
  (test? true  (begins '(1 2 3 4) '(1 2)))) ; works on lists too

(define-test findsubseq
  (test? 2   (findsubseq "cd" "abcdef"))
  (test? nil (findsubseq "zz" "abcdef")))

(define-test subst
  (test? "aXcXd"   (subst "X" "b" "abcbd"))
  (test? "x--y--z" (subst "--" "ab" "xabyabz"))) ; multi-char old/new

(define-test multisubst
  (test? "121" (multisubst '(("a" "1") ("bb" "2")) "abba")))

(define-test blank
  (test? true   (blank "   "))
  (test? true   (blank ""))
  (test? false  (blank " a "))
  (test? "  x " (nonblank "  x "))
  (test? nil    (nonblank "   ")))

(define-test trim
  (test? "hi"   (trim "  hi  "))
  (test? "hi  " (trim "  hi  " 'front))
  (test? "  hi" (trim "  hi  " 'end))
  (test? "hi"   (trim "xxhixx" 'both [is _ #\x]))) ; custom trim test

(define-test num
  (test? "3.14"      (num 3.14159))
  (test? "3.1416"    (num 3.14159 4)) ; digits arg
  (test? "1,234,567" (num 1234567)) ; thousands commas
  (test? "1,000"     (num 1000 0))
  (test? "-42"       (num -42))
  (test? ".50"       (num 0.5 2 t))) ; trail-zeros

(define-test pluralize
  (test? "cat"    (pluralize 1 "cat"))
  (test? "cats"   (pluralize 2 "cat"))
  (test? "cats"   (pluralize 0 "cat"))
  (test? "1 cat"  (plural 1 "cat"))
  (test? "3 cats" (plural 3 "cat")))

(define-test natsort
  ; digit runs compare by value, not lexically
  (test? '("a1" "a2" "a10")            (natsort '("a10" "a2" "a1")))
  (test? '("img1" "img2" "img10" "img12")
         (natsort '("img12" "img10" "img2" "img1")))
  (test? '("1" "2" "3" "10" "20")      (natsort '("1" "10" "2" "20" "3")))
  ; a prefix (no trailing number) sorts before the numbered variants
  (test? '("file" "file1" "file2" "file10")
         (natsort '("file" "file10" "file2" "file1")))
  ; multiple number fields (version-like)
  (test? '("v1.1" "v1.2" "v1.10" "v2.0")
         (natsort '("v1.2" "v1.10" "v1.1" "v2.0")))
  ; text compares case-insensitively, with a raw-string tiebreak
  (test? '("A" "a" "B" "b")            (natsort '("b" "B" "a" "A")))
  ; equal numeric value, differing zero-padding: deterministic tiebreak
  (test? '("x08" "x8" "x9" "x10")      (natsort '("x10" "x8" "x9" "x08")))
  ; edge cases
  (test? nil       (natsort '()))
  (test? '("only") (natsort '("only")))
  ; the underlying key and comparator
  (test? '("img" 10 "a") (nat-key "Img10a"))
  (test? nil             (nat-key ""))
  (test? true            (nat< "a2" "a10"))
  (test? false           (nat< "a10" "a2")))

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

(define-test literals
  (test? true true)
  (test? false false)
  (test? true (< -inf -1e10))
  (test? false (< inf -1e10))
  (test? false (is nan nan))
  (test? true (anan nan))
  (test? true (anan (- nan)))
  (test? true (anan (* nan 20)))
  (test? -inf (- inf))
  (test? inf (- -inf)))

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
                  (do (= a 20) a)))))

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
  (test? "\"\\u0001\""          (tostring (to-json (string (as!char 1))))))

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

(define-test json-encode-pretty
  ; an empty object stays on one line (nil is always "null", not "[]")
  (test? "{}" (tostring (to-json (table) t)))
  ; default two-space indent
  (test? "[\n  1,\n  2\n]"
         (tostring (to-json '(1 2) t)))
  (test? "{\n  \"a\": 1,\n  \"b\": 2\n}"
         (tostring (to-json (obj b 2 a 1) t)))
  ; nesting indents cumulatively
  (test? "{\n  \"nest\": [\n    1,\n    2\n  ]\n}"
         (tostring (to-json (obj nest '(1 2)) t)))
  ; int gives that many spaces; string is used verbatim
  (test? "[\n    1\n]"   (tostring (to-json '(1) 4)))
  (test? "[\n\t1\n]"     (tostring (to-json '(1) "\t")))
  ; no pretty arg stays compact
  (test? "[1,2]" (tostring (to-json '(1 2)))))

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

(define-test html-escape
  ; eschtml encodes the special chars as named/hex entities
  (test? "&lt;a&gt;"            (eschtml "<a>"))
  (test? "&amp;"               (eschtml "&"))
  (test? "&quot;&#x27;&#x2F;"   (eschtml "\"'/"))
  ; every char eschtml-char escapes round-trips back through uneschtml-char
  (each c '(#\< #\> #\& #\" #\' #\/)
    (let (back end) (uneschtml-char (eschtml-char c) 0)
      (test? c back)
      (test? (len (eschtml-char c)) end)))
  ; uneschtml decodes a whole string (the / case regressed twice before)
  (test? "<a> & \"x\" '/'"
         (uneschtml "&lt;a&gt; &amp; &quot;x&quot; &#x27;&#x2F;&#x27;")))

(define-test markdown-escape
  ; a backslash escapes a following * into a literal asterisk
  (test? "<i>foo</i>"     (markdown "*foo*"))
  (test? "*foo*"          (markdown "\\*foo\\*"))
  (test? "<i>foo*</i>"    (markdown "*foo\\**"))
  (test? "* foo*"         (markdown "\\* foo\\*"))
  ; \\ is a literal backslash, then the next \* escapes the asterisk
  (test? "<i>foo\\*bar</i>" (markdown "*foo\\\\*bar*"))
  ; a backslash before anything but * is just a literal backslash
  (test? "\\baz"          (markdown "\\baz"))
  ; a doubled ** is also a literal asterisk (not empty emphasis),
  ; even inside italics
  (test? "*"              (markdown "**"))
  (test? "a*b"            (markdown "a**b"))
  (test? "*foo*"          (markdown "**foo**"))
  (test? "*foo*"          (markdown "**foo\\*"))
  (test? "<i>foo*</i>"    (markdown "*foo***"))
  (test? "* foo*"         (markdown "** foo**"))
  (test? "<i>foo*bar</i>" (markdown "*foo**bar*")))

(define-test markdown-canonicalize
  ; submitting markdown runs it through markdown then unmarkdown, which
  ; should normalize ** / *** escapes into backslash-escaped asterisks
  (each (in want) '(("*foo*"      "*foo*")
                    ("**foo\\*"   "\\*foo\\*")
                    ("*foo***"    "*foo\\**")
                    ("** foo**"   "\\* foo\\*")
                    ("*foo**bar*" "*foo\\*bar*"))
    (test? want (unmarkdown (markdown in)))))

(define-test markdown-roundtrip
  ; markdown -> unmarkdown should recover the original text, including
  ; slashes, angle brackets, ampersands, and quotes
  (each s (list "path /a/b and it's <fine> & \"ok\""
                "http://x.com/p?q=1&r=2"
                "plain text no specials")
    (test? s (unmarkdown (markdown s))))
  ; re-rendering an unmarkdown'd doc reproduces the same html, so
  ; escaped asterisks survive an edit round-trip
  (each html (list "<i>foo</i>" "*foo*" "<i>foo*</i>" "* foo*")
    (test? html (markdown (unmarkdown html)))))

; ---------------------------------------------------------------------------
; t / nil / symbol identity corner cases.
;
; This project distinguishes two things spelled "t":
;
;   * the TRUTH VALUE t -- what a top-level t, 't, or `t evaluates to.
;   * the bindable SYMBOL named t -- what you get from a t sitting inside
;     quoted list data ((car '(t))) or built at runtime ((sym "t")).  It's
;     an ordinary symbol you can bind as a parameter; it is NOT the truth
;     value -- they are distinct objects.
;
; nil is simpler: nil anywhere is the empty value, EXCEPT (sym "nil") which,
; like (sym "t"), builds a distinct bindable symbol.
;
; Symbols are case-insensitive: 'foo, 'FOO and (sym "FOO") are one symbol, and
; (sym "t") / (sym "T") are the one bindable t-symbol (see arc-str->sym).
;
; Each assertion is its own test so one failure never masks the next.

; one named test asserting a single expected value; keeps the matrix DRY
; without letting an early failure hide later assertions.
(mac test-is (name expected expr)
  `(define-test ,name (test? ,expected ,expr)))

; NOTE: test names avoid differing only by letter case -- since symbol case is
; folded, two names like `write-sym-t` / `write-sym-T` would collapse into one
; and clobber each other.  The upper/lower distinction lives in words, not case.

; --- the TRUTH VALUE t (top-level t / 't / `t) ---
(test-is t-self            true  (is t t))
(test-is t-quote           true  (is t 't))
(test-is quote-t-vs-t      true  (is 't t))
(test-is quote-t-self      true  (is 't 't))
(test-is t-qq              true  (is t `t))
(test-is qq-t-vs-t         true  (is `t t))
(test-is qq-t-quote        true  (is `t 't))
(test-is t-not-string      false (is t "t"))
(test-is no-t              false (no t))
(test-is no-quote-t        false (no 't))
(test-is no-qq-t           false (no `t))
(test-is type-t-is-sym     true  (is (type t) 'sym))
(test-is write-t           "t"   (writes t))

; --- the bindable SYMBOL t (in list data / via sym) is NOT the truth value ---
(test-is t-not-list-t         false (is t (car '(t))))
(test-is t-not-sym-t          false (is t (sym "t")))
(test-is quote-t-not-sym-t    false (is 't (sym "t")))
(test-is list-t-not-t         false (is (car '(t)) t))
(test-is no-list-t            false (no (car '(t)))) ; a symbol, hence truthy
(test-is no-sym-t             false (no (sym "t")))
(test-is type-sym-t-is-sym    true  (is (type (sym "t")) 'sym))

; --- ...but every bindable-symbol path is the SAME symbol (case-insensitive) ---
(test-is list-t-eq-sym-t      true  (is (car '(t)) (sym "t")))
(test-is list-t-eq-qq-t       true  (is (car '(t)) (car `(t))))
(test-is sym-t-self           true  (is (sym "t") (sym "t")))
(test-is sym-lc-t-eq-sym-upcase-t  true  (is (sym "t") (sym "T")))
(test-is list-t-eq-sym-upcase-t    true  (is (car '(t)) (sym "T")))
(test-is t-not-sym-upcase-t   false (is t (sym "T"))) ; still the symbol, not truth
(test-is write-sym-lc-t       "t"   (writes (sym "t")))
(test-is write-sym-upcase-t   "t"   (writes (sym "T")))

; --- unquote injects the VALUE, flipping list-t from symbol to truth value ---
(test-is qq-list-t-symbol     false (is (cadr `(a t)) t)) ; literal t: symbol
(test-is qq-list-unquote-t    true  (is (cadr `(a ,t)) t)) ; ,t: the truth value
(test-is qq-vs-quote-list-t   true  (is (cadr `(a t)) (cadr '(a t)))) ; qq == quote

; --- nil: one value everywhere (only (sym "nil") makes a distinct symbol) ---
(test-is nil-self          true  (is nil nil))
(test-is nil-quote         true  (is nil 'nil))
(test-is nil-qq            true  (is nil `nil))
(test-is nil-empty-list    true  (is nil '()))
(test-is nil-paren         true  (is nil ()))
(test-is nil-in-list       true  (is (car '(nil)) nil)) ; nil in data IS nil (unlike t)
(test-is nil-is-false      true  (is nil false))
(test-is no-nil            true  (no nil))
(test-is no-quote-nil      true  (no 'nil))
(test-is no-empty-list     true  (no '()))
(test-is no-list-nil       true  (no (car '(nil))))
(test-is type-nil-is-sym   true  (is (type nil) 'sym))
(test-is write-nil         "nil" (writes nil))
(test-is nil-eq-quote-upcase-nil true (is nil 'NIL)) ; case-insensitive
(test-is write-quote-upcase-nil  "nil" (writes 'NIL))
; (sym "nil") is a distinct bindable symbol, not the empty value
(test-is nil-not-sym-nil       false (is nil (sym "nil")))
(test-is quote-nil-not-sym-nil false (is 'nil (sym "nil")))
(test-is no-sym-nil            false (no (sym "nil"))) ; a symbol, hence truthy
(test-is nil-not-sym-upcase-nil false (is nil (sym "NIL")))
(test-is sym-nil-eq-sym-upcase-nil true (is (sym "nil") (sym "NIL"))) ; case-insensitive

; --- quasiquote agrees with quote for plain data ---
(test-is qq-nil            true  (is `nil nil))
(test-is qq-list-nil       true  (is `(a nil) '(a nil)))
(test-is qq-unquote-t      true  (is `,t t))

; --- general symbol case: case-insensitive + construction agreement ---
(test-is sym-foo-self         true (is 'foo 'foo))
(test-is sym-foo-agree        true (is 'foo (sym "foo")))
(test-is quote-upcase-foo-agree      true (is 'FOO (sym "FOO")))
(test-is foo-eq-upcase-foo    true (is 'foo 'FOO))
(test-is foo-eq-cap-foo       true (is 'foo 'Foo))
(test-is sym-foo-eq-sym-upcase-foo   true (is (sym "foo") (sym "FOO")))
(test-is quote-foo-eq-sym-upcase-foo true (is 'foo (sym "FOO")))
(test-is write-quote-lc-foo   "foo" (writes 'foo))
(test-is write-quote-upcase-foo      "foo" (writes 'FOO))

; ---------------------------------------------------------------------------
; (eval ...) round-trips: which "t" you feed a binder decides the result.
;
; A bindable t as the parameter name binds like any symbol.  But 't is the
; TRUTH VALUE, so building code with 't puts the truth value where you might
; have wanted the symbol -- illegal as a parameter (compile error), and in
; body position it is just that value, not the binding.  To construct a
; bindable t at runtime, use (sym "t") (the symbol), not 't (the value).

; eval FORM but muffle SBCL's compile-error chatter and turn a failed
; compile/eval into the sentinel 'ERROR, so a mismatch is a value, not noise.

(def mute (thunk)
  #`(cl::let ((cl::*error-output* (cl::make-broadcast-stream)))
      (arc::arc-call0 #,thunk)))

(def eval-quiet (form)
  (on-err (fn (e) 'ERROR) (fn () (mute (fn () (eval form))))))

; sanity: eval of code that doesn't bind t behaves normally
(test-is eval-plain            5    (eval-quiet '(+ 2 3)))
(test-is eval-is-t-quote-t     true (eval-quiet '(is t 't)))
(test-is eval-is-nil-quote-nil true (eval-quiet '(is nil 'nil)))
(test-is eval-quote-t-form     true (is (eval-quiet '(quote t)) t))

; a bindable t as the parameter binds and returns fine, however constructed
(test-is eval-quote-let-t    5  (eval-quiet '(let t 5 t))) ; list-t is bindable
(test-is eval-qq-let-t       5  (eval-quiet `(let t 5 t)))
(test-is eval-list-sym-let-t 5  (eval-quiet (list 'let (sym "t") 5 (sym "t"))))
(test-is eval-with-t         5  (eval-quiet '(with (t 5) t)))
(test-is eval-quote-fn-t     42 (eval-quiet '((fn (t) t) 42)))
(test-is eval-qq-fn-t        42 (eval-quiet `((fn (t) t) 42)))
(test-is eval-list-sym-fn-t  42 (eval-quiet (list (list 'fn (list (sym "t")) (sym "t")) 42)))

; the TRUTH value t ('t) as a parameter name is illegal -> compile error
(test-is eval-list-quote-let-t 'ERROR (eval-quiet (list 'let 't 5 't)))
(test-is eval-qq-unquote-bind  'ERROR (eval-quiet `(let ,'t 5 t)))
(test-is eval-list-fn-t        'ERROR (eval-quiet (list (list 'fn (list 't) 't) 42)))

; the truth value t in the body is that value, not the bound variable
(test-is eval-qq-unquote-body  true (is (eval-quiet `(let t 5 ,'t)) t))
(test-is eval-body-binds       5    (eval-quiet `(let t 5 t))) ; contrast: bindable t

; construction paths agree with each other and with direct evaluation
(test-is eval-quote-eq-direct  true (is (let t 5 t) (eval-quiet '(let t 5 t))))
(test-is eval-quote-eq-qq      true (is (eval-quiet '(let t 5 t))
                                        (eval-quiet `(let t 5 t))))

(when (main)
  (run-tests))
