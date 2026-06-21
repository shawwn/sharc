;;;; sbcl --script boot.lisp [file...]
;;;;
;;;; Arc bootstrap entry point -- equivalent of arc3.2/as.scm. Loads
;;;; the Arc runtime (arc.arc + libs.arc), then dispatches:
;;;;   * file args:        run each as a script and exit
;;;;   * stdin not a tty:  read/eval all expressions from stdin and exit
;;;;   * otherwise:        drop into the Arc REPL

(load (merge-pathnames "arc1.lisp" *load-pathname*))
(load (merge-pathnames "sha1.lisp" *load-pathname*))
(load (merge-pathnames "bcrypt.lisp" *load-pathname*))

(defun arc-verbose-p ()
  (let ((v (uiop:getenv "ARC_VERBOSE")))
    (and v (not (string= v "")) (not (string= v "0")))))

(defmacro arc-vlog (&rest args)
  `(when (arc-verbose-p) (format t ,@args) (force-output)))

(defun arc-boot-dir ()
  (let ((env (uiop:getenv "ARC_DIR")))
    (if (and env (not (string= env "")))
        env
        (namestring (uiop:pathname-directory-pathname *load-pathname*)))))

(defun arc-load-stdin ()
  (loop
    (let ((expr (arc:arc-read *standard-input* nil :eof)))
      (when (eq expr :eof) (return))
      (arc:arc-eval expr))))

(defun arc-boot (&key arc-dir files)
  (unless arc-dir (setf arc-dir (arc-boot-dir)))
  (let ((*default-pathname-defaults* (pathname arc-dir)))
    (arc-vlog "Loading arc.arc...~%")
    (arc:arc-load (merge-pathnames "arc.arc" arc-dir))
    (arc-vlog "Loading libs.arc...~%")
    (arc:arc-load (merge-pathnames "libs.arc" arc-dir))
    (setf (arc::arc-global 'arc::|main-file*|) nil)
    (when files
      (setf (arc::arc-global 'arc::|main-file*|)
            (namestring (truename (car (last files))))))
    (cond (files
           (dolist (f files) (arc:arc-load f))
           (uiop:quit 0))
          ((not (interactive-stream-p *standard-input*))
           (arc-load-stdin)
           (uiop:quit 0))
          (t
           (arc-vlog "Arc ready.~%")
           (arc:arc-tl)))))

(arc-boot :arc-dir (arc-boot-dir)
          :files (cdr sb-ext:*posix-argv*))
