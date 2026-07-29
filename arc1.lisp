;;; arc1.lisp -- Arc compiler for Common Lisp (SBCL)
;;; Port of arc3.2/ac.scm.  Usage: sbcl --load arc1.lisp

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :asdf)
  (require :sb-bsd-sockets)
  (load (merge-pathnames "arc0.lisp" *load-pathname*)))

(defpackage :arc
  (:use :common-lisp)
  (:export #:arc-load #:arc-eval #:arc-read #:arc-read-1 #:arc-tl))

(in-package :arc)

;;;; ============================================================
;;;; Arc reader  (custom, to handle : . ! ~ & as symbol chars)
;;;; ============================================================
;;; CL's package: separator conflicts with Arc ssyntax (foo:bar = compose).
;;; We write our own tokenizer so : is just a constituent character.

(xdef ssyntax  (x) (tnil (ssyntax-p x)))
(xdef ssexpand (x) (if (ssyntax-p x) (expand-ssyntax x) x))

(defun arc-whitespace-p (c)
  (member c '(#\space #\tab #\newline #\return #\page)))

(defun arc-delimiter-p (c)
  (or (arc-whitespace-p c)
      (member c '(#\( #\) #\[ #\] #\{ #\} #\" #\; ))))

(defun arc-read-vbar-segment (stream buf)
  "Read characters up to a closing |, writing them verbatim to BUF.
Backslash escapes the next character."
  (read-char stream)  ; consume opening |
  (loop
    (let ((c (read-char stream nil nil)))
      (cond
        ((null c) (error "Unexpected EOF in |...| symbol"))
        ((char= c #\|) (return))
        ((char= c #\\)
         (let ((next (read-char stream nil nil)))
           (when (null next) (error "Unexpected EOF after \\ in |...| symbol"))
           (write-char next buf)))
        (t (write-char c buf))))))

(defun arc-read-token (stream)
  "Read a bare token (symbol or number) from stream.
Handles a leading |...| segment and inline backslash escapes verbatim,
allowing special chars in symbol names. A backslash escapes the following
character even if it is a delimiter, so e.g. \\{ reads as the symbol named
{ (matching the Racket/CL reader). Returns (values string escaped-p) so
the caller can distinguish an escaped literal (the empty-name symbol ||,
or an escaped : that should stay a symbol) from an ordinary token."
  (let ((escaped nil))
    (values
     (with-output-to-string (buf)
       ;; A leading |...| segment reads verbatim.
       (when (eql #\| (peek-char nil stream nil nil))
         (setf escaped t)
         (arc-read-vbar-segment stream buf))
       (loop
         (let ((c (peek-char nil stream nil nil)))
           (cond
             ((null c) (return))
             ((char= c #\\)
              (setf escaped t)
              (read-char stream)  ; consume backslash
              (let ((next (read-char stream nil nil)))
                (if (null next)
                    (error "Unexpected EOF after \\ in token")
                    (write-char next buf))))
             ((arc-delimiter-p c) (return))
             (t (write-char (read-char stream) buf))))))
     escaped)))

(defun ssyntax-char-p (c)
  (member c '(#\: #\~ #\& #\| #\. #\!)))

(defun cl-package-qualified-p (str)
  "True if STR has the form pkg::name with non-empty pkg and name.
We only recognise the double-colon form; single colon stays compose ssyntax.
Either side containing an ssyntax char (e.g. a:sb-thread::x, sb-thread::x:b,
a&sb-thread::x) means this token belongs to ssyntax expansion, not pkg-qualified
interning -- ssyntax expansion will recurse into the qualified piece."
  (let ((p (search "::" str)))
    (and p (> p 0) (< (+ p 2) (length str))
         (not (find-if #'ssyntax-char-p str :end p))
         (not (find-if #'ssyntax-char-p str :start (+ p 2)))
         (not (search "::" str :start2 (+ p 2))))))

(defun arc-keyword-token-p (str)
  "True if STR is :foo or foo: --- a single leading or trailing colon
with at least one non-colon char and no other colons in the token.
Excludes pkg::name (handled elsewhere), bare : / ::, and foo:bar
(compose ssyntax)."
  (let ((len (length str)))
    (and (> len 1)
         (or (and (char= (char str 0) #\:)
                  (not (find #\: str :start 1)))
             (and (char= (char str (1- len)) #\:)
                  (not (find #\: str :end (1- len))))))))

(defun arc-keyword-from-token (str)
  "Strip the leading or trailing colon and intern the rest as a CL
keyword. Upcases to match the standard CL reader."
  (let ((name (if (char= (char str 0) #\:)
                  (subseq str 1)
                  (subseq str 0 (1- (length str))))))
    (intern (string-upcase name) :keyword)))

(defun intern-cl-qualified (str)
  "Parse pkg::name and look up the existing symbol in the named CL
package, upcasing both parts to match the standard CL reader. Unlike
CL's own pkg::name (which interns), we use find-symbol so a typo
errors out clearly rather than polluting (often locked) CL packages."
  (let* ((p (search "::" str))
         (pkg-name (string-upcase (subseq str 0 p)))
         (sym-name (string-upcase (subseq str (+ p 2))))
         (pkg (or (find-package pkg-name)
                  (error "No CL package named ~A in ~A" pkg-name str))))
    (or (find-symbol sym-name pkg)
        (error "No symbol named ~A in package ~A (~A)" sym-name pkg-name str))))

(defun arc-intern-token (str)
  "Convert a raw token string to a CL value."
  (cond
    ((string= str "") nil)
    ((string= str "nil") nil)
    ;; Intern t as arc::t (regular bindable symbol) rather than cl:t,
    ;; so it can be used as a lambda parameter name. ac translates
    ;; free references back to cl:t at expression position.
    ((string= str "t")   (arc-sym 't))
    (t
     ;; Try number first
     (let ((n (ignore-errors
                (with-standard-io-syntax
                  (let ((*read-eval* nil)
                        (*readtable* (copy-readtable nil)))
                    (let ((v (read-from-string str)))
                      (if (numberp v) v nil)))))))
       (or n (arc-sym str))))))

(defun arc-copy-balanced-paren (stream buf)
  "Copy a balanced parenthesised expression (including the opening
   `(` at STREAM's head and the matching `)`) into BUF. Outside any
   nested string, backslash escapes are processed like the surrounding
   atstring reader would. Inside a nested `\"...\"`, characters and
   `\\X` escapes are preserved verbatim so arc-read can later parse
   the string with its own escape handling. This lets `@(...)` capture
   either bare or backslash-escaped inner quotes."
  (let ((depth 0))
    (loop
      (let ((c (read-char stream t nil)))
        (cond
          ((char= c #\\)
           (let ((next (read-char stream t nil)))
             (write-char (case next
                           (#\n #\newline) (#\t #\tab) (#\r #\return)
                           (t next))
                         buf)))
          ((char= c #\()
           (write-char c buf)
           (incf depth))
          ((char= c #\))
           (write-char c buf)
           (decf depth)
           (when (zerop depth) (return)))
          ((char= c #\")
           (write-char c buf)
           (loop
              (let ((sc (read-char stream t nil)))
                (cond
                  ((char= sc #\\)
                   (write-char sc buf)
                   (write-char (read-char stream t nil) buf))
                  ((char= sc #\")
                   (write-char sc buf)
                   (return))
                  (t (write-char sc buf))))))
          (t (write-char c buf)))))))

(defun arc-read-string (stream)
  "Read a double-quoted string, handling backslash escapes.
   When atstrings is enabled, `@(...)` is captured as a balanced
   parenthesised form so inner quotes need not be escaped."
  (with-output-to-string (buf)
    (loop
      (let ((c (read-char stream t nil)))
        (cond
          ((char= c #\") (return))
          ((char= c #\\)
           (let ((next (read-char stream t nil)))
             (write-char (case next
                           (#\n #\newline) (#\t #\tab) (#\r #\return)
                           (t next))
                         buf)))
          ((and *arc-atstrings*
                (char= c #\@)
                (eql (peek-char nil stream nil nil) #\())
           (write-char #\@ buf)
           (arc-copy-balanced-paren stream buf))
          (t (write-char c buf)))))))

(defun arc-read-char-literal (stream)
  "Read #\\ character literal."
  ;; Already consumed #\\
  ;; If next char is a delimiter (e.g. #\ = space), read it directly.
  (let ((first (peek-char nil stream nil nil)))
    (when (or (null first) (arc-delimiter-p first))
      (return-from arc-read-char-literal
        (or (read-char stream nil nil)
            (error "EOF after #\\")))))
  (let ((buf (with-output-to-string (s)
               (loop
                 (let ((c (peek-char nil stream nil nil)))
                   (if (or (null c) (arc-delimiter-p c))
                       (return)
                       (write-char (read-char stream) s)))))))
    (cond
      ((string= buf "space")   #\space)
      ((string= buf "newline") #\newline)
      ((string= buf "tab")     #\tab)
      ((string= buf "return")  #\return)
      ((string= buf "null")    #\null)
      ((string= buf "nul")     #\null)
      ((= (length buf) 1)      (char buf 0))
      (t (error "Unknown character name: ~S" buf)))))

(defun arc-skip-comment (stream)
  (loop (let ((c (read-char stream nil nil)))
          (when (or (null c) (char= c #\newline)) (return)))))

(defun arc-read-list (stream close-char)
  "Read a list, handling dotted pairs."
  (let ((result nil))
    (loop
      (let ((c (arc-skip-ws stream)))
        (cond
          ((eq c :eof) (error "Unexpected EOF in list"))
          ((char= c close-char) (read-char stream) (return (nreverse result)))
          ((char= c #\.)
           ;; could be dot or number or symbol starting with .
           (read-char stream)
           (let ((next (peek-char nil stream nil nil)))
             (if (or (null next) (arc-delimiter-p next))
                 ;; It's a dotted-pair dot
                 (progn
                   (arc-skip-ws stream)
                   (let ((tail (arc-read-1 stream)))
                     (arc-skip-ws stream)
                     (let ((c2 (read-char stream nil nil)))
                       (unless (and c2 (char= c2 close-char))
                         (error "Expected ~C after cdr of dotted pair" close-char)))
                     (return (nconc (nreverse result) tail))))
                 ;; Not a dot - unread and read as token
                 (progn
                   (unread-char #\. stream)
                   (push (arc-read-1 stream) result)))))
          (t
           (push (arc-read-1 stream) result)))))))

(defun arc-skip-ws (stream)
  "Skip whitespace and comments.  Returns the next char (peeked, not
   consumed) or :eof.  On a TTY, `peek-char' triggers a read syscall;
   returning the char lets callers avoid a second peek that would
   require a second EOF (Ctrl-D) to dislodge."
  (loop
    (let ((c (peek-char nil stream nil :eof)))
      (cond
        ((eq c :eof) (return :eof))
        ((char= c #\;) (arc-skip-comment stream))
        ((arc-whitespace-p c) (read-char stream))
        (t (return c))))))

(defun arc-read-1 (stream)
  "Read one Arc expression from stream."
  (let ((c (arc-skip-ws stream)))
    (cond
      ((eq c :eof) (values :eof t))
      ((char= c #\()
       (read-char stream)
       (arc-read-list stream #\)))
      ((char= c #\[)
       (read-char stream)
       (let ((body (arc-read-list stream #\])))
         (cons (arc-sym '%brackets) body)))
      ((char= c #\{)
       (read-char stream)
       (let ((body (arc-read-list stream #\})))
         (cons (arc-sym '%braces) body)))
      ((char= c #\")
       (read-char stream)
       (arc-read-string stream))
      ((char= c #\')
       (read-char stream)
       (list (arc-sym 'quote) (arc-read-1 stream)))
      ((char= c #\`)
       (read-char stream)
       (list (arc-sym 'quasiquote) (arc-read-1 stream)))
      ((char= c #\,)
       (read-char stream)
       (let ((next (peek-char nil stream nil nil)))
         (if (and next (char= next #\@))
             (progn (read-char stream)
                    (list (arc-sym 'unquote-splicing)
                          (arc-read-1 stream)))
             (list (arc-sym 'unquote) (arc-read-1 stream)))))
      ((char= c #\#)
       (read-char stream)
       (let ((c2 (read-char stream t nil)))
         (cond
           ((char= c2 #\\)
            (arc-read-char-literal stream))
           ((char= c2 #\()
            ;; #(v0 v1 ...) - vector literal
            (apply #'vector (arc-read-list stream #\))))
           ((or (char= c2 #\t) (char= c2 #\T)) t)
           ((or (char= c2 #\f) (char= c2 #\F)) nil)
           ;; skip shebangs
           ((char= c2 #\!)
            (read-line stream nil)
            (arc-read-1 stream))
           ((char= c2 #\')
            (list (arc-sym 'function) (arc-read-1 stream)))
           ((char= c2 #\`)
            (list (arc-sym 'quasisyntax) (arc-read-1 stream)))
           ((char= c2 #\,)
            (let ((next (peek-char nil stream nil nil)))
              (if (and next (char= next #\@))
                  (progn (read-char stream)
                         (list (arc-sym 'unsyntax-splicing)
                               (arc-read-1 stream)))
                  (list (arc-sym 'unsyntax)
                        (arc-read-1 stream)))))
           (t (error "Unknown # syntax: #~C" c2)))))
      ((char= c #\;)
       (arc-skip-comment stream)
       (arc-read-1 stream))
      ((char= c #\))
       (error "Unexpected )"))
      ((char= c #\])
       (error "Unexpected ]"))
      ((char= c #\})
       (error "Unexpected }"))
      (t
       ;; Symbol or number
       (multiple-value-bind (tok had-vbar) (arc-read-token stream)
         (cond
           ;; Real |...| with an empty content -> the empty-name symbol.
           ((and (string= tok "") had-vbar) (arc-sym ""))
           ((string= tok "") (arc-read-1 stream)) ; shouldn't happen
           ;; Bare pkg::name interns directly into the named CL package.
           ;; |pkg::name| keeps the colons literal and stays in :arc.
           ((and (not had-vbar) (cl-package-qualified-p tok))
            (intern-cl-qualified tok))
           ;; :foo and foo: read as the CL keyword :FOO. |:foo| escapes.
           ((and (not had-vbar) (arc-keyword-token-p tok))
            (arc-keyword-from-token tok))
           (t (arc-intern-token tok))))))))

(defun arc-read (stream &optional (eof-error-p t) eof-value)
  (multiple-value-bind (val eof-p) (arc-read-1 stream)
    (if (eq val :eof)
        (if eof-error-p
            (error "End of file on ~S" stream)
            eof-value)
        val)))

;;;; ============================================================
;;;; ssyntax
;;;; ============================================================

(defun ssyntax-p (x)
  (and (symbolp x)
       (let ((n (symbol-name x)))
         (has-ssyntax-char-p n (- (length n) 2)))))

(defun has-ssyntax-char-p (str i)
  (and (>= i 0)
       (or (ssyntax-char-p (char str i))
           (has-ssyntax-char-p str (- i 1)))))

(defun arc-sym-intern (chars pkg)
  (intern (coerce chars 'string) pkg))

(defun chars->value (chars)
  (let ((str (coerce chars 'string)))
    (if (cl-package-qualified-p str)
        (intern-cl-qualified str)
        (arc-intern-token str))))

;; Tokenise CHARS for compose ssyntax: split on a single `:`, but keep
;; `::` (CL pkg-qualified marker) inside the surrounding token so e.g.
;; a:sb-thread::make-mutex -> ("a" "sb-thread::make-mutex").
(defun compose-tokens (chars)
  (let ((tokens nil) (cur nil))
    (labels ((flush () (when cur (push (nreverse cur) tokens) (setf cur nil))))
      (loop while chars do
        (let ((c (car chars)))
          (cond
            ((and (eql c #\:) (eql (cadr chars) #\:))
             (push c cur) (push c cur)
             (setf chars (cddr chars)))
            ((eql c #\:)
             (flush)
             (setf chars (cdr chars)))
            (t (push c cur)
               (setf chars (cdr chars))))))
      (flush)
      (nreverse tokens))))

(defun sym->chars (x) (coerce (symbol-name x) 'list))

(defun arc-tokens (test source token acc keepsep-p)
  (cond
    ((null source)
     (reverse (if (consp token) (cons (reverse token) acc) acc)))
    ((funcall test (car source))
     (arc-tokens test (cdr source) nil
                 (let ((rec (if (null token) acc (cons (reverse token) acc))))
                   (if keepsep-p (cons (car source) rec) rec))
                 keepsep-p))
    (t
     (arc-tokens test (cdr source) (cons (car source) token) acc keepsep-p))))

(defun sym-pkg (sym) (symbol-package sym))

;; Like (find c str) but treats `::` runs as transparent, so a `:`
;; that's part of a CL package marker doesn't trigger compose dispatch.
(defun find-outside-cl-marker (c str)
  (loop with len = (length str)
        with i = 0
        while (< i len)
        do (cond
             ((and (char= (char str i) #\:)
                   (< (1+ i) len)
                   (char= (char str (1+ i)) #\:))
              (incf i 2))
             ((char= (char str i) c) (return-from find-outside-cl-marker i))
             (t (incf i))))
  nil)

(defun expand-ssyntax (sym)
  (let ((n (symbol-name sym)))
    (cond
      ((find #\| n) (expand-or sym))
      ((find #\& n) (expand-and sym))
      ((or (find-outside-cl-marker #\: n) (find #\~ n)) (expand-compose sym))
      ((or (find #\. n) (find #\! n)) (expand-sexpr sym))
      (t (error "Unknown ssyntax: ~S" sym)))))

(defun expand-and (sym)
  (let ((pkg (sym-pkg sym)))
    (let ((elts (mapcar #'chars->value
                        (arc-tokens (lambda (c) (eql c #\&))
                                    (sym->chars sym) nil nil nil))))
      (if (null (cdr elts))
          (car elts)
          (cons (intern "andf" pkg) elts)))))

(defun expand-or (sym)
  (let ((pkg (sym-pkg sym)))
    (let ((elts (mapcar #'chars->value
                        (arc-tokens (lambda (c) (eql c #\|))
                                    (sym->chars sym) nil nil nil))))
      (if (null (cdr elts))
          (car elts)
          (cons (intern "orf" pkg) elts)))))

(defun expand-compose (sym)
  (let ((pkg (sym-pkg sym)))
    (let ((elts (mapcar
                 (lambda (tok)
                   (if (eql (car tok) #\~)
                       (if (null (cdr tok))
                           (intern "no" pkg)
                           `(,(intern "complement" pkg) ,(chars->value (cdr tok))))
                       (chars->value tok)))
                 (compose-tokens (sym->chars sym)))))
      (if (null (cdr elts))
          (car elts)
          (cons (intern "compose" pkg) elts)))))

(defun expand-sexpr (sym)
  (build-sexpr (reverse (arc-tokens (lambda (c) (or (eql c #\.) (eql c #\!)))
                                    (sym->chars sym) nil nil t))
               sym))

(defun build-sexpr (toks orig)
  (cond
    ((null toks) (intern "get" (sym-pkg orig)))
    ((null (cdr toks)) (chars->value (car toks)))
    (t (list (build-sexpr (cddr toks) orig)
             (if (eql (cadr toks) #\!)
                 (list (arc-sym 'quote) (chars->value (car toks)))
                 (if (or (eql (car toks) #\.) (eql (car toks) #\!))
                     (error "Bad ssyntax: ~S" orig)
                     (chars->value (car toks))))))))

;;;; ============================================================
;;;; Arc compiler  (ac)
;;;; ============================================================

(defvar *env* nil)

(defun literal-p (x)
  (or (eq x t) (characterp x) (stringp x) (numberp x) (null x)
      (keywordp x)))

(defun ac (s)
  (cond
    ((stringp s)                                 (ac-string s))
    ((literal-p s)                               s)
    ;; Arc nil/t with preserved case from arc-read
    ((and (arc-sym= s "nil") (not (lex-p s)))    nil)
    ;; Free reference to t -> cl:t; lex-bound t falls through to ac-var-ref
    ((and (arc-sym= s "t") (not (lex-p s)))      t)
    ((ssyntax-p s)                               (ac (expand-ssyntax s)))
    ((symbolp s)                                 (ac-var-ref s))
    ((arc-car? s #'ssyntax-p)                    (ac (cons (expand-ssyntax (car s)) (cdr s))))
    ((arc-sym= (arc-car? s) "function")          (cl-quoted (cadr s)))
    ((arc-sym= (arc-caar? s) "function")         (mapcar #'ac s))
    ;; (pkg::fn args...) compiles to a direct CL call -- same path as
    ;; ((function fn) args...) above, but lets you drop the #'.
    ((foreign-cl-call-p s)                       (cons (car s) (mapcar #'ac (cdr s))))
    ((arc-sym= (arc-car? s) "quote")             (list 'quote (ac-quoted (cadr s) t)))
    ((arc-sym= (arc-car? s) "quasiquote")        (ac-qq (cadr s)))
    ((arc-sym= (arc-car? s) "quasisyntax")       (ac-qs (cadr s)))
    ((arc-sym= (arc-car? s) "unsyntax")          (error "unsyntax outside quasisyntax: ~S" s))
    ((arc-sym= (arc-car? s) "unsyntax-splicing") (error "unsyntax-splicing outside quasisyntax: ~S" s))
    ((arc-sym= (arc-car? s) "%do")               `(progn ,@(ac-body* (cdr s))))
    ((arc-sym= (arc-car? s) "if")                (ac-if (cdr s)))
    ((ac-fn-value-p s)                           (ac-fn (cadr s) (cddr s)))
    ((arc-sym= (arc-car? s) "assign")            (ac-set (cdr s)))
    ;; the next three clauses could be removed without changing semantics
    ;; ... except that they work for macros (so prob should do this for
    ;; every elt of s, not just the car)
    ((arc-sym= (arc-caar? s) "compose")          (ac (decompose (cdar s) (cdr s))))
    ((arc-sym= (arc-caar? s) "complement")       (ac `(,(intern "no" (sym-pkg (caar s)))
                                                        (,(cadar s) ,@(cdr s)))))
    ((arc-sym= (arc-caar? s) "andf")             (ac-andf s))
    ((arc-sym= (arc-caar? s) "orf")              (ac-orf s))
    ;; uncomment this next line to see which expression is causing a
    ;; crash due to a function call on non-function (e.g. nil/num/sym)
    ;((consp s)                                  (ac-safe-call (car s) (cdr s)))
    ((consp s)                                   (ac-call (car s) (cdr s)))
    (t (error "Bad object in expression: ~S" s))))

;;;; ---- Atstring expansion ----

(defun atpos (s i)
  (cond ((>= i (length s)) nil)
        ((char= (char s i) #\@)
         (if (and (< (1+ i) (length s))
                  (char/= (char s (1+ i)) #\@))
             i
             (atpos s (+ i 2))))
        (t (atpos s (1+ i)))))

(defun unescape-ats (s)
  (with-output-to-string (out)
    (loop with i = 0 and len = (length s)
          while (< i len)
          do (let ((c (char s i)))
               (if (and (char= c #\@)
                        (< (1+ i) len)
                        (char= (char s (1+ i)) #\@))
                   (progn (write-char #\@ out) (incf i 2))
                   (progn (write-char c out)   (incf i)))))))

(defun codestring (s)
  (let ((i (atpos s 0)))
    (if i
        (cons (subseq s 0 i)
              (let* ((rest (subseq s (1+ i)))
                     (in   (make-string-input-stream rest))
                     (expr (arc-read in nil :eof))
                     (pos  (file-position in)))
                (cons expr (codestring (subseq rest pos)))))
        (list s))))

(defun ac-codestring (x)
  (cond
    ((arc-sym= (arc-car? x) "%braces")
     (ac-codestring (cadr x)))
    ((stringp x)
     (unescape-ats x))
    (t x)))

(defun ac-string (s)
  (if *arc-atstrings*
      (let ((pos (atpos s 0)))
        (if pos
            (ac (cons (arc-sym 'string)
                      (mapcar #'ac-codestring (codestring s))))
            (copy-seq (unescape-ats s))))
      (copy-seq s)))

;;;; ---- quoting ----

;; Symbols already in a non-:arc package (e.g. SB-THREAD:MAKE-SEMAPHORE
;; written as sb-thread::make-semaphore) pass through unchanged --
;; only :arc-package symbols are case-normalised through cl-sym/arc-sym.

(defun arc-package-symbol-p (x)
  (and (symbolp x) (eq (symbol-package x) (find-package :arc))))

(defun foreign-cl-symbol-p (s)
  "True if S is a symbol from a package other than :arc and not visible
from :arc through inheritance. Symbols inherited via :use (like cl:=,
cl:cons) are NOT foreign even though their symbol-package is :common-lisp,
because Arc-side names resolve to them through find-symbol."
  (and (symbolp s)
       (let ((pkg (symbol-package s)))
         (and pkg
              (not (eq pkg (find-package :arc)))
              (not (eq (find-symbol (symbol-name s) :arc) s))))))

(defun foreign-cl-call-p (s)
  "True if S is a call form whose head is a foreign CL symbol that
isn't shadowed by a lexical binding."
  (and (consp s)
       (foreign-cl-symbol-p (car s))
       (not (lex-p (car s)))))

(defun cl-quoted (x)
  (cond ((null x) nil)
        ((eq x t) t)
        ((consp x)                (arc-imap #'cl-quoted x))
        ((arc-package-symbol-p x) (cl-sym x))
        (t x)))

(defun ac-quoted (x &optional fold-t)
  (cond ((null x) nil)
        ((eq x t) t)
        ; needed for (is t 't) to return t, and (eval '(let t 5 t)) to work.
        ((and fold-t (arc-sym= x "t")) t)
        ((consp x)                (arc-imap #'ac-quoted x))
        ((arc-package-symbol-p x) (arc-sym x))
        (t x)))


;;;; ---- quasiquote ----
;;; We compile Arc quasiquotes to explicit cons/list/append CL code.
;;; The Arc readtable produces (quasiquote ...) / (unquote ...) / (unquote-splicing ...)
;;; as plain s-expression lists.

(defun ac-qq (x)
  "Entry: compile Arc (quasiquote x) to list-building CL code."
  (if (arc-sym= x "t") t (ac-qq1 1 x)))

(defun ac-qq1 (level x)
  (cond
    ;; Level 0: compile as normal Arc expression
    ((= level 0) (ac x))
    ;; nil -> CL nil
    ((null x) nil)
    ;; Non-cons atoms -> quoted literal
    ((not (consp x)) `',x)
    ;; (quasiquote inner) -> increase level
    ((arc-sym= (car x) "quasiquote")
     `(cons ',(arc-sym 'quasiquote)
              (cons ,(ac-qq1 (1+ level) (cadr x)) nil)))
    ;; (unquote expr) at level 1 -> compile expr
    ((and (= level 1) (arc-sym= (car x) "unquote"))
     (ac (cadr x)))
    ;; (unquote expr) at level > 1 -> wrap, reducing level
    ((arc-sym= (car x) "unquote")
     `(cons ',(arc-sym 'unquote)
              (cons ,(ac-qq1 (1- level) (cadr x)) nil)))
    ;; Check car for unquote-splicing at level 1
    ((and (= level 1) (consp (car x)) (arc-sym= (caar x) "unquote-splicing"))
     `(append ,(ac (cadar x)) ,(ac-qq1 1 (cdr x))))
    ;; (unquote-splicing expr) at level > 1 -> wrap, reducing level
    ((and (> level 1) (arc-sym= (car x) "unquote-splicing"))
     `(cons ',(arc-sym 'unquote-splicing)
              (cons ,(ac-qq1 (1- level) (cadr x)) nil)))
    ;; Normal cons cell
    (t
     `(cons ,(ac-qq1 level (car x))
            ,(ac-qq1 level (cdr x))))))

;;;; ---- quasisyntax ----
;;; Unlike quasiquote (which builds a list at runtime via cons/list/append),
;;; quasisyntax produces a literal CL form at compile time. (unsyntax e)
;;; holes are replaced by (ac e). The result is suitable as input to
;;; CL macroexpansion, so #`(cl-macro #,arc-expr ...) lets you call CL
;;; macros from arc with arc subexpressions in selected slots.
;;;
;;; (unsyntax-splicing e) is intentionally not supported -- splicing
;;; would force a runtime list-construction expression, defeating the
;;; "literal form for the macroexpander" purpose. To inject a body, use
;;; #,(do ,@body) and rely on do -> progn.

(defun ac-qs (x)
  (cond
    ;; atoms pass through as a literal CL value: arc-package symbols are
    ;; converted to their CL symbols (uppercased, like #'/cl-quoted), so
    ;; #`(let ...) yields a real (CL:LET ...) without needing cl:: on
    ;; every operator.  #,holes are still ac-compiled below.
    ((not (consp x)) (cl-quoted x))
    ((arc-sym= (car x) "unsyntax") (ac (cadr x)))
    ((arc-sym= (car x) "unsyntax-splicing")
     (error "unsyntax-splicing inside quasisyntax not supported: ~S" x))
    (t (cons (ac-qs (car x)) (ac-qs (cdr x))))))

;;;; ---- if ----

(defun ac-if (args)
  (cond
    ((null args) nil)
    ((null (cdr args)) (ac (car args)))
    (t `(if ,(ac (car args))
            ,(ac (cadr args))
            ,(ac-if (cddr args))))))

;;;; ---- fn ----

;; A name marker is a one-element list (NAME) pushed onto *env* around an
;; fn value, so the fn knows a name it's being bound to.  Markers come
;; from ac-set1 (assignment, e.g. (= foo (fn ...))) and from ac-call
;; (an fn passed as an arg to an immediately-applied fn, e.g. the value
;; in (let f (fn ...) ...), which expands to ((fn (f) ...) (fn ...))).
;; The marker is a cons, so it can never be eq to a symbol and lex-p
;; ignores it.
;;
;; ac-fn does NOT consume the marker; it leaves it in the body env so
;; nested fns combine their enclosing names: a fn compiled with env
;; (y (bar) x (foo)) is named foo--bar, and an inner (let f ...) value
;; there is named foo--bar--f.  The combined name shows up in SBCL
;; backtraces.  Because named lambdas can land in operator position
;; (or= and friends expand to ((fn ...) ...)), ac-call/ac-safe-call emit
;; them under funcall, where a named-lambda is legal (a bare
;; ((named-lambda ...) ...) is not).

;; Lambda names that would collide with a CL symbol live here instead.
;; Naming a lambda after a CL symbol (arc's >= is cl:>=, car is cl:car,
;; ...) makes SBCL apply that symbol's ftype to the lambda body and
;; mis-infer types, so we copy such names into a private package that
;; has no function info attached.
(defpackage :arc-fn (:use))

(defun ac-fn-markers (env)
  "The marker names in ENV, outermost first (foo before the bar nested
   in it).  Markers are the cons entries; arglist entries are symbols."
  (let ((names nil))
    (dolist (e env names)
      (when (and (consp e) (symbolp (car e)))
        (push (car e) names)))))

(defun ac-safe-name (name)
  "NAME unless it's a CL symbol, in which case a same-named symbol in
   the :arc-fn package (so SBCL attaches no ftype to the lambda)."
  (if (eq (symbol-package name) (find-package :common-lisp))
      (intern (symbol-name name) :arc-fn)
      name))

(defun ac-fn-name (env)
  "Combined fn name from every marker in ENV (foo--bar--f), or nil.
   A joined name has a -- in it, so it can't collide with a CL symbol;
   a lone name might (e.g. >=), so it's run through ac-safe-name."
  (let ((markers (ac-fn-markers env)))
    (cond ((null markers)       nil)
          ((null (cdr markers)) (ac-safe-name (car markers)))
          (t (arc-sym (format nil "~{~A~^--~}"
                              (mapcar #'symbol-name markers)))))))

(defun ac-lambda (name largs body)
  "A CL lambda form, named (so it appears in backtraces) when NAME is set."
  (if name
      `(sb-int:named-lambda ,name ,largs ,@body)
      `(lambda ,largs ,@body)))

(defun ac-fn (args body)
  (let ((*env* *env*)
        (name (ac-fn-name *env*)))   ; combined name incl. enclosing markers
    (if (ac-complex-args-p args)
        (ac-complex-fn args body name)
        (let ((largs (ac-arglist-cl args)))
          (setf *env* (append (ac-arglist args) *env*))
          (ac-lambda name largs (ac-body* body))))))

;;; Convert Arc arglist to CL lambda list (handles rest params)
(defun ac-arglist-cl (args)
  (cond
    ((null args) nil)
    ((and (symbolp args) (not (arc-sym= args "nil")))
     `(&rest ,args))                       ; bare rest param
    ((symbolp (cdr args))
     (if (null (cdr args))
         (list (car args))
         (list (car args) '&rest (cdr args)))) ; (x . rest)
    (t (cons (car args) (ac-arglist-cl (cdr args))))))

(defun ac-complex-args-p (args)
  (cond
    ((or (null args) (arc-sym= args "nil")) nil)
    ((symbolp args) nil)
    ((and (consp args)
          (or (and (consp (car args)) (ac-table-pattern-p (car args)))
              (ac-table-pattern-p (car args))))
     t)
    ((and (consp args) (symbolp (car args))) (ac-complex-args-p (cdr args)))
    (t t)))

(defun ac-complex-fn (args body name)
  (let* ((ra (gensym "RA"))
         (z  (ac-complex-args args ra t)))
    (setf *env* (append (ac-complex-getargs z) *env*))
    (ac-lambda name `(&rest ,ra)
               `((let* ,z
                   ,@(ac-body* body))))))

(defun ac-complex-args (args ra is-params)
  (cond
    ((or (null args) (arc-sym= args "nil")) nil)
    ((symbolp args) (list (list args ra)))
    ((consp args)
     (let* ((slot-ra (if is-params `(car ,ra) `(arc-xcar ,ra)))
            (x (cond
                 ;; positional slot is a table-destructuring pattern
                 ;; (checked before (o ...) since `(o :keyword ...)` is a
                 ;; table entry, not a positional optional)
                 ((and (consp (car args)) (ac-table-pattern-p (car args)))
                  (ac-table-args (car args) slot-ra))
                 ((and (consp (car args)) (arc-sym= (caar args) "o"))
                  (ac-complex-opt (cadar args)
                                  (if (consp (cddar args)) (caddar args) nil)
                                  ra))
                 ;; (t var)         => (o var (the var))
                 ;; (t local var)   => (o local (the var))
                 ;; thread-local fallback: arg defaults to (the var) if
                 ;; the caller didn't supply one. See examples/the.arc.
                 ((and (consp (car args)) (arc-sym= (caar args) "t"))
                  (let* ((parms (cdar args))
                         (local (car parms))
                         (key (if (consp (cdr parms)) (cadr parms) local)))
                    (ac-complex-opt local
                                    (list (intern "the" (sym-pkg (caar args)))
                                          key)
                                    ra)))
                 (t (ac-complex-args (car args) slot-ra nil)))))
       (setf *env* (append (ac-complex-getargs x) *env*))
       (append x (ac-complex-args (cdr args)
                                  `(arc-xcdr ,ra)
                                  is-params))))
    (t (error "Can't understand fn arg list: ~S" args))))

(defun ac-complex-opt (var expr ra)
  (list (list var `(if (consp ,ra) (car ,ra) ,(ac expr)))))

;;; Table destructuring: (:a :b :c) at a param position binds locals
;;; a, b, c to the corresponding table entries.  Sub-forms supported:
;;;   :k              -- bind k to (tbl 'k)
;;;   :k var          -- remap: bind var to (tbl 'k)
;;;   :k pat          -- nested: destructure (tbl 'k) by pat
;;;   (o :k default)  -- bind k to (tbl 'k default)
;;;   (o :k var default) -- remap with default
;;; Both :foo and foo: read as the same CL keyword, so either spelling
;;; works on the key side.

(defun ac-table-opt-form-p (x)
  (and (consp x) (arc-sym= (car x) "o")
       (consp (cdr x)) (keywordp (cadr x))))

(defun ac-table-pattern-p (pat)
  "True if PAT is a table-destructuring pattern: a non-empty list whose
   first element is a keyword or (o :keyword ...) form."
  (and (consp pat)
       (or (keywordp (car pat))
           (ac-table-opt-form-p (car pat)))))

(defun ac-keyword->arc-sym (kw)
  "Convert a CL keyword like :A to the arc symbol arc::a used as a
   table key by `obj`."
  (arc-sym kw))

(defun ac-table-args (pat ra)
  "Generate let* bindings that destructure RA as a table according to
   the keyword pattern PAT."
  (let ((tbl (gensym "TBL")))
    (cons (list tbl ra)
          (ac-table-args-loop pat tbl))))

(defun ac-table-args-loop (pat tbl)
  (cond
    ((null pat) nil)
    ((keywordp (car pat))
     (let* ((key-sym (ac-keyword->arc-sym (car pat)))
            (rest    (cdr pat))
            (next    (and (consp rest) (car rest)))
            ;; A non-keyword, non-(o ...) element after a keyword is the
            ;; bind target (a symbol for remap, or a sub-pattern list).
            (has-target (and (consp rest)
                             (not (keywordp next))
                             (not (ac-table-opt-form-p next)))))
       (if has-target
           (append (ac-table-slot key-sym next nil tbl)
                   (ac-table-args-loop (cdr rest) tbl))
           (append (ac-table-slot key-sym key-sym nil tbl)
                   (ac-table-args-loop rest tbl)))))
    ((ac-table-opt-form-p (car pat))
     ;; (o :k)         -- bind k to (tbl 'k), no default
     ;; (o :k default) -- bind k with default if absent
     (let* ((entry   (car pat))
            (key-sym (ac-keyword->arc-sym (cadr entry)))
            (default (if (consp (cddr entry)) (caddr entry) nil)))
       (append (ac-table-slot key-sym key-sym default tbl)
               (ac-table-args-loop (cdr pat) tbl))))
    (t (error "Bad table-destructure element: ~S" (car pat)))))

(defun ac-table-lookup (tbl key-sym default)
  "CL expression that fetches KEY-SYM from TBL.  If DEFAULT is given,
   it's an arc expression evaluated lazily when the key is missing."
  (if default
      (let ((v (gensym "V")))
        `(let ((,v (gethash ',key-sym ,tbl :arc/missing)))
           (if (eq ,v :arc/missing) ,(ac default) ,v)))
      `(arc-call1 ,tbl ',key-sym)))

(defun ac-table-slot (key-sym target default tbl)
  "Bindings for one table slot: key KEY-SYM, value bound according to
   TARGET (a symbol or sub-pattern), with optional DEFAULT expression
   used lazily when the key is missing.  Sub-patterns dispatch back
   through ac-complex-args."
  (cond
    ((symbolp target)
     (list (list target (ac-table-lookup tbl key-sym default))))
    ((consp target)
     (let ((val (gensym "VAL")))
       (cons (list val (ac-table-lookup tbl key-sym default))
             (if (ac-table-pattern-p target)
                 (ac-table-args target val)
                 (ac-complex-args target val nil)))))
    (t (error "Bad table-destructure target: ~S" target))))

(defun ac-complex-getargs (a) (mapcar #'car a))

;;; Arc arglist -> list of symbols for env tracking
(defun ac-arglist (a)
  (cond
    ((null a) nil)
    ((and (symbolp a) (not (arc-sym= a "nil"))) (list a))
    ((and (symbolp (cdr a))
          (not (arc-sym= (cdr a) "nil")))
     (list (car a) (cdr a)))
    (t (cons (car a) (ac-arglist (cdr a))))))

(defun ac-body  (body) (mapcar #'ac body))
(defun ac-body* (body) (if (null body) '(nil) (ac-body body)))

;;;; ---- assign / set ----

(defun ac-set (x)
  `(progn ,@(ac-setn x)))

(defun ac-setn (x)
  (if (null x) nil
      (cons (ac-set1 (ac-macex (car x)) (cadr x))
            (ac-setn (cddr x)))))

;; True when B1 is (or macroexpands to) an fn form, so ac-set1 should
;; tell that fn the name it's being assigned to (for backtraces).
(defun ac-fn-value-p (b1)
  (arc-sym= (arc-car? b1) "fn"))

(defun ac-set1 (a b1)
  (if (symbolp a)
      (let* ((b1 (ac-macex b1))
             (b (let ((*env* (if (ac-fn-value-p b1)
                               (cons (list a) *env*)
                               *env*)))
                  (ac b1))))
        `(let ((zz ,b))
           ,(cond
              ((lex-p a)          `(setq ,a zz))
              ((arc-sym= a "nil") (error "Can't rebind nil"))
              ((arc-sym= a "t")   (error "Can't rebind t"))
              ;; Resolve the global to its cell now, at compile time, so
              ;; the assignment is a slot write instead of a hash store.
              (t `(setf (gcell-value ,(intern-gcell a)) zz)))
           zz))
      (error "First arg to assign must be a symbol: ~S" a)))

;;;; ---- call / macros ----

(defun ac-var-ref (s)
  (cond ((lex-p s) s)
        ((or (arc-sym= s "scope")
             (arc-sym= s "scope%"))
         (ac `(%scope ,*env*)))
        ;; Free reference: resolve to the global's cell at compile time and
        ;; embed the cell as a literal, so evaluating the reference is a
        ;; slot read.  The cell is interned even when S is still unbound --
        ;; forward references and recursive definitions are compiled before
        ;; the name exists -- and gcell-ref defers the existence check to
        ;; the moment the reference is actually evaluated.
        (t `(gcell-ref ,(intern-gcell s)))))

(defun lex-p (v) (member v *env* :test #'eq))

(xdef lex #'lex-p)

;; Compile the args of an immediately-applied fn ((fn PARAMS body) . ARGS).
;; An fn-valued arg is named after its (simple) param, so the value fn in
;; (let f (fn ...) ...) -- which expands to ((fn (f) ...) (fn ...)) -- is
;; named ...--f.  Other args (and complex/rest params) compile normally.
(defun ac-named-args (params args)
  (when args
    (let* ((p (and (consp params) (car params)))
           (a (car args)))
      (cons (if (and (symbolp p) (not (arc-sym= p "nil")) (ac-fn-value-p a))
                (let ((*env* (cons (list p) *env*))) (ac a))
                (ac a))
            (ac-named-args (and (consp params) (cdr params)) (cdr args))))))

(defun ac-call (fn args)
  (let ((macfn (ac-macro-p fn)))
    (cond
      (macfn (ac-mac-call macfn args))
      ((ac-fn-value-p fn)
       ;; funcall, not ((ac fn) ...): ac fn may be a named-lambda, which
       ;; is illegal in operator position but fine as a funcall argument.
       `(funcall ,(ac fn) ,@(ac-named-args (cadr fn) args)))
      ((= (length args) 0)
       `(arc-call0 ,(ac fn)))
      ((= (length args) 1)
       `(arc-call1 ,(ac fn) ,(ac (car args))))
      ((= (length args) 2)
       `(arc-call2 ,(ac fn) ,(ac (car args)) ,(ac (cadr args))))
      ((= (length args) 3)
       `(arc-call3 ,(ac fn) ,(ac (car args))
                   ,(ac (cadr args)) ,(ac (caddr args))))
      (t `(ar-apply ,(ac fn)
                    (list ,@(mapcar #'ac args)))))))

(defun ac-safe-call (fn args)
  (let ((macfn (ac-macro-p fn))
        (expr (cons fn args)))
    (cond
      (macfn (ac-mac-call macfn args))
      ((ac-fn-value-p fn)
       `(funcall ,(ac fn) ,@(ac-named-args (cadr fn) args)))
      (t `(ar-safe-apply ',expr ,(ac fn) (list ,@(mapcar #'ac args)))))))

(defun ac-mac-call (m args)
  (ac (apply m args)))

(defun ac-macro-p (fn)
  (when (symbolp fn)
    (let ((val (arc-global fn)))
      (when (and val (arc-tagged-p val)
                 (arc-sym= (arc-tagged-type val) "mac"))
        (arc-tagged-rep val)))))

(defun ac-macex (e &optional once)
  (if (consp e)
      (let ((m (ac-macro-p (car e))))
        (if m
            (let ((exp (apply m (cdr e))))
              (if once exp (ac-macex exp)))
            e))
      e))

(xdef macex  (e) (ac-macex e))
(xdef macex1 (e) (ac-macex e t))

(defun decompose (fns args)
  (cond
    ((null fns)  `((fn (vals) (car vals)) ,@args))
    ((null (cdr fns)) (cons (car fns) args))
    (t (list (car fns) (decompose (cdr fns) args)))))

(defun ac-gensym (x)
  (declare (ignore x))
  (gensym))

(defun ac-infix (s op)
  (let ((gs (mapcar #'ac-gensym (cdr s))))
    (ac `((fn ,gs
            (,op ,@(mapcar (lambda (f) `(,f ,@gs)) (cdar s))))
          ,@(cdr s)))))

(defun ac-andf (s) (ac-infix s 'and))

(defun ac-orf (s) (ac-infix s 'or))


;;;; ============================================================
;;;; Gensym
;;;; ============================================================

(defvar *arc-gensym-count* 0)
(defun arc-gensym (&optional (x 'gs))
  (incf *arc-gensym-count*)
  (arc-sym (format nil "~A~D" x *arc-gensym-count*)))

(xdef uniq #'arc-gensym)

;;;; ============================================================
;;;; Arc eval / load
;;;; ============================================================

(defun arc-eval (expr)
  (eval (ac expr)))

(xdef eval #'arc-eval)

(defun arc-load (filename)
  (with-open-file (p filename :direction :input
                              :element-type 'character
                              :external-format :utf-8)
    (let ((path (namestring (truename p)))
          (prev (arc-global '|script-file*|)))
      (setf (arc-global '|script-file*|) path)
      (unwind-protect
           (loop
             (let ((x (arc-read p nil :eof)))
               (when (eq x :eof) (return))
               (arc-eval x)))
        (setf (arc-global '|script-file*|) prev)))))

(xdef call-quietly (thunk)
  (handler-bind ((style-warning #'muffle-warning))
    (with-compilation-unit (:override t)
      (arc-call0 thunk))))

