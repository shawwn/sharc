;;;; setup.lisp  --  load ironclad from ./lib without Quicklisp.

(require :asdf)

;; SBCL contribs. ASDF can usually find these itself, but requiring
;; them explicitly costs nothing and removes a failure mode.
#+sbcl (require :sb-rotate-byte)
#+sbcl (require :sb-posix)

(let ((here (uiop:pathname-directory-pathname *load-truename*)))
  (asdf:initialize-source-registry
   `(:source-registry
     :ignore-inherited-configuration
     (:tree ,(merge-pathnames "lib/" here))
     (:directory ,here))))

(asdf:load-system "ironclad/core")
