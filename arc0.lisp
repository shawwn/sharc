;;; arc0.lisp -- Arc runtime for Common Lisp (SBCL)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (load (merge-pathnames "setup.lisp"
                         (or *compile-file-truename*
                             *load-truename*
                             *default-pathname-defaults*))))

(defpackage :arc
  (:use :common-lisp))

(in-package :arc)

;;;; ============================================================
;;;; Utilities
;;;; ============================================================

(defun tnil (x) (if x t nil))

(defun arc-list-p (x) (or (consp x) (null x)))

(defun arc-imap (f l)
  "map over proper or improper list (like Scheme's imap)."
  (cond ((consp l) (cons (funcall f (car l)) (arc-imap f (cdr l))))
        ((null l) nil)
        (t (funcall f l))))

;;;; ============================================================
;;;; Translation from Arc names to CL names and vice-versa
;;;; ============================================================

(defun cl-sym-key (s)
  "Normalize any Arc symbol to an uppercase string key for CL globals."
  (string-upcase (symbol-name s)))

(defun arc-sym-key (s)
  "Normalize any CL symbol to a lowercase string key for Arc globals."
  (string-downcase (symbol-name s)))

(defun cl-sym (name)
  (intern (if (symbolp name) (cl-sym-key name) name) :arc))

(defun arc-sym (name)
  (intern (if (symbolp name) (arc-sym-key name) name) :arc))

(defun arc-sym= (x name)
  "Case-insensitive comparison of symbol X to string NAME."
  (and (symbolp x) (string-equal (symbol-name x) name)))

