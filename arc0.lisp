;;; arc0.lisp -- Arc runtime for Common Lisp (SBCL)

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

;;;; ============================================================
;;;; Global variable table  (key = lowercase string)
;;;; ============================================================

(defvar *arc-globals*       (make-hash-table :test #'equal :synchronized t))
(defvar *arc-fn-signatures* (make-hash-table :test #'equal :synchronized t))

(defun arc-global (s)
  (gethash (arc-sym-key s) *arc-globals*))

(defun (setf arc-global) (val s)
  (setf (gethash (arc-sym-key s) *arc-globals*) val))

(defun arc-bound-p (s)
  (nth-value 1 (gethash (arc-sym-key s) *arc-globals*)))

(defun arc-global-ref (s)
  (multiple-value-bind (v present) (gethash (arc-sym-key s) *arc-globals*)
    (if present v (error "Unbound variable: ~A" s))))

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
(defvar *arc-direct-calls*  nil)
(defvar *arc-explicit-flush* nil)

(xdef sig *arc-fn-signatures*)

(defun arc-declare (key val)
  (let ((flag (not (null val)))
        (k (string-downcase (symbol-name key))))
    (cond ((string= k "atstrings")      (setf *arc-atstrings*      flag))
          ((string= k "direct-calls")   (setf *arc-direct-calls*   flag))
          ((string= k "explicit-flush") (setf *arc-explicit-flush* flag)))
    val))

(xdef declare #'arc-declare)

;;;; ============================================================
;;;; Funcall helpers
;;;; ============================================================

(defun ar-apply-args (args)
  (cond
    ((null args) nil)
    ((null (cdr args)) (car args))
    (t (cons (car args) (ar-apply-args (cdr args))))))

(defun ar-apply (fn args)
  (cond
    ((functionp fn)  (apply fn args))
    ((consp fn)      (nth (car args) fn))
    ((stringp fn)    (char fn (car args)))
    ((hash-table-p fn)
     (let ((v (gethash (car args) fn :arc/missing)))
       (if (eq v :arc/missing)
           (if (cdr args) (cadr args) nil)
           v)))
    ((vectorp fn)    (aref fn (car args)))
    (t (error "Function call on non-function: ~S" fn))))

(defun arc-apply (fn &rest args)
  (ar-apply fn (ar-apply-args args)))

(xdef apply #'arc-apply)

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
  (or (eql a b)
      (and (numberp a) (numberp b) (= a b))
      (and (stringp a) (stringp b) (string= a b))
      (and (null a) (null b))))

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

(xdef > (&rest args) (pairwise #'arc->2 args))

(defun arc-<2 (x y)
  (tnil (cond ((and (numberp x) (numberp y)) (< x y))
              ((and (stringp x) (stringp y)) (string< x y))
              ((and (symbolp x) (symbolp y))
               (string< (symbol-name x) (symbol-name y)))
              ((and (characterp x) (characterp y)) (char< x y))
              (t (< x y)))))

(xdef < (&rest args) (pairwise #'arc-<2 args))

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
    ((arc-tagged-p x)                  (arc-tagged-type x))
    ((consp x)                         (intern "cons"    :arc))
    ((null x)                          (intern "sym"     :arc))
    ((symbolp x)                       (intern "sym"     :arc))
    ((functionp x)                     (intern "fn"      :arc))
    ((characterp x)                    (intern "char"    :arc))
    ((stringp x)                       (intern "string"  :arc))
    ((and (integerp x) (= x (truncate x))) (intern "int" :arc))
    ((numberp x)                       (intern "num"     :arc))
    ((hash-table-p x)                  (intern "table"   :arc))
    ((and (streamp x) (output-stream-p x)) (intern "output" :arc))
    ((and (streamp x) (input-stream-p x))  (intern "input"  :arc))
    ((typep x 'sb-thread:thread)       (intern "thread"  :arc))
    ((vectorp x)                       (intern "vector"  :arc))
    (t (error "Unknown type: ~S" x))))

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
          :element-type 'character
          :external-format :latin-1))

(xdef infile-binary (f)
  (open f :direction :input
          :element-type '(unsigned-byte 8)))

(xdef outfile (f &rest args)
  (open f :direction :output
          :element-type 'character
          :external-format :latin-1
          :if-exists (if (equal (car args) "append") :append :supersede)
          :if-does-not-exist :create))

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

(defun arc-disp-val (x port)
  (cond
    ((stringp x)    (write-string x port))
    ((characterp x) (write-char x port))
    ((null x)       nil)
    ((symbolp x)    (write-string (symbol-name x) port))
    ((typep x 'double-float) (format port "~F" x))
    ((consp x)
     (write-char #\( port)
     (arc-disp-val (car x) port)
     (let ((rest (cdr x)))
       (loop while rest do
         (cond
           ((consp rest)
            (write-char #\space port)
            (arc-disp-val (car rest) port)
            (setf rest (cdr rest)))
           (t
            (write-string " . " port)
            (arc-disp-val rest port)
            (setf rest nil)))))
     (write-char #\) port))
    (t (write x :stream port :readably nil))))

(defun arc-write-val (x port)
  (cond
    ((stringp x)    (write x :stream port))  ; quoted
    ((characterp x) (write x :stream port))
    ((null x)       (write-string "nil" port))
    ((eq x t)       (write-string "t" port))
    ((symbolp x)    (write-string (symbol-name x) port))
    ((consp x)
     (write-char #\( port)
     (arc-write-val (car x) port)
     (let ((rest (cdr x)))
       (loop while rest do
         (cond
           ((consp rest)
            (write-char #\space port)
            (arc-write-val (car rest) port)
            (setf rest (cdr rest)))
           (t
            (write-string " . " port)
            (arc-write-val rest port)
            (setf rest nil)))))
     (write-char #\) port))
    (t (write x :stream port :readably nil))))

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

(defun arc-coerce (x type &optional radix)
  (let ((tname (string-downcase
                (if (symbolp type) (symbol-name type) (string type)))))
    (cond
      ((arc-tagged-p x) (error "Can't coerce annotated object"))
      ((string= tname (string-downcase (symbol-name (arc-type x)))) x)
      ((characterp x)
       (cond ((string= tname "int")    (char-code x))
             ((string= tname "string") (string x))
             ((string= tname "sym")    (intern (string x) :arc))
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
       (cond ((string= tname "sym")    (intern x :arc))
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
             (t (error "Can't coerce sym ~S to ~S" x type))))
      ;; a non-string vector (e.g. a byte vector) -> its elements as a
      ;; list; for a byte vector that's a list of ints in [0..255]
      ((vectorp x)
       (cond ((string= tname "cons") (coerce x 'list))
             (t (error "Can't coerce vector ~S to ~S" x type))))
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
           (stream (sb-bsd-sockets:socket-make-stream
                    client :input t :output t
                    :element-type :default
                    :external-format :latin-1
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
;;;
;;;   (http-fetch url [opts])
;;;     HTTP request; returns the response body as a string.
;;;     Signals an error on non-2xx status.
;;;     opts is an optional table:
;;;       method   -- HTTP method (default "GET")
;;;       headers  -- alist of ("Header-Name" "value") pairs
;;;       body     -- request body string
;;;       noverify -- skip certificate verification
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
              (progn (setf (ssl-stream-read-buf s) ""
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

(defun tcp-connect (host port)
  "Open a TCP connection, return the raw socket."
  (let* ((addr (sb-bsd-sockets:host-ent-address
                (sb-bsd-sockets:get-host-by-name host)))
         (sock (make-instance 'sb-bsd-sockets:inet-socket
                              :type :stream :protocol :tcp)))
    (sb-bsd-sockets:socket-connect sock addr port)
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
     noverify -- skip certificate verification"
  (let* ((ssl-p (or (arc-opt opts "ssl") (= port 443)))
         (noverify (arc-opt opts "noverify"))
         (sock (tcp-connect host port)))
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

(defun http-parse-response (raw)
  "Split an HTTP response into (values status-code headers body)."
  (let* ((header-end (search (format nil "~C~C~C~C"
                                     #\return #\newline #\return #\newline)
                             raw))
         (header-str (subseq raw 0 header-end))
         (body (subseq raw (+ header-end 4)))
         (first-line-end (position #\return header-str))
         (status-line (subseq header-str 0 first-line-end))
         ;; "HTTP/1.1 200 OK" -> 200
         (status-code (parse-integer status-line :start 9 :end 12)))
    (values status-code header-str body)))

(defun arc-http-fetch (url &optional opts)
  "Fetch URL via HTTP. Returns the response body as a string.
   OPTS is an Arc table with optional keys:
     method   -- HTTP method (default \"GET\")
     headers  -- alist of (name value) string pairs
     body     -- request body string
     noverify -- skip SSL certificate verification"
  (multiple-value-bind (host port path use-ssl) (parse-url url)
    (let* ((method  (or (arc-opt opts "method") "GET"))
           (hdrs    (arc-opt opts "headers"))
           (reqbody (arc-opt opts "body"))
           (sock-opts (when (arc-opt opts "noverify")
                        (let ((h (make-hash-table :test #'equal :synchronized t)))
                          (setf (gethash (arc-sym "noverify") h) t)
                          h)))
           (stream  (arc-socket-connect host port
                      (if use-ssl
                          (or sock-opts
                              (let ((h (make-hash-table :test #'equal :synchronized t)))
                                (setf (gethash (arc-sym "ssl") h) t)
                                h))
                          sock-opts))))
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
             ;; Read response
             (let ((raw (with-output-to-string (buf)
                          (loop for c = (read-char stream nil nil)
                                while c do (write-char c buf)))))
               (multiple-value-bind (code headers body)
                   (http-parse-response raw)
                 (declare (ignore headers))
                 (unless (<= 200 code 299)
                   (error "HTTP ~D from ~A" code url))
                 body)))
        (close stream)))))

(xdef http-fetch (url &rest args)
  (arc-http-fetch url (car args)))

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

(xdef dead (th) (tnil (not (sb-thread:thread-alive-p th))))

(xdef sleep (n) (sleep n) nil)

;;;; ---- atomic-invoke ----

(defvar *arc-mutex* (sb-thread:make-mutex :name "arc"))
(defvar *arc-atomic-owner* nil)

(xdef atomic-invoke (f)
  (if (eq sb-thread:*current-thread* *arc-atomic-owner*)
      (arc-call0 f)
      (sb-thread:with-mutex (*arc-mutex*)
        (let ((*arc-atomic-owner* sb-thread:*current-thread*))
          (arc-call0 f)))))

;;;; ============================================================
;;;; System calls
;;;; ============================================================

(xdef system (cmd)
  (let* ((proc (sb-ext:run-program "/bin/sh" (list "-c" cmd)
                                   :output :stream :wait nil))
         (out  (sb-ext:process-output proc)))
    (loop for c = (read-char out nil nil)
          while c do (write-char c *standard-output*))
    (sb-ext:process-wait proc))
  nil)

(xdef pipe-from (cmd)
  ;; :external-format :latin-1 so each byte from the subprocess becomes
  ;; one Arc char.  Matches the file I/O defaults (see infile/outfile)
  ;; and keeps UTF-8 subprocess output round-trippable through Latin-1
  ;; files (each byte preserved literally).
  (sb-ext:process-output
   (sb-ext:run-program "/bin/sh" (list "-c" cmd)
                       :output :stream :wait nil
                       :external-format :latin-1)))

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

(xdef rand (&optional n)
  (if n (random n)
      (random 1.0d0)))

(let ((urandom-stream nil))
  (xdef randb ()
    (unless urandom-stream
      (setf urandom-stream
            (open "/dev/urandom"
                  :element-type '(unsigned-byte 8)
                  :direction :input)))
    (read-byte urandom-stream)))

(xdef dir (name)
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
     (mapcar (lambda (p) (car (last (pathname-directory p))))
             subdirs))))

(xdef file-exists (name) (if (probe-file name) name nil))

(xdef dir-exists (name)
  (let ((p (probe-file name)))
    (if (and p (cl:pathname-name p) (string= (cl:pathname-name p) ""))
        nil
        (if (and p (null (pathname-name p))) name nil))))

(xdef rmfile (name) (delete-file name) nil)

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

(xdef ssyntax  (x) (tnil (ssyntax-p x)))
(xdef ssexpand (x) (if (ssyntax-p x) (expand-ssyntax x) x))

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

(defvar *arc-last-err* nil)

(defun arc-report-error (c &optional (stream *error-output*))
  (setf *arc-last-err* c)
  (format stream "Error: ~A~%" c)
  (format stream "Backtrace for: ~A~%" sb-thread:*current-thread*)
  (let ((i 0)
        (count 30)
        (stop nil))
    (sb-debug:map-backtrace
     (lambda (frame)
       (when (and (not stop) (< i count))
         ;; Print frames under :invert readtable case so mixed-case
         ;; symbol names (like arc--CAR) come out without |...| escapes.
         ;; All-lowercase and all-uppercase names still print in their
         ;; canonical form; only mixed-case ones change.
         (let ((text (with-output-to-string (s)
                       (let ((*print-pretty* nil)
                             (*readtable* (copy-readtable *readtable*)))
                         (setf (readtable-case *readtable*) :invert)
                         (sb-debug::print-frame-call frame s :number nil)))))
           (format stream "~D: ~A~%" i text)
           (incf i)
           (let ((name (sb-di:debug-fun-name (sb-di:frame-debug-fun frame))))
             (when (and (symbolp name)
                        (string= (symbol-name name) "ARC-BOOT"))
               (setf stop t))))))))
  (terpri stream)
  (force-output stream))

(defun arc-tl ()
  (format t "Use (quit) to quit, (arc:arc-tl) to return here after an interrupt.~%")
  (arc-tl2))

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
             (arc-write-val val *standard-output*)
             (terpri)
             (setf (arc-global '|that|)     val)
             (setf (arc-global '|thatexpr|) expr)))))))
  (arc-tl2))