(defun arc-str->sym (str)
  "String -> Arc symbol, case-folded to lowercase so (sym ...) / coerce agree
with the reader (symbols are case-insensitive here): (sym \"FOO\") is 'foo.
t and nil are NOT canonicalized to the truth/empty values: (sym \"t\") is the
bindable symbol named t, the same object the t inside '(t) is -- distinct from
the truth value t.  See the identity tests in test.arc."
  (intern (string-downcase str) :arc))

;;;; ============================================================
;;;; Global variable table  (key = lowercase string)
;;;;
;;;; Each global lives in a *cell*: a mutable box interned by name in
;;;; *arc-globals*.  Compiled Arc code embeds the cell itself as a
;;;; literal (see ac-var-ref / ac-set1 in arc1.lisp), so reading or
;;;; assigning a global is a struct slot access rather than a hash
;;;; lookup keyed by a freshly consed, downcased copy of the name.
;;;;
;;;; Cells are interned once per name and thereafter mutated in place,
;;;; so bindings made *after* a reference was compiled -- forward
;;;; references, redefinitions, hot reloads -- are seen by code that
;;;; was already compiled against the cell.
;;;; ============================================================

(defvar *arc-unbound* (make-symbol "UNBOUND")
  "Marker held in a cell's value slot while the global is unbound.
A defvar so its identity survives reloading this file.")

(defstruct (gcell (:constructor make-gcell (name &optional (value *arc-unbound*)))
                  (:print-object print-gcell)
                  (:copier nil))
  (name "" :read-only t)
  value)

(defun print-gcell (c stream)
  ;; Deliberately does not print the value: cells appear inside compiled
  ;; code, which is printed in backtraces, and a global's value can be
  ;; arbitrarily large (or circular).
  (format stream "#<gcell ~A>" (gcell-name c)))

(defvar *arc-globals* (make-hash-table :test #'equal)
  "Lowercase name string -> gcell.")

(defvar *arc-globals-lock* (sb-thread:make-mutex :name "arc-globals"))

(defvar *arc-fn-signatures* (make-hash-table :test #'equal :synchronized t))

(defun find-gcell (s)
  "The cell for S, or nil if nothing has ever referenced or bound S."
  (gethash (arc-sym-key s) *arc-globals*))

(defun intern-gcell (s)
  "The cell for S, creating an unbound one if it doesn't exist yet.
Creation is serialized so two threads interning the same name can't end
up holding two different cells for it."
  (let ((key (arc-sym-key s)))
    (or (gethash key *arc-globals*)
        (sb-thread:with-recursive-lock (*arc-globals-lock*)
          (or (gethash key *arc-globals*)
              (setf (gethash key *arc-globals*) (make-gcell key)))))))

(defun gcell-unbound (c)
  (error "Unbound variable: ~A" (gcell-name c)))

;;; Deliberately NOT declaimed inline.  Arc compiles a fresh form for every
;;; top-level expression and every fn body, and this appears once per free
;;; variable reference -- thousands of sites.  Inlining it (even with the
;;; error out of line, as above) grew the IR1 and emitted code enough to
;;; add ~0.7s to a test.arc run, wiping out more than it gained.  An
;;; out-of-line call costs one call per reference at runtime, which is
;;; still far cheaper than the hash lookup this replaced.
(defun gcell-ref (c)
  "Read a cell, erroring if the global is unbound.  This is what compiled
Arc code calls for a free variable reference."
  (let ((v (gcell-value c)))
    (if (eq v *arc-unbound*)
        (gcell-unbound c)
        v)))

(defun arc-global (s)
  "Tolerant lookup: nil when S is unbound.  Used by runtime infrastructure
that legitimately probes for maybe-unset globals."
  (let ((c (find-gcell s)))
    (if c
        (let ((v (gcell-value c)))
          (if (eq v *arc-unbound*) nil v))
        nil)))

(defun (setf arc-global) (val s)
  (setf (gcell-value (intern-gcell s)) val))

(defun arc-bound-p (s)
  (let ((c (find-gcell s)))
    (and c (not (eq (gcell-value c) *arc-unbound*)))))

(defun arc-global-ref (s)
  "Strict lookup by name: errors when S is unbound.  Compiled code goes
straight to gcell-ref; this remains for callers holding only a symbol."
  (let ((c (find-gcell s)))
    (if c
        (gcell-ref c)
        (error "Unbound variable: ~A" s))))

(defun (setf arc-global-ref) (val s)
  (setf (arc-global s) val))

(defun arc-global-name (name)
  (intern (concatenate 'string "arc--" (symbol-name name))))

;;; xdef: define an Arc primitive.
;;; (xdef name value)              - bind name to value
;;; (xdef name (args...) body...)  - defun arc--NAME and bind name to it,
;;;                                  so the function shows up in backtraces.
(defmacro xdef (name x &rest body)
  (if (null body)
      `(setf (arc-global ',name) ,x)
      (let ((f (arc-global-name name)))
        `(progn (defun ,f ,x ,@body)
                (xdef ,name #',f)))))

;;;; ============================================================
;;;; Options
;;;; ============================================================

(defvar *arc-atstrings*     t)
(defvar *arc-explicit-flush* nil)

(sb-int:with-float-traps-masked (:overflow :divide-by-zero :invalid)
  (xdef -inf (/ -1d0 0d0))
  (xdef  inf (/  1d0 0d0))
  (xdef  nan (/  0d0 0d0)))

;; global, for the session
; (sb-int::set-floating-point-modes :traps '(:invalid :divide-by-zero))
; doesn't seem to work

(xdef sig *arc-fn-signatures*)

(defun arc-declare (key &optional (val t))
  (let ((flag (not (null val))))
    (cond ((arc-sym= key "atstrings")      (setf *arc-atstrings*      flag))
          ((arc-sym= key "explicit-flush") (setf *arc-explicit-flush* flag)))))

(xdef declare #'arc-declare)

;;;; ============================================================
;;;; Funcall helpers
;;;; ============================================================

(defun arc-apply (fn &rest args)
  (ar-apply fn (ar-apply-args args)))

(xdef apply #'arc-apply)

(defun ar-apply-args (args)
  (cond
    ((null args) nil)
    ((null (cdr args)) (car args))
    (t (cons (car args) (ar-apply-args (cdr args))))))

(defun ar-apply (fn args)
  (if (functionp fn) (apply fn args)
    (let ((x (apply #'arc-ref fn args)))
      (if (eq x :arc/invalid)
          (error "Function call on non-function: ~S" fn)
          x))))

(defun arc-ref (seq i &optional default)
  (cond
    ((sequencep seq)    (elt seq i))
    ((hash-table-p seq) (let ((v (gethash i seq :arc/missing)))
                          (if (eq v :arc/missing) default v)))
    (t :arc/invalid)))

(defun arc-call0 (fn)
  (if (functionp fn) (funcall fn) (ar-apply fn nil)))

(defun arc-call1 (fn a)
  (if (functionp fn) (funcall fn a) (ar-apply fn (list a))))

(defun arc-call2 (fn a b)
  (if (functionp fn) (funcall fn a b) (ar-apply fn (list a b))))

(defun arc-call3 (fn a b c)
  (if (functionp fn) (funcall fn a b c) (ar-apply fn (list a b c))))

(defun ar-safe-apply (expr fn args)
  (if (or (null fn) (symbolp fn) (numberp fn))
      (error "Function call on non-function: ~S ~S" fn expr)
      (ar-apply fn args)))

(defun arc-safe-apply (expr fn &rest args)
  (ar-safe-apply expr fn (ar-apply-args args)))

;;;; ============================================================
;;;; Core primitives
;;;; ============================================================

;;;; ---- nil / t (bound in globals for completeness) ----

(xdef nil nil)
(xdef t   t)

;;;; ---- join / car / cdr ----

(defun arc-join (&optional (a nil) (b nil))
  (cons a b))

(xdef join #'arc-join)

(defun arc-car (x)
  (cond ((consp x) (car x))
        ((null x)  nil)
        (t (error "Can't take car of ~S" x))))

(xdef car #'arc-car)

(defun arc-cdr (x)
  (cond ((consp x) (cdr x))
        ((null x)  nil)
        (t (error "Can't take cdr of ~S" x))))

(xdef cdr #'arc-cdr)

(defun arc-xcar (x) (if (null x) nil (car x)))
(defun arc-xcdr (x) (if (null x) nil (cdr x)))

;;;; ---- scar / scdr ----

(xdef scar (x val)
  (if (stringp x) (setf (char x 0) val) (setf (car x) val))
  val)

(xdef scdr (x val)
  (if (stringp x) (error "Can't set cdr of string")
      (setf (cdr x) val))
  val)

;;;; ---- len ----

(defun arc-len (x)
  (cond ((stringp x)    (length x))
        ((hash-table-p x) (hash-table-count x))
        (t (length x))))

(xdef len #'arc-len)

;;;; ---- comparison operators ----

(defun pairwise (pred lst)
  (cond ((null lst)       t)
        ((null (cdr lst)) t)
        ((null (funcall pred (car lst) (cadr lst))) nil)
        (t (pairwise pred (cdr lst)))))

;; Returns true iff a and b are identical. 
(defun arc-id (a b)
  (cond ((and (numberp a) (numberp b)) (= a b))
        ((and (stringp a) (stringp b)) (string= a b))
        (t (or (eql a b) (and (null a) (null b))))))

(xdef id #'arc-id)

(defun arc-is2 (a b)
   (or (arc-id a b)
       (cond
         ;; lists
         ((and (consp a) (consp b))
          (and (arc-is2 (car a) (car b))
               (arc-is2 (cdr a) (cdr b))))
         ;; vectors (skip strings — arc-id already handled them)
         ((and (vectorp a) (vectorp b)
               (not (stringp a)) (not (stringp b)))
          (and (= (length a) (length b))
               (loop for i below (length a)
                     always (arc-is2 (aref a i) (aref b i)))))
         ;; tables
         ((and (hash-table-p a) (hash-table-p b))
          (and (eq (hash-table-test a) (hash-table-test b))
               (= (hash-table-count a) (hash-table-count b))
               (loop for k being the hash-keys of a using (hash-value va)
                     always (multiple-value-bind (vb present) (gethash k b)
                              (and present (arc-is2 va vb)))))))))

(defun arc-is (a b &rest args)
  (and (arc-is2 a b)
       (or (null args)
           (apply #'arc-is b args))))

(xdef is #'arc-is)

(defun arc->2 (x y)
  (tnil (cond ((and (numberp x) (numberp y)) (> x y))
              ((and (stringp x) (stringp y)) (string> x y))
              ((and (symbolp x) (symbolp y))
               (string> (symbol-name x) (symbol-name y)))
              ((and (characterp x) (characterp y)) (char> x y))
              (t (> x y)))))

(xdef > (x y &rest args)
  (if args
      (and (arc->2 x y)
           (arc->2 y (car args))
           (pairwise #'arc->2 args))
      (arc->2 x y)))

(defun arc-<2 (x y)
  (tnil (cond ((and (numberp x) (numberp y)) (< x y))
              ((and (stringp x) (stringp y)) (string< x y))
              ((and (symbolp x) (symbolp y))
               (string< (symbol-name x) (symbol-name y)))
              ((and (characterp x) (characterp y)) (char< x y))
              (t (< x y)))))

(xdef < (x y &rest args)
  (if args
      (and (arc-<2 x y)
           (arc-<2 y (car args))
           (pairwise #'arc-<2 args))
      (arc-<2 x y)))

;;;; ---- math operators ----

(defun char-or-str-p (x) (or (stringp x) (characterp x)))

(defun arc-+2 (x y)
  (cond ((and (numberp x) (numberp y)) (+ x y))
        ((char-or-str-p x)
         (concatenate 'string
                      (if (characterp x) (string x) x)
                      (if (characterp y) (string y) y)))
        ((and (arc-list-p x) (arc-list-p y)) (append x y))
        (t (+ x y))))

(defun arc-+ (&rest args)
  (cond
    ((null args) 0)
    ((char-or-str-p (car args))
     (apply #'concatenate 'string
            (mapcar (lambda (a)
                      (cond ((stringp a) a)
                            ((characterp a) (string a))
                            ((null a) "")
                            (t (format nil "~A" a))))
                    args)))
    ((arc-list-p (car args)) (apply #'append args))
    (t (apply #'+ args))))

(xdef + #'arc-+)

(xdef - #'-)
(xdef * #'*)
(xdef / #'/)
(xdef mod #'mod)
(xdef expt #'expt)
(xdef sqrt #'sqrt)

;;;; ---- Continuations (escape-only) ----

(defun arc-ccc (f)
  (let ((tag (gensym "K")))
    (catch tag
      (arc-call1 f (lambda (x) (throw tag x))))))

(xdef ccc #'arc-ccc)

;;;; ============================================================
;;;; Higher-level utilities
;;;; ============================================================

(defun arc-car? (l &optional (k :arc/unset) &key (test #'arc-id))
  (and (consp l)
       (if (eq k :arc/unset) (car l)
         (if (functionp k) (funcall k (car l))
           (test (car l) k)))))

(defun arc-caar? (l &optional (k :arc/unset) &key (test #'arc-id))
  (arc-car? (arc-car? l) k :test test))

;;;; ============================================================
;;;; Tagged types
;;;; ============================================================

(defstruct (arc-tagged (:constructor %arc-tag (type rep)))
  type rep)

;;;; ---- Type system ----

(defun arc-type (x)
  (cond
    ((arc-tagged-p x) (arc-tagged-type x))
    ((consp x)        (arc-sym "cons"))
    ((keywordp x)     (arc-sym "key"))
    ((null x)         (arc-sym "sym"))
    ((symbolp x)      (arc-sym "sym"))
    ((functionp x)    (arc-sym "fn"))
    ((characterp x)   (arc-sym "char"))
    ((stringp x)      (arc-sym "string"))
    ((exactp x)       (arc-sym "int"))
    ((numberp x)      (arc-sym "num"))
    ((hash-table-p x) (arc-sym "table"))
    ((outstreamp x)   (arc-sym "output"))
    ((instreamp x)    (arc-sym "input"))
    ((threadp x)      (arc-sym "thread"))
    ((vectorp x)      (arc-sym "vector"))
    (t (error "Unknown type: ~S" x))))

(defun exactp (x)
  (and (integerp x) (= x (truncate x))))

(defun outstreamp (x)
  (and (streamp x) (output-stream-p x)))

(defun instreamp (x)
  (and (streamp x) (input-stream-p x)))

(defun threadp (x)
  (typep x 'sb-thread:thread))

(defun sequencep (x)
  (typep x 'sequence))

(defun arc-tag (type rep)
  (if (and (arc-tagged-p rep)
           (arc-sym= (arc-tagged-type rep) (symbol-name type)))
      rep
      (%arc-tag type rep)))

(defun arc-rep (x)
  (if (arc-tagged-p x) (arc-tagged-rep x) x))

(xdef annotate #'arc-tag)
(xdef type     #'arc-type)
(xdef rep      #'arc-rep)

;;;; ============================================================
;;;; I/O
;;;; ============================================================

(xdef infile (f)
  (open f :direction :input
          :element-type :default
          ;; replacement so a stray pre-utf-8 (latin-1) byte in old data
          ;; degrades to #\? instead of crashing the load.
          :external-format '(:utf-8 :replacement #\?)))

(xdef outfile (f &rest args)
  (open f :direction :output
          :element-type :default
          :external-format :utf-8
          :if-exists (if (equal (car args) "append") :append :supersede)
          :if-does-not-exist :create))

;; infile-binary and outfile-binary variants aren't needed.
;; :element-type :default lets readc/writec work with UTF-8 and
;; readb/writeb work with bytes.

(xdef instring  #'make-string-input-stream)
(xdef outstring () (make-string-output-stream))
(xdef inside    #'get-output-stream-string)

(xdef stdout () *standard-output*)
(xdef stdin  () *standard-input*)
(xdef stderr () *error-output*)

(xdef call-w/stdout (port thunk)
  (let ((*standard-output* port)) (arc-call0 thunk)))
(xdef call-w/stdin (port thunk)
  (let ((*standard-input* port)) (arc-call0 thunk)))

(xdef readc (&rest args)
  (let ((c (read-char (if args (car args) *standard-input*) nil nil)))
    (or c nil)))

(xdef readb (&rest args)
  (let ((b (read-byte (if args (car args) *standard-input*) nil nil)))
    (or b nil)))

(xdef peekc (&rest args)
  (let ((c (peek-char nil (if args (car args) *standard-input*) nil nil)))
    (or c nil)))

(xdef writec (c &rest args)
  (write-char c (if args (car args) *standard-output*))
  c)

(xdef writeb (b &rest args)
  (write-byte b (if args (car args) *standard-output*))
  b)

(defun print-level-exceeded-p (depth)
  "True when a nested object at DEPTH should print as # per *print-level*."
  (and *print-level* (>= depth *print-level*)))

(defun write-remaining-level (x port depth)
  "Fall back to CL's printer, charging DEPTH against *print-level*."
  (let ((*print-level* (and *print-level* (max 0 (- *print-level* depth)))))
    (write x :stream port :readably nil)))

(defun arc-print-list (x port depth printer)
  "Print list X as (elem elem ...) using PRINTER, honouring *print-length*."
  (write-char #\( port)
  (let ((rest x) (n 0))
    (loop while rest do
      (cond
        ((and *print-length* (>= n *print-length*))
         ;; Out of budget: a dotted atom tail is still printed in full
         ;; (CL prints (1 . 2) even with *print-length* 1), but any
         ;; remaining elements collapse to "...".
         (cond ((consp rest)
                (when (plusp n) (write-char #\space port))
                (write-string "..." port))
               (t
                (write-string " . " port)
                (funcall printer rest port (1+ depth))))
         (setf rest nil))
        ((consp rest)
         (when (plusp n) (write-char #\space port))
         (funcall printer (car rest) port (1+ depth))
         (incf n)
         (setf rest (cdr rest)))
        (t
         (write-string " . " port)
         (funcall printer rest port (1+ depth))
         (setf rest nil)))))
  (write-char #\) port))

(defun arc-disp-val (x port &optional (depth 0))
  (cond
    ((stringp x)    (write-string x port))
    ((characterp x) (write-char x port))
    ((null x)       nil)
    ((keywordp x)   (write-char #\: port)
                    (write-string (string-downcase (symbol-name x)) port))
    ((symbolp x)    (write-string (symbol-name x) port))
    ((typep x 'double-float) (format port "~F" x))
    ((consp x)
     (if (print-level-exceeded-p depth)
         (write-char #\# port)
         (arc-print-list x port depth 'arc-disp-val)))
    (t (write-remaining-level x port depth))))

(defun arc-write-val (x port &optional (depth 0))
  (cond
    ((stringp x)    (write x :stream port))  ; quoted
    ((characterp x) (write x :stream port))
    ((null x)       (write-string "nil" port))
    ((eq x t)       (write-string "t" port))
    ((keywordp x)   (write-char #\: port)
                    (write-string (string-downcase (symbol-name x)) port))
    ((symbolp x)    (write-string (symbol-name x) port))
    ((consp x)
     (if (print-level-exceeded-p depth)
         (write-char #\# port)
         (arc-print-list x port depth 'arc-write-val)))
    (t (write-remaining-level x port depth))))

(xdef disp (&rest args)
  (let ((port (if (cdr args) (cadr args) *standard-output*)))
    (when args (arc-disp-val (car args) port))
    (unless *arc-explicit-flush* (force-output port)))
  nil)

(xdef write (&rest args)
  (let ((port (if (cdr args) (cadr args) *standard-output*)))
    (when args (arc-write-val (car args) port))
    (unless *arc-explicit-flush* (force-output port)))
  nil)

(xdef sread (p eof)
  (arc-read p nil eof))

;;;; ---- coerce ----

(defun parse-num (s)
  (with-standard-io-syntax
    (let ((*read-eval* nil))
      (ignore-errors
        (let ((n (read-from-string s)))
          (if (numberp n) n nil))))))

(defun arc-typename (type)
  (string-downcase
    (if (symbolp type) (symbol-name type) (string type))))

(defun arc-coerce (x type &optional radix)
  (let ((tname (arc-typename type)))
    (cond
      ((arc-tagged-p x) (error "Can't coerce annotated object"))
      ((string= tname (arc-typename (arc-type x))) x)
      ((keywordp x)
       ;; keyword names are upcased by the reader; fold back to lowercase
       ;; so key->string/sym round-trips with how it was written.
       (cond ((string= tname "string") (string-downcase (symbol-name x)))
             ((string= tname "sym")    (arc-str->sym (symbol-name x)))
             (t (error "Can't coerce keyword ~S to ~S" x type))))
      ((characterp x)
       (cond ((string= tname "int")    (char-code x))
             ((string= tname "string") (string x))
             ((string= tname "sym")    (arc-str->sym (string x)))
             (t (error "Can't coerce char ~S to ~S" x type))))
      ((and (integerp x) (= x (truncate x)))
       (cond ((string= tname "num")    x)
             ((string= tname "char")   (code-char x))
             ((string= tname "string")
              (if radix
                  (string-downcase (format nil (format nil "~~~DR" radix) x))
                  (format nil "~D" x)))
             (t (error "Can't coerce int ~S to ~S" x type))))
      ((numberp x)
       (cond ((string= tname "int")    (round x))
             ((string= tname "char")   (code-char (round x)))
             ((string= tname "string") (format nil "~A" x))
             (t (error "Can't coerce num ~S to ~S" x type))))
      ((stringp x)
       (cond ((string= tname "sym")    (arc-str->sym x))
             ((string= tname "key")    (intern (string-upcase x) :keyword))
             ((string= tname "cons")   (coerce x 'list))
             ((string= tname "char")
              (if (= (length x) 1)
                  (char x 0)
                  (error "Can't coerce string ~S to char" x)))
             ((string= tname "num")
              (or (parse-num x) (error "Can't coerce string ~S to num" x)))
             ((string= tname "int")
              (if radix
                  (or (ignore-errors (parse-integer x :radix radix))
                      (error "Can't coerce string ~S to int" x))
                  (let ((n (parse-num x)))
                    (if n (round n) (error "Can't coerce string ~S to int" x)))))
             (t (error "Can't coerce string ~S to ~S" x type))))
      ((consp x)
       (cond ((string= tname "string")
              (apply #'concatenate 'string
                     (mapcar (lambda (c)
                               (if (characterp c) (string c) (format nil "~A" c)))
                             x)))
             ;; a list of byte ints -> a byte vector (inverse of the
             ;; vector->cons case below)
             ((string= tname "vector")
              (make-array (length x) :element-type '(unsigned-byte 8)
                                     :initial-contents x))
             (t (error "Can't coerce cons to ~S" type))))
      ((null x)
       (cond ((string= tname "string") "")
             ((string= tname "vector")
              (make-array 0 :element-type '(unsigned-byte 8)))
             (t (error "Can't coerce nil to ~S" type))))
      ((symbolp x)
       (cond ((string= tname "string") (symbol-name x))
             ((string= tname "key")    (intern (string-upcase (symbol-name x)) :keyword))
             (t (error "Can't coerce sym ~S to ~S" x type))))
      ;; a non-string vector (e.g. a byte vector) -> its elements as a
      ;; list; for a byte vector that's a list of ints in [0..255]
      ((vectorp x)
       (cond ((string= tname "cons") (coerce x 'list))
             (t (error "Can't coerce vector ~S to ~S" x type))))
      ((functionp x)
       (error "Can't coerce function ~S to ~S" x type))
      (t x))))

(xdef coerce (x type &rest args) (arc-coerce x type (car args)))

;;;; ---- utf-8/latin-1 conversion ----

(defun arc-string->bytes (s &optional (ef :utf-8))
  (sb-ext:string-to-octets s :external-format ef))

(xdef string->bytes #'arc-string->bytes)

(defun arc-bytes->string (b &optional (ef :utf-8))
  (sb-ext::octets-to-string b :external-format ef))

(xdef bytes->string #'arc-bytes->string)

;; Convert between a string and its UTF-8 byte vector.  Useful where a
;; protocol is defined over bytes rather than characters (urlencode,
;; Content-Length, etc.).
(xdef utf8-encode (s) (sb-ext:string-to-octets s :external-format :utf-8))
(xdef utf8-decode (b) (sb-ext:octets-to-string b :external-format :utf-8))

;;;; ============================================================
;;;; Networking  (sb-bsd-sockets)
;;;; ============================================================

(defclass arc-server-socket ()
  ((sock :initarg :sock :reader ass-sock)))

;;; Gray stream wrapper with byte limit
(defclass arc-limited-stream (sb-gray:fundamental-character-input-stream)
  ((source :initarg :source :reader als-src)
   (limit  :initarg :limit  :reader als-limit)
   (count  :initform 0 :accessor als-count)))

(defmethod sb-gray:stream-read-char ((s arc-limited-stream))
  (if (>= (als-count s) (als-limit s))
      :eof
      (let ((c (read-char (als-src s) nil :eof)))
        (when (characterp c) (incf (als-count s)))
        c)))

(defmethod sb-gray:stream-unread-char ((s arc-limited-stream) c)
  (unread-char c (als-src s))
  (when (> (als-count s) 0) (decf (als-count s))))

(defmethod sb-gray:stream-peek-char ((s arc-limited-stream))
  (if (>= (als-count s) (als-limit s))
      :eof
      (peek-char nil (als-src s) nil :eof)))

(defmethod sb-gray:stream-line-column ((s arc-limited-stream)) nil)

(defmethod cl:close ((s arc-limited-stream) &key abort)
  (close (als-src s) :abort abort))

(defun arc-open-socket (port)
  (let ((s (make-instance 'sb-bsd-sockets:inet-socket
                          :type :stream :protocol :tcp)))
    (setf (sb-bsd-sockets:sockopt-reuse-address s) t)
    (sb-bsd-sockets:socket-bind s #(0 0 0 0) port)
    (sb-bsd-sockets:socket-listen s 50)
    (make-instance 'arc-server-socket :sock s)))

(defun arc-socket-accept (arc-sock)
  ;; socket-accept returns (client-socket ip-vec port)
  (multiple-value-bind (client ipv _port)
      (sb-bsd-sockets:socket-accept (ass-sock arc-sock))
    (declare (ignore _port))
    (let* ((ip  (format nil "~D.~D.~D.~D"
                        (aref ipv 0) (aref ipv 1)
                        (aref ipv 2) (aref ipv 3)))
           ;; :default element-type keeps the stream bivalent, so binary
           ;; output (writeb, e.g. images) still writes raw octets and
           ;; ignores this external-format; utf-8 governs char i/o only.
           ;; :replacement so a malformed request byte degrades to #\?
           ;; instead of signalling mid-request.
           (stream (sb-bsd-sockets:socket-make-stream
                    client :input t :output t
                    :element-type :default
                    :external-format '(:utf-8 :replacement #\?)
                    :buffering :full))
           (lim (make-instance 'arc-limited-stream
                               :source stream :limit 2000000)))
      (list lim stream ip))))

(xdef open-socket  #'arc-open-socket)
(xdef socket-accept #'arc-socket-accept)

(xdef setuid (uid)
  (handler-case
      (sb-alien:alien-funcall
       (sb-alien:extern-alien
        "setuid"
        (function sb-alien:int sb-alien:unsigned))
       uid)
    (error () nil))
  nil)

(xdef client-ip (port) (declare (ignore port)) "unknown")

;;;; ============================================================
;;;; HTTP client  (sb-alien + OpenSSL)
;;;; ============================================================
;;;
;;; Arc API:
;;;
;;;   (socket-connect host port [opts])
;;;     Open a TCP connection, return a bidirectional stream.
;;;     SSL is auto-enabled for port 443.
;;;     Works with readc, writec, disp, write, close, flushout.
;;;     opts is an optional table:
;;;       ssl      -- force SSL on any port
;;;       noverify -- skip certificate verification
;;;       timeout  -- seconds a read may stall before erroring.
;;;                   No default here, unlike http-fetch: this is a
;;;                   general primitive and SMTP (email.arc) uses it.
;;;
;;;   (http-fetch url [opts])
;;;     HTTP request; returns the response body as a string.
;;;     Signals an error on non-2xx status.
;;;     opts is an optional table:
;;;       method   -- HTTP method (default "GET")
;;;       headers  -- alist of ("Header-Name" "value") pairs
;;;       body     -- request body string
;;;       noverify -- skip certificate verification
;;;       timeout  -- seconds a single read may stall (default
;;;                   *http-timeout*, 60; 0 means block forever)
;;;       maxtime  -- seconds for the whole request
;;;
;;;   (http-response url [opts])
;;;     Same request, but returns a table of status / headers / body and
;;;     does NOT signal on non-2xx -- 3xx replies carry headers worth
;;;     reading, e.g. the Set-Cookie on a login redirect.  headers is an
;;;     alist of (name value) with duplicates kept.
;;;

;;;   (flushout [stream])
;;;     Flush a stream (defaults to stdout).
;;;
;;; SSL requires OpenSSL installed on the system. On macOS, Homebrew's
;;; OpenSSL is loaded from /opt/homebrew/lib or /usr/local/lib.
;;; If OpenSSL is not found, *ssl-available* is nil and http/https
;;; requests to SSL hosts signal an error; startup is not affected.

(defvar *ssl-available* nil)

(defvar *libssl* nil)
(defvar *libcrypto* nil)

(defun try-load-ssl ()
  "Try to load OpenSSL shared libraries. Sets *ssl-available* on success.
   On macOS, only tries explicit Homebrew paths to avoid Apple's restricted
   system libcrypto which causes a fatal SIGABRT."
  (flet ((try-load (paths)
           (dolist (p paths)
             (when (or (not (find #\/ p))         ; bare name (linux/win)
                       (probe-file p))            ; full path must exist
               (ignore-errors
                 (sb-alien:load-shared-object p)
                 (return-from try-load p))))))
    (handler-case
        (let ((crypto (try-load #+darwin '("/opt/homebrew/lib/libcrypto.dylib"
                                           "/usr/local/lib/libcrypto.dylib")
                                #+linux '("libcrypto.so" "libcrypto.so.3"
                                          "libcrypto.so.1.1")
                                #+win32 '("libcrypto-3-x64.dll"
                                          "libcrypto-1_1-x64.dll")
                                #-(or darwin linux win32) '("libcrypto.so")))
              (ssl    (try-load #+darwin '("/opt/homebrew/lib/libssl.dylib"
                                           "/usr/local/lib/libssl.dylib")
                                #+linux '("libssl.so" "libssl.so.3"
                                          "libssl.so.1.1")
                                #+win32 '("libssl-3-x64.dll"
                                          "libssl-1_1-x64.dll")
                                #-(or darwin linux win32) '("libssl.so"))))
          (when (and crypto ssl)
            (setf *libcrypto* crypto *libssl* ssl *ssl-available* t)))
      (error () nil))))

(try-load-ssl)

(when *ssl-available*
  ;; Only define FFI bindings when the libraries loaded successfully.
  (sb-alien:define-alien-routine "TLS_client_method" (* t))
  (sb-alien:define-alien-routine "SSL_CTX_new" (* t) (method (* t)))
  (sb-alien:define-alien-routine "SSL_CTX_free" sb-alien:void (ctx (* t)))
  (sb-alien:define-alien-routine "SSL_new" (* t) (ctx (* t)))
  (sb-alien:define-alien-routine "SSL_free" sb-alien:void (ssl (* t)))
  (sb-alien:define-alien-routine "SSL_set_fd" sb-alien:int
    (ssl (* t)) (fd sb-alien:int))
  (sb-alien:define-alien-routine "SSL_connect" sb-alien:int (ssl (* t)))
  (sb-alien:define-alien-routine "SSL_read" sb-alien:int
    (ssl (* t)) (buf (* t)) (num sb-alien:int))
  (sb-alien:define-alien-routine "SSL_write" sb-alien:int
    (ssl (* t)) (buf (* t)) (num sb-alien:int))
  (sb-alien:define-alien-routine "SSL_shutdown" sb-alien:int (ssl (* t)))
  (sb-alien:define-alien-routine "SSL_ctrl" sb-alien:long
    (ssl (* t)) (cmd sb-alien:int) (larg sb-alien:long) (parg (* t)))
  (sb-alien:define-alien-routine "SSL_get_error" sb-alien:int
    (ssl (* t)) (ret sb-alien:int))
  ;; Certificate verification
  (sb-alien:define-alien-routine "SSL_CTX_set_default_verify_paths" sb-alien:int
    (ctx (* t)))
  (sb-alien:define-alien-routine "SSL_CTX_set_verify" sb-alien:void
    (ctx (* t)) (mode sb-alien:int) (callback (* t)))
  (sb-alien:define-alien-routine "SSL_set1_host" sb-alien:int
    (ssl (* t)) (hostname sb-alien:c-string))
  (sb-alien:define-alien-routine "SSL_get_verify_result" sb-alien:long
    (ssl (* t)))
  (sb-alien:define-alien-routine "X509_verify_cert_error_string" sb-alien:c-string
    (n sb-alien:long))
  ;; Error reporting
  (sb-alien:define-alien-routine "ERR_get_error" sb-alien:unsigned-long)
  (sb-alien:define-alien-routine "ERR_error_string" sb-alien:c-string
    (e sb-alien:unsigned-long) (buf (* t)))
  (sb-alien:define-alien-routine "ERR_clear_error" sb-alien:void))

(defun ssl-error-string ()
  "Return the earliest queued OpenSSL error as a human-readable string,
   or nil if the error queue is empty."
  (let ((code (err-get-error)))
    (when (plusp code)
      (err-error-string code (sb-alien:sap-alien (sb-sys:int-sap 0) (* t))))))

(defun ssl-set-tlsext-host-name (ssl hostname)
  "Set SNI hostname on an SSL connection (required by most servers)."
  ;; SSL_CTRL_SET_TLSEXT_HOSTNAME = 55, TLSEXT_NAMETYPE_host_name = 0
  (sb-sys:with-pinned-objects (hostname)
    (let ((buf (sb-ext:string-to-octets hostname :external-format :ascii)))
      (sb-sys:with-pinned-objects (buf)
        (ssl-ctrl ssl 55 0 (sb-sys:vector-sap buf))))))

;;; Gray stream that wraps an SSL connection for transparent I/O.
;;; Supports character read/write so Arc's readc/writec/disp/write
;;; work directly on SSL-connected streams.

(defclass arc-ssl-stream (sb-gray:fundamental-character-input-stream
                          sb-gray:fundamental-character-output-stream)
  ((ssl-ptr  :initarg :ssl  :reader ssl-stream-ssl)
   (ctx-ptr  :initarg :ctx  :reader ssl-stream-ctx)
   (sock     :initarg :sock :reader ssl-stream-sock)
   ;; Read buffering: SSL_read returns bytes, we decode to characters.
   (read-buf :initform "" :accessor ssl-stream-read-buf)
   (read-pos :initform 0  :accessor ssl-stream-read-pos)
   ;; Write buffering: accumulate characters, flush as bytes.
   (write-buf :initform (make-array 1024 :element-type '(unsigned-byte 8)
                                         :adjustable t :fill-pointer 0)
              :accessor ssl-stream-write-buf)))

(defmethod sb-gray:stream-read-char ((s arc-ssl-stream))
  (when (>= (ssl-stream-read-pos s) (length (ssl-stream-read-buf s)))
    ;; Refill from SSL_read
    (let ((buf (make-array 8192 :element-type '(unsigned-byte 8))))
      (sb-sys:with-pinned-objects (buf)
        (let ((n (ssl-read (ssl-stream-ssl s) (sb-sys:vector-sap buf) 8192)))
          (if (<= n 0)
              (progn
                ;; A -1 with SSL_ERROR_SYSCALL (5) is a failed read(2) --
                ;; a fired SO_RCVTIMEO, if one was set.  Reporting that as
                ;; :eof would truncate the stream silently, so say so.
                (when (and (minusp n) (= (ssl-get-error (ssl-stream-ssl s) n) 5))
                  (error "ssl read timed out"))
                (setf (ssl-stream-read-buf s) ""
                      (ssl-stream-read-pos s) 0)
                (return-from sb-gray:stream-read-char :eof))
              (setf (ssl-stream-read-buf s)
                    (sb-ext:octets-to-string (subseq buf 0 n)
                                             :external-format :utf-8)
                    (ssl-stream-read-pos s) 0))))))
  (prog1 (char (ssl-stream-read-buf s) (ssl-stream-read-pos s))
    (incf (ssl-stream-read-pos s))))

(defmethod sb-gray:stream-unread-char ((s arc-ssl-stream) c)
  (declare (ignore c))
  (when (> (ssl-stream-read-pos s) 0)
    (decf (ssl-stream-read-pos s))))

(defmethod sb-gray:stream-read-char-no-hang ((s arc-ssl-stream))
  (sb-gray:stream-read-char s))

(defmethod sb-gray:stream-write-char ((s arc-ssl-stream) c)
  (let ((bytes (sb-ext:string-to-octets (string c) :external-format :utf-8)))
    (loop for b across bytes
          do (vector-push-extend b (ssl-stream-write-buf s))))
  c)

(defmethod sb-gray:stream-write-string ((s arc-ssl-stream) string &optional start end)
  (let ((bytes (sb-ext:string-to-octets (subseq string (or start 0) end)
                                        :external-format :utf-8)))
    (loop for b across bytes
          do (vector-push-extend b (ssl-stream-write-buf s)))))

(defmethod sb-gray:stream-force-output ((s arc-ssl-stream))
  (let ((buf (ssl-stream-write-buf s)))
    (when (> (length buf) 0)
      (let ((arr (make-array (length buf) :element-type '(unsigned-byte 8)
                                          :initial-contents buf)))
        (sb-sys:with-pinned-objects (arr)
          (ssl-write (ssl-stream-ssl s) (sb-sys:vector-sap arr) (length arr))))
      (setf (fill-pointer buf) 0))))

(defmethod sb-gray:stream-finish-output ((s arc-ssl-stream))
  (sb-gray:stream-force-output s))

(defmethod sb-gray:stream-line-column ((s arc-ssl-stream)) nil)

(defmethod cl:close ((s arc-ssl-stream) &key abort)
  (declare (ignore abort))
  (sb-gray:stream-force-output s)
  (ignore-errors (ssl-shutdown (ssl-stream-ssl s)))
  (ssl-free (ssl-stream-ssl s))
  (ssl-ctx-free (ssl-stream-ctx s))
  (sb-bsd-sockets:socket-close (ssl-stream-sock s)))

;;; ---- Socket read timeouts ----
;;;
;;; Without these, a peer that accepts a connection and then goes quiet
;;; blocks the reading thread forever: there is no other timeout in this
;;; path, and TCP keepalive is off by default.
;;;
;;; Two mechanisms, because neither covers both stream types:
;;;
;;;   SO_RCVTIMEO works for SSL, where ssl-read calls read(2) directly
;;;   and we see the -1 ourselves.  It does NOT work for plain sockets:
;;;   SBCL's fd-stream treats the resulting EAGAIN as "would block" and
;;;   waits on the fd anyway, so read-byte still hangs indefinitely
;;;   (measured).  sb-bsd-sockets doesn't expose the option, so it goes
;;;   through setsockopt directly.
;;;
;;;   wait-until-fd-usable gates every read on both stream types and is
;;;   what actually bounds the plain-socket path.

(sb-alien:define-alien-routine ("setsockopt" %setsockopt) sb-alien:int
  (fd sb-alien:int) (level sb-alien:int) (optname sb-alien:int)
  (optval (* t)) (optlen sb-alien:int))

(defconstant +sol-socket+  #+darwin #xffff #-darwin 1)
(defconstant +so-rcvtimeo+ #+darwin #x1006 #-darwin 20)
(defconstant +so-sndtimeo+ #+darwin #x1005 #-darwin 21)

(defvar *http-timeout* 60
  "Default timeout in seconds for socket-connect and http-fetch: how long
   a single read may go without progress.  nil or 0 means block forever
   (the old behavior).  Override per call with the `timeout' option.
   Note this bounds reads, not connect(2), which is left to the OS's own
   SYN-retry limit (~75s on darwin, ~2min on linux).")

(defun set-socket-timeout (fd seconds)
  "Set SO_RCVTIMEO / SO_SNDTIMEO on FD.  Silently does nothing when
   SECONDS is nil or non-positive."
  (when (and seconds (> seconds 0))
    ;; struct timeval is 16 bytes on both platforms: tv_sec is 64-bit at
    ;; offset 0, tv_usec is 32-bit (darwin) or 64-bit (linux) at offset
    ;; 8.  Writing tv_usec as 32 bits and leaving 12-15 zero is correct
    ;; for both, since both are little-endian.
    (let ((buf (make-array 16 :element-type '(unsigned-byte 8)
                              :initial-element 0)))
      (multiple-value-bind (sec frac) (floor seconds)
        (let ((usec (round (* frac 1000000))))
          (dotimes (i 8) (setf (aref buf i)       (ldb (byte 8 (* 8 i)) sec)))
          (dotimes (i 4) (setf (aref buf (+ 8 i)) (ldb (byte 8 (* 8 i)) usec)))))
      (sb-sys:with-pinned-objects (buf)
        (dolist (opt (list +so-rcvtimeo+ +so-sndtimeo+))
          (%setsockopt fd +sol-socket+ opt
                       (sb-alien:sap-alien (sb-sys:vector-sap buf) (* t))
                       16))))))

(defun stream-fd (stream)
  "The file descriptor behind STREAM, for either stream type we hand out."
  (cond ((typep stream 'arc-ssl-stream)
         (sb-bsd-sockets:socket-file-descriptor (ssl-stream-sock stream)))
        ((typep stream 'sb-sys:fd-stream)
         (sb-sys:fd-stream-fd stream))))

(defun wait-readable (stream timeout host-desc)
  "Block until STREAM has data available.  Signals an error if TIMEOUT
   seconds pass with nothing to read.  A nil/0 timeout waits forever."
  (if (and timeout (> timeout 0))
      (let ((fd (stream-fd stream)))
        (or (null fd)                   ; unknown stream type: can't poll
            (sb-sys:wait-until-fd-usable fd :input timeout nil)
            (error "read from ~A timed out after ~A s" host-desc timeout)))
      t))

(defun tcp-connect (host port &optional timeout)
  "Open a TCP connection, return the raw socket.  TIMEOUT bounds later
   reads and writes; connect itself is bounded by the OS."
  (let* ((addr (sb-bsd-sockets:host-ent-address
                (sb-bsd-sockets:get-host-by-name host)))
         (sock (make-instance 'sb-bsd-sockets:inet-socket
                              :type :stream :protocol :tcp)))
    (sb-bsd-sockets:socket-connect sock addr port)
    (set-socket-timeout (sb-bsd-sockets:socket-file-descriptor sock) timeout)
    sock))

(defun arc-opt (opts key)
  "Look up KEY (a string) in an Arc options table. Returns the value
   or nil if the table is nil or the key is absent."
  (when (hash-table-p opts)
    (gethash (arc-sym key) opts)))

(defun arc-socket-connect (host port &optional opts)
  "Connect to host:port, return a bidirectional stream.
   OPTS is an Arc table with optional keys:
     ssl      -- force SSL (default: auto for port 443)
     noverify -- skip certificate verification
     timeout  -- seconds a read may stall before erroring (0 = forever,
                 default *http-timeout*)"
  (let* ((ssl-p (or (arc-opt opts "ssl") (= port 443)))
         (noverify (arc-opt opts "noverify"))
         ;; No default here: socket-connect is a general primitive (SMTP
         ;; in email.arc uses it), and a socket-level timeout changes how
         ;; those streams behave.  The default lives in http-fetch, which
         ;; is where the unbounded reads were a problem.
         (timeout (arc-opt opts "timeout"))
         (sock (tcp-connect host port timeout)))
    (if ssl-p
        (progn
          (unless *ssl-available*
            (error "SSL not available (OpenSSL libraries not found)"))
          (err-clear-error)
          (let* ((fd (sb-bsd-sockets:socket-file-descriptor sock))
                 (ctx (ssl-ctx-new (tls-client-method))))
            (unless noverify
              (ssl-ctx-set-default-verify-paths ctx)
              ;; SSL_VERIFY_PEER = 1
              (ssl-ctx-set-verify ctx 1
                (sb-alien:sap-alien (sb-sys:int-sap 0) (* t))))
            (let ((ssl (ssl-new ctx)))
              (ssl-set-fd ssl fd)
              (ssl-set-tlsext-host-name ssl host)
              (unless noverify
                (ssl-set1-host ssl host))
              (let ((ret (ssl-connect ssl)))
                (when (<= ret 0)
                  (let* ((code (ssl-get-error ssl ret))
                         (vr   (ssl-get-verify-result ssl))
                         (vmsg (when (plusp vr)
                                 (x509-verify-cert-error-string vr)))
                         (msg  (or vmsg (ssl-error-string))))
                    (ssl-free ssl)
                    (ssl-ctx-free ctx)
                    (sb-bsd-sockets:socket-close sock)
                    (error "SSL connect to ~A:~D failed: ~A"
                           host port (or msg (format nil "SSL_get_error=~D" code))))))
              (make-instance 'arc-ssl-stream :ssl ssl :ctx ctx :sock sock))))
        (sb-bsd-sockets:socket-make-stream
         sock :input t :output t
         :element-type :default
         :external-format :utf-8
         :buffering :full))))

(xdef socket-connect (host port &rest args)
  (arc-socket-connect host port (car args)))

;;; ---- HTTP convenience layer ----

(defun parse-url (url)
  "Parse URL into (values host port path use-ssl)."
  (let* ((ssl (cond ((and (>= (length url) 8)
                          (string-equal url "https://" :end1 8))
                     t)
                    ((and (>= (length url) 7)
                          (string-equal url "http://" :end1 7))
                     nil)
                    (t (error "Unsupported URL scheme: ~A" url))))
         (rest (subseq url (if ssl 8 7)))
         (slash-pos (position #\/ rest))
         (host-port (if slash-pos (subseq rest 0 slash-pos) rest))
         (path (if slash-pos (subseq rest slash-pos) "/"))
         (colon-pos (position #\: host-port))
         (host (if colon-pos (subseq host-port 0 colon-pos) host-port))
         (port (if colon-pos
                   (parse-integer (subseq host-port (1+ colon-pos)))
                   (if ssl 443 80))))
    (values host port path ssl)))

;; The HTTP response is read as raw octets and only decoded to characters
;; after the transfer framing has been removed.  Decoding earlier (e.g.
;; per SSL_read buffer, as stream-read-char does) breaks on multi-byte
;; UTF-8 characters that straddle a chunk boundary or a transport read
;; boundary: the leading byte ends up followed by chunk framing (CRLF, a
;; hex size, CRLF) instead of its continuation bytes.

(defun http-response-end (out header-end need chunked)
  "True when OUT already holds the whole response, so we can stop reading
   instead of waiting for the peer to close.  NEED is the total length
   implied by Content-Length; CHUNKED means look for the terminal chunk."
  (cond ((null header-end) nil)
        (need    (>= (length out) need))
        (chunked (let ((n (length out)))
                   ;; terminal chunk: CRLF "0" CRLF CRLF
                   (and (>= n (+ header-end 4 7))
                        (= (aref out (- n 7)) 13) (= (aref out (- n 6)) 10)
                        (= (aref out (- n 5)) 48)
                        (= (aref out (- n 4)) 13) (= (aref out (- n 3)) 10)
                        (= (aref out (- n 2)) 13) (= (aref out (- n 1)) 10))))
        (t nil)))

(defun http-slurp-octets (stream &optional timeout deadline host-desc)
  "Read the entire response from STREAM into a fresh adjustable
   (unsigned-byte 8) vector, with no character decoding.

   Stops as soon as the response is complete per Content-Length or the
   terminal chunk, rather than waiting for EOF: a server that ignores
   our `Connection: close' would otherwise hang us forever holding a
   response we had already fully received (measured).  Falls back to
   reading until EOF when neither framing is present.

   Signals an error if a single read stalls for TIMEOUT seconds, or if
   the whole read exceeds DEADLINE (internal-real-time units)."
  (let ((out (make-array 8192 :element-type '(unsigned-byte 8)
                              :adjustable t :fill-pointer 0))
        (buf (make-array 8192 :element-type '(unsigned-byte 8)))
        (ssl-p (typep stream 'arc-ssl-stream))
        (header-end nil) (need nil) (chunked nil))
    (loop
      (when (and deadline (> (get-internal-real-time) deadline))
        (error "read from ~A exceeded its overall time limit" host-desc))
      (wait-readable stream timeout host-desc)
      (let ((n (sb-sys:with-pinned-objects (buf)
                 (if ssl-p
                     ;; Read raw bytes straight from SSL, bypassing the
                     ;; stream's per-buffer UTF-8 decoding.
                     (ssl-read (ssl-stream-ssl stream)
                               (sb-sys:vector-sap buf) 8192)
                     ;; Plain socket: read(2) on the fd directly.  We
                     ;; never read through the stream, so nothing is
                     ;; buffered behind us -- and unlike read-sequence,
                     ;; this returns what's available instead of blocking
                     ;; until the buffer is full, which is what lets the
                     ;; Content-Length check below fire.
                     (multiple-value-bind (cnt errno)
                         (sb-unix:unix-read (stream-fd stream)
                                            (sb-sys:vector-sap buf) 8192)
                       ;; nil is a failed read, not end of data; treating
                       ;; it as EOF would truncate the body silently.
                       (or cnt
                           (error "read from ~A failed (errno ~D)"
                                  host-desc errno)))))))
        (when (<= n 0)
          (when (and ssl-p (minusp n))
            ;; SSL_ERROR_SYSCALL (5) with a -1 return is a failed read(2)
            ;; -- with SO_RCVTIMEO set that means the timeout fired.  A 0
            ;; return is a peer that closed without close_notify, which is
            ;; common enough to treat as a clean EOF.
            (let ((code (ssl-get-error (ssl-stream-ssl stream) n)))
              (when (= code 5)
                (error "read from ~A timed out" host-desc))))
          (return))
        (dotimes (i n) (vector-push-extend (aref buf i) out))
        ;; Learn the framing once, then checking for completion is O(1).
        (unless header-end
          (setf header-end (octets-find-crlfx2 out))
          (when header-end
            (let* ((hdrs (parse-http-headers (octets->latin1 out 0 header-end)))
                   (te (cdr (assoc "transfer-encoding" hdrs :test #'string=)))
                   (cl (cdr (assoc "content-length" hdrs :test #'string=))))
              (cond ((and te (search "chunked" (string-downcase te)))
                     (setf chunked t))
                    (cl (let ((k (parse-integer cl :junk-allowed t)))
                          (when k (setf need (+ header-end 4 k)))))))))
        (when (http-response-end out header-end need chunked)
          (return))))
    out))

(defun octets->latin1 (v start end)
  "Decode V[start:end] as latin-1 (one octet = one char).  Used for the
   ASCII header block, where every octet maps to itself."
  (sb-ext:octets-to-string v :start start :end end :external-format :latin-1))

(defun octets-find-crlf (v start)
  "Index of the CR of the first CRLF at or after START, or nil."
  (loop for i from start below (1- (length v))
        when (and (= (aref v i) 13) (= (aref v (1+ i)) 10))
          return i))

(defun octets-find-crlfx2 (v)
  "Index of the CR of the first CRLFCRLF (header terminator), or nil."
  (loop for i from 0 below (- (length v) 3)
        when (and (= (aref v i) 13) (= (aref v (+ i 1)) 10)
                  (= (aref v (+ i 2)) 13) (= (aref v (+ i 3)) 10))
          return i))

(defun split-crlf (str)
  "Split STR on CRLF into a list of lines."
  (let ((crlf (coerce (list #\return #\newline) 'string)))
    (loop with start = 0
          for pos = (search crlf str :start2 start)
          collect (subseq str start (or pos (length str)))
          while pos
          do (setf start (+ pos 2)))))

(defun parse-http-headers (header-str)
  "Alist of (lowercased-name . value) for the header block, excluding the
   status line."
  (let ((result '()))
    (dolist (line (cdr (split-crlf header-str)) (nreverse result))
      (let ((colon (position #\: line)))
        (when colon
          (push (cons (string-downcase (string-trim '(#\space #\tab)
                                                    (subseq line 0 colon)))
                      (string-trim '(#\space #\tab) (subseq line (1+ colon))))
                result))))))

(defun dechunk-octets (body)
  "Decode a chunked transfer-encoding payload (octet vector) into a fresh
   octet vector with the chunk framing removed."
  (let ((out (make-array (length body) :element-type '(unsigned-byte 8)
                                       :adjustable t :fill-pointer 0))
        (i 0)
        (len (length body)))
    (loop
      (let ((line-end (octets-find-crlf body i)))
        (unless line-end (return))
        (let* ((size-str (octets->latin1 body i line-end))
               (semi (position #\; size-str)) ; ignore chunk extensions
               (size (parse-integer size-str :radix 16 :junk-allowed t
                                    :end (or semi (length size-str)))))
          (when (or (null size) (zerop size)) (return)) ; last/invalid chunk
          (setf i (+ line-end 2))             ; past the size line's CRLF
          (loop for k from 0 below size
                while (< i len)
                do (vector-push-extend (aref body i) out)
                   (incf i))
          (setf i (+ i 2)))))                 ; past the chunk data's CRLF
    out))

(defun http-parse-response (raw)
  "RAW is an (unsigned-byte 8) vector holding a full HTTP response.  Return
   (values status-code header-string body-octets), with any chunked
   transfer-encoding decoded and the body trimmed to Content-Length when
   present.  BODY-OCTETS is left undecoded."
  (let ((header-end (octets-find-crlfx2 raw)))
    (unless header-end
      (error "Malformed HTTP response: no header terminator"))
    (let* ((header-str (octets->latin1 raw 0 header-end))
           (body (subseq raw (+ header-end 4)))
           (headers (parse-http-headers header-str))
           (status-line (car (split-crlf header-str)))
           ;; "HTTP/1.1 200 OK" -> 200
           (status-code (parse-integer status-line :start 9 :end 12))
           (te (cdr (assoc "transfer-encoding" headers :test #'string=)))
           (cl (cdr (assoc "content-length" headers :test #'string=))))
      (cond ((and te (search "chunked" (string-downcase te)))
             (setf body (dechunk-octets body)))
            (cl (let ((n (parse-integer cl :junk-allowed t)))
                  (when (and n (< n (length body)))
                    (setf body (subseq body 0 n))))))
      (values status-code header-str body))))

(defun arc-http-request (url &optional opts)
  "Perform an HTTP request.  Returns (values status-code headers body),
   where HEADERS is an alist of (lowercased-name . value) and BODY is a
   decoded string.  Does not signal on non-2xx -- that's the caller's
   business, and 3xx replies carry headers worth reading (a login POST's
   Set-Cookie, say).
   OPTS is an Arc table with optional keys:
     method   -- HTTP method (default \"GET\")
     headers  -- alist of (name value) string pairs
     body     -- request body string
     noverify -- skip SSL certificate verification
     timeout  -- seconds a single read may stall (0 = forever)
     maxtime  -- seconds for the whole request"
  (multiple-value-bind (host port path use-ssl) (parse-url url)
    (let* ((method  (or (arc-opt opts "method") "GET"))
           (hdrs    (arc-opt opts "headers"))
           (reqbody (arc-opt opts "body"))
           (timeout (or (arc-opt opts "timeout") *http-timeout*))
           (maxtime (arc-opt opts "maxtime"))
           (deadline (when (and maxtime (> maxtime 0))
                       (+ (get-internal-real-time)
                          (* maxtime internal-time-units-per-second))))
           ;; One options table with every key in it.  Building it as an
           ;; either/or (noverify OR ssl) used to drop the ssl flag when
           ;; noverify was passed, so https on a non-443 port silently
           ;; connected in the clear.
           (sock-opts (let ((h (make-hash-table :test #'equal :synchronized t)))
                        (when use-ssl (setf (gethash (arc-sym "ssl") h) t))
                        (when (arc-opt opts "noverify")
                          (setf (gethash (arc-sym "noverify") h) t))
                        (when timeout (setf (gethash (arc-sym "timeout") h) timeout))
                        h))
           (stream  (arc-socket-connect host port sock-opts)))
      (unwind-protect
           (progn
             ;; Request line
             (write-string (format nil "~A ~A HTTP/1.1~C~C"
                                   method path #\return #\newline)
                           stream)
             ;; Required headers
             (write-string (format nil "Host: ~A~C~C" host #\return #\newline)
                           stream)
             (write-string (format nil "Connection: close~C~C"
                                   #\return #\newline)
                           stream)
             ;; User headers (alist of (name value) pairs)
             (dolist (pair hdrs)
               (write-string
                (format nil "~A: ~A~C~C"
                        (car pair) (cadr pair) #\return #\newline)
                stream))
             ;; Content-Length for body
             (when reqbody
               (write-string
                (format nil "Content-Length: ~D~C~C"
                        (length (sb-ext:string-to-octets reqbody
                                  :external-format :utf-8))
                        #\return #\newline)
                stream))
             ;; End of headers
             (write-string (format nil "~C~C" #\return #\newline) stream)
             ;; Body
             (when reqbody (write-string reqbody stream))
             (force-output stream)
             ;; Read response as raw octets; decode only after the transfer
             ;; framing is stripped (see http-slurp-octets / http-parse-response).
             (let ((raw (http-slurp-octets stream timeout deadline url)))
               (multiple-value-bind (code headers body)
                   (http-parse-response raw)
                 (values code
                         (parse-http-headers headers)
                         (sb-ext:octets-to-string
                          body :external-format '(:utf-8 :replacement #\?))))))
        (close stream)))))

(defun arc-http-fetch (url &optional opts)
  "Fetch URL via HTTP.  Returns the response body as a string, and
   signals an error on non-2xx.  See arc-http-request for OPTS."
  (multiple-value-bind (code headers body) (arc-http-request url opts)
    (declare (ignore headers))
    (unless (<= 200 code 299)
      (error "HTTP ~D from ~A" code url))
    body))

(defun arc-http-response (url &optional opts)
  "Like arc-http-fetch, but returns an Arc table of the whole response --
   status, headers and body -- and never signals on the status.  Headers
   are an alist of (name value) pairs, keeping duplicates: a response can
   carry several Set-Cookie lines and they all matter."
  (multiple-value-bind (code headers body) (arc-http-request url opts)
    (let ((h (make-hash-table :test #'equal :synchronized t)))
      (setf (gethash (arc-sym "status") h) code
            (gethash (arc-sym "headers") h)
              (mapcar (lambda (p) (list (car p) (cdr p))) headers)
            (gethash (arc-sym "body") h) body)
      h)))

(xdef http-fetch (url &rest args)
  (arc-http-fetch url (car args)))

(xdef http-response (url &rest args)
  (arc-http-response url (car args)))

;;;; ============================================================
;;;; Threading  (sb-thread)
;;;; ============================================================

(xdef new-thread (f)
  (sb-thread:make-thread
   (lambda ()
     ;; handler-bind (not handler-case) so arc-report-error runs before
     ;; the stack unwinds -- otherwise its backtrace would show only this
     ;; thread's entry frame, not the arc functions that signalled.
     (block done
       (handler-bind ((error (lambda (c)
                               (arc-report-error c *error-output*)
                               (return-from done nil))))
         (arc-call0 f))))
   :name "arc"))

(xdef kill-thread (th) (sb-thread:terminate-thread th) nil)

(xdef break-thread (th)
  (sb-thread:interrupt-thread
   th (lambda () (error "Thread interrupted")))
  nil)

(xdef current-thread () sb-thread:*current-thread*)

(xdef dead-thread (th) (not (sb-thread:thread-alive-p th)))

(xdef join-thread (th &optional (default t))
  (sb-thread:join-thread th :default default))

(xdef sleep (n) (sleep n) nil)

;;;; ---- lock ordering ----

;;; Locks are assigned integer levels and must be acquired in strictly
;;; increasing order; re-entering a lock already held is always allowed.
;;; This turns a potential deadlock into a loud, deterministic error at
;;; the moment of the offending acquisition, usually in a single thread,
;;; rather than an intermittent hang under load.  See
;;; docs/agents/plans/2026-08-02-001-remove-global-mutex.md, principle 3.

;;; lock priorities: see arc.arc

(defvar *arc-lock-levels* nil
    "Stack of (level . lock) for locks held by this thread, innermost first.
     Per-thread by virtue of always being LET-bound, never SETF'd.")

(defvar *arc-check-lock-order* t)

(defvar *arc-lock-level-table* (make-hash-table :test #'eq :synchronized t))

(defun arc-lock-level (lock)
  (or (gethash lock *arc-lock-level-table*) 99))  ; unregistered = leaf

(xdef set-lock-level (lock n) (setf (gethash lock *arc-lock-level-table*) n))

(defun lock-repr (lock)
  "A readable name for LOCK.  Diagnostics only, so it never errors: a lock
made by make-lock carries its name under 'name, *arc-mutex* is an
sb-thread mutex with a :name, and anything else prints as itself."
  (cond ((hash-table-p lock)           (or (gethash (arc-sym "name") lock)
                                           "unnamed"))
        ((typep lock 'sb-thread:mutex) (sb-thread:mutex-name lock))
        (t                             lock)))

(defun held-locks-repr ()
  "The current thread's held locks as (name level), innermost first."
  (mapcar (lambda (e) (list (lock-repr (cdr e)) (car e)))
          *arc-lock-levels*))

(defun arc-check-lock-level (level lock)
  (when *arc-check-lock-order*
    (let ((top (car *arc-lock-levels*)))
      (when (and top
                 ;; re-entering a lock we already hold anywhere is safe
                 (not (find lock *arc-lock-levels* :key #'cdr))
                 (<= level (car top)))
        (error "Lock order violation: acquiring ~A (level ~D) while holding ~A (level ~D)~%  held: ~A"
               (lock-repr lock) level
               (lock-repr (cdr top)) (car top)
               (held-locks-repr))))))

;;;; ---- atomic-invoke ----

;; Named "arc-lock", not "arc": threads are named "arc" too, so a mutex
;; called "arc" makes SBCL's own deadlock reports ambiguous (the mutex,
;; its owner, and the waiting thread would all print as "arc").
(defvar *arc-mutex* (sb-thread:make-mutex :name "arc-lock"))
(defvar *arc-atomic-owner* nil)

(defun arc-already-atomic ()
  (eq sb-thread:*current-thread* *arc-atomic-owner*))

(xdef atomic-invoke (f)
  (if (arc-already-atomic)
      (arc-call0 f)
      (progn
        (arc-check-lock-level 0 *arc-mutex*)
        (let ((*arc-lock-levels* (cons (cons 0 *arc-mutex*) *arc-lock-levels*)))
          (sb-thread:with-mutex (*arc-mutex*)
            (let ((*arc-atomic-owner* sb-thread:*current-thread*))
              (arc-call0 f)))))))

;;;; ---- call-w/locked-table ----

;;; NB: with-locked-hash-table gives no protection against weak-entry
;;; culling, which the GC performs outside this mutex.  Do not use this
;;; to build a check-then-act sequence over a weak table.  See
;;; docs/agents/plans/2026-08-02-002-weak-tables-and-synchronized.md.

(xdef call-w/locked-table (table thunk)
  (let ((level (arc-lock-level table)))
    (arc-check-lock-level level table)
    (let ((*arc-lock-levels* (cons (cons level table) *arc-lock-levels*)))
      (sb-ext:with-locked-hash-table (table)
        (arc-call0 thunk)))))

;;;; ============================================================
;;;; System calls
;;;; ============================================================

(defun arc-grab-line (&optional (stream *standard-input*) (eof nil))
  (multiple-value-bind (line missing-newline-p) (read-line stream nil :arc/eof)
    (if (eq line :arc/eof) eof (list line missing-newline-p))))

(defun arc-put-line (pair &optional (stream *standard-output*))
  (when pair
    (let ((line (car pair))
          (missing-newline-p (cadr pair)))
      (if missing-newline-p
          (write-string line stream)
          (write-line line stream))
      (force-output stream))))

(xdef system (cmd)
  ;; give the child arc's current stdin, so e.g.
  ;;   (fromstring "foo" (system "cat"))  prints "foo".
  ;; *standard-input* may be the real fd-stream (the child inherits it,
  ;; tty and all) or an in-memory stream like a string-input-stream
  ;; (SBCL copies it to the child through a pipe in the background, so
  ;; reading the child's output below can't deadlock against the write).
  (let* ((bin (if (listp cmd) (car cmd) "/bin/sh"))
         (args (if (listp cmd) (cdr cmd) (list "-c" cmd)))
         (proc (sb-ext:run-program bin args
                                   :input *standard-input*
                                   :output :stream :wait nil
                                   :search t))
         (out  (sb-ext:process-output proc)))
    ; (loop for c = (read-char out nil nil)
    ;       while c do (write-char c *standard-output*))
    (loop for c = (arc-grab-line out)
          while c do (arc-put-line c))
    (sb-ext:process-wait proc))
  nil)

(xdef pipe-from (cmd &optional (wait nil) (format :latin-1))
  ;; :external-format :latin-1 so each byte from the subprocess becomes
  ;; one Arc char.  Matches the file I/O defaults (see infile/outfile)
  ;; and keeps UTF-8 subprocess output round-trippable through Latin-1
  ;; files (each byte preserved literally).
  ;;
  ;; :input *standard-input* mirrors (system): the child gets arc's
  ;; current stdin.  A real fd-stream is inherited; an in-memory stream
  ;; (e.g. fromstring's) is copied to the child in the background, which
  ;; works even though the caller reads our returned stream later -- SBCL
  ;; captured the stream here and feeds it independently of the binding.
  (let* ((bin (if (listp cmd) (car cmd) "/bin/sh"))
         (args (if (listp cmd) (cdr cmd) (list "-c" cmd))))
    (sb-ext:process-output
     (sb-ext:run-program bin args
                         :input *standard-input*
                         :output :stream :wait wait
                         :external-format format
                         :search t))))

(xdef getenv (name &optional default)
  ;; treat both "unset" and "set-but-empty" as missing, matching
  ;; shell's ${VAR:-default}.  callers who really need to tell the
  ;; two cases apart can use sb-ext:posix-getenv directly.
  (let ((v (sb-ext:posix-getenv name)))
    (if (or (null v) (string= v ""))
        default
        v)))

;;;; ============================================================
;;;; Tables / hash tables
;;;; ============================================================

(xdef table (&rest args)
  (let ((h (make-hash-table :test #'equal :synchronized t)))
    (when args (arc-call1 (car args) h))
    h))

(xdef isotable (&rest args)
  (let ((h (make-hash-table :test #'arc-is2 :hash-function #'sb-impl::psxhash :synchronized t)))
    (when args (arc-call1 (car args) h))
    h))

(xdef maptable (fn table)
  (maphash (lambda (k v) (arc-call2 fn k v)) table)
  table)

(xdef sref (obj val idx)
  (cond
    ((hash-table-p obj)
     (if (null val) (remhash idx obj) (setf (gethash idx obj) val)))
    ((stringp obj)  (setf (char obj idx) val))
    ((consp obj)    (setf (car (nthcdr idx obj)) val))
    (t (error "Can't sref ~S" obj)))
  val)

;;;; ============================================================
;;;; protect / error handling
;;;; ============================================================

(xdef protect (during after)
  (unwind-protect (arc-call0 during) (arc-call0 after)))

(xdef err #'error)

(xdef on-err (errfn f)
  (handler-case (arc-call0 f)
    (error (c) (arc-call1 errfn c))))

(xdef details (c) (format nil "~A" c))

;;;; ============================================================
;;;; Misc primitives
;;;; ============================================================

(defun arc-rand (&optional (n 1.0d0))
  (cond ((= n 0) 0)
        ((< n 0) (- (arc-rand (- n))))
        (t (crypto:strong-random n))))

(xdef rand #'arc-rand)

(xdef rand-bits #'crypto:random-bits)

(defun arc-dir (name)
  (let* ((base (if (or (zerop (length name))
                       (eql (char name (1- (length name))) #\/))
                   name
                   (concatenate 'string name "/")))
         (files (directory (concatenate 'string base "*.*")))
         (subdirs (directory (concatenate 'string base "*/"))))
    (append
     (loop for p in files
           for n = (file-namestring p)
           unless (or (null n) (string= n "")) collect n)
     (mapcar (lambda (p)
               (concatenate 'string (car (last (pathname-directory p))) "/"))
             subdirs))))

(xdef dir (name) (arc-dir name))

(defun arc-file-exists (name)
  (if (probe-file name) name nil))

(xdef file-exists (name) (arc-file-exists name))

(defun arc-dir-exists (name)
  (let ((p (probe-file name)))
    (if (and p (cl:pathname-name p) (string= (cl:pathname-name p) ""))
        nil
        (if (and p (null (pathname-name p))) name nil))))

(xdef dir-exists (name) (arc-dir-exists name))

(defun arc-rmfile (name)
  (delete-file name)
  nil)

(xdef rmfile (name) (arc-rmfile name))

(xdef mvfile (old new)
  ; CL rename-file merges new-name with old's truename, which can
  ; double directory components and inherit the old extension.
  ; Avoid both by making new-name absolute and setting type to
  ; :unspecific (explicitly no extension) when the caller provides none.
  (let* ((new-p    (pathname new))
         (new-typed (make-pathname :defaults new-p
                                   :type (or (pathname-type new-p) :unspecific)))
         (new-abs  (merge-pathnames new-typed *default-pathname-defaults*)))
    (rename-file old new-abs))
  nil)

(xdef cpfile (old new)
  ; copy old's contents to new.  Go through (unsigned-byte 8) so the
  ; copy is byte-exact regardless of encoding, and use :supersede /
  ; :create to mirror outfile's overwrite semantics.
  (with-open-file (in old :direction :input :element-type '(unsigned-byte 8))
    (with-open-file (out new :direction :output
                             :element-type '(unsigned-byte 8)
                             :if-exists :supersede
                             :if-does-not-exist :create)
      (let ((buf (make-array 65536 :element-type '(unsigned-byte 8))))
        (loop for n = (read-sequence buf in)
              while (plusp n)
              do (write-sequence buf out :end n)))))
  nil)

(xdef bound (x) (tnil (arc-bound-p x)))

(xdef newstring (size &optional (c #\space))
  (make-string size :initial-element c))

(xdef trunc (x) (truncate x))

(xdef exact (x) (tnil (and (integerp x) (= x (truncate x)))))

;; Clocks:
;;  now  -- wall-clock Unix time (seconds, double, microsecond precision);
;;          absolute, but can jump (NTP / manual changes).
;;  msec -- monotonic milliseconds (double), for measuring durations.
;;  nsec -- monotonic nanoseconds (integer), jump-proof and high-res.
;; msec and nsec have arbitrary, unrelated epochs, so only differences
;; are meaningful -- don't treat them as wall-clock times or compare them
;; to now (or each other).

(defun arc-now ()
  (multiple-value-bind (s us) (sb-ext:get-time-of-day)
    (+ s (/ us 1000000d0))))

(xdef now #'arc-now)

(defun arc-msec ()
  (* 1d0 (* 1000 (/ (get-internal-real-time)
                    internal-time-units-per-second))))

(xdef msec #'arc-msec)

(defun arc-nsec ()
  (multiple-value-bind (s ns) (sb-unix:clock-gettime sb-unix:clock-monotonic)
    (+ (* s 1000000000) ns)))

(xdef nsec #'arc-nsec)

(defun arc-current-process-milliseconds ()
  (* 1d0 (* 1000 (/ (get-internal-run-time)
                    internal-time-units-per-second))))

(xdef current-process-milliseconds #'arc-current-process-milliseconds)

(xdef current-gc-milliseconds () 0)

;;; Unix time: CL universal time is from 1900; Unix from 1970
(defconstant +cl-to-unix+ 2208988800)

(xdef seconds () (- (get-universal-time) +cl-to-unix+))

;; a file's last-modification time as Unix seconds (nil if it's missing)
(xdef modtime (name)
  (let ((p (probe-file name)))
    (and p (- (file-write-date p) +cl-to-unix+))))

(xdef timedate (&rest args)
  (let* ((unix (if args (car args) (- (get-universal-time) +cl-to-unix+)))
         (ut   (+ unix +cl-to-unix+))
         (d    (multiple-value-list (decode-universal-time ut 0))))
    ;; sec min hr day mon yr ...
    (list (first d) (second d) (third d) (fourth d) (fifth d) (sixth d))))

(xdef sin  #'sin)
(xdef cos  #'cos)
(xdef tan  #'tan)
(xdef asin #'asin)
(xdef acos #'acos)
(xdef atan #'atan)
(xdef log  #'log)

(xdef flushout (&optional (s *standard-output*))
  (force-output s) t)

(xdef quit () (sb-ext:exit))

(xdef memory () (sb-kernel:dynamic-usage))

(defun arc-heap-hist ()
  (sb-ext:gc :full t)
  (let ((h (make-hash-table :test 'eq)))
    (sb-vm:map-allocated-objects
     (lambda (obj widetag size)
       (declare (ignore widetag size))
       (incf (gethash (type-of obj) h 0)))
     :dynamic)
    (let (rows)
      (maphash (lambda (k v) (push (cons v k) rows)) h)
      (sort (subseq (sort rows #'> :key #'car) 0 30)
            #'string< :key #'arc-heap-name))))

(defun arc-heap-name (x)
  (if (consp x)
      (or (arc-heap-name (car x))
          (arc-heap-name (cdr x)))
      (if (symbolp x)
          (symbol-name x)
          nil)))

(xdef heap-hist #'arc-heap-hist)

;;;; ---- close / force-close ----

(xdef close (&rest args)
  (dolist (p args)
    (ignore-errors
      (cond ((typep p 'arc-server-socket) (sb-bsd-sockets:socket-close (ass-sock p)))
            ((streamp p) (cl:close p))
            (t nil))))
  nil)

(xdef force-close (&rest args)
  (dolist (p args)
    (ignore-errors
      (cond ((typep p 'arc-server-socket) (sb-bsd-sockets:socket-close (ass-sock p)))
            ((streamp p) (cl:close p :abort t))
            (t nil))))
  nil)

;;;; ============================================================
;;;; REPL
;;;; ============================================================

(defun arc-report-frame (frame &optional (stream *error-output*))
  ;; Print frames under :invert readtable case so mixed-case
  ;; symbol names (like arc--CAR) come out without |...| escapes.
  ;; All-lowercase and all-uppercase names still print in their
  ;; canonical form; only mixed-case ones change.
  (let ((text (with-output-to-string (s)
                (let ((*print-pretty* nil)
                      (*readtable* (copy-readtable *readtable*)))
                  (setf (readtable-case *readtable*) :invert)
                  (sb-debug::print-frame-call frame s :number nil)))))
    (format stream "~A~%" text)))

(xdef report-frame #'arc-report-frame)

(defvar *arc-err-print-length* 10)
(defvar *arc-err-print-level* 4)

(defun arc-map-backtrace (fn)
  (sb-debug:map-backtrace fn))

(xdef map-backtrace #'arc-map-backtrace)

(defun arc-report-backtrace (&optional (stream *error-output*) (report-frame #'arc-report-frame))
  (let ((*print-length* *arc-err-print-length*)
        (*print-level* *arc-err-print-level*))
    (format stream "Backtrace for: ~A~%" sb-thread:*current-thread*)
    (let ((i 0)
          (count 30)
          (stop nil))
      (arc-map-backtrace
       (lambda (frame)
         (when (and (not stop) (< i count))
           (format stream "~D: " i)
           (funcall report-frame frame stream)
           (incf i)
           (let ((name (sb-di:debug-fun-name (sb-di:frame-debug-fun frame))))
             (when (and (symbolp name)
                        (string= (symbol-name name) "ARC-BOOT"))
               (setf stop t)))))))
    (terpri stream)
    (force-output stream)))

(xdef report-backtrace #'arc-report-backtrace)

(defun arc-report-error (c &optional (stream *error-output*))
  (let ((*print-length* *arc-err-print-length*)
        (*print-level* *arc-err-print-level*))
    (format stream "Error: ~A~%" c))
  (arc-report-backtrace stream))

(xdef report-error #'arc-report-error)

(defun arc-tl ()
  (format t "Use (quit) to quit.~%")
  (arc-tl2))

(xdef repl #'arc-tl)

(defvar *arc-repl-print-length* 100)
(defvar *arc-repl-print-level* 8)

(defun arc-tl2 ()
  (format t "arc> ")
  (force-output *standard-output*)
  (block iter
    (handler-bind ((sb-sys:interactive-interrupt
                    (lambda (c)
                      (declare (ignore c))
                      (clear-input *standard-input*)
                      (terpri)
                      (return-from iter)))
                   (error (lambda (c)
                            (arc-report-error c)
                            ;; Drop the rest of the buffered line so a
                            ;; mid-token read error doesn't leave stray
                            ;; delimiters that re-trigger on each prompt.
                            (clear-input *standard-input*)
                            (return-from iter))))
      (let ((expr (arc-read *standard-input* nil :eof)))
        (cond
          ((or (eq expr :eof) (equal expr :a)) (return-from arc-tl2 'done))
          (t
           (let ((val (arc-eval expr)))
             (let ((*print-length* *arc-repl-print-length*)
                   (*print-level* *arc-repl-print-level*))
               (arc-write-val val *standard-output*))
             (terpri)
             (setf (arc-global '|that|)     val)
             (setf (arc-global '|thatexpr|) expr)))))))
  (arc-tl2))

(xdef call-reporting (f)
  (block done
    (handler-bind ((error (lambda (c)
                            (arc-report-error c *error-output*)
                            (return-from done nil))))
      (arc-call0 f))))

