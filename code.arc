; Code analysis. Spun off 21 Dec 07.

; Ought to do more of this in Arc.  One of the biggest advantages
; of Lisp is messing with code.

(def codelines (file)
  (w/infile in file
    (summing test
      (whilet line (readline in)
        (test (aand (find nonwhite line) (isnt it #\;)))))))

(def codeflat (file)
  (len (flat (readall (infile file)))))

(def codetree (file)
  (treewise + (fn (x) 1) (readall (infile file))))

(def code-density (file)
  (/ (codetree file) (codelines file))) 

(def tokcount ((o files loaded-files*))
  (lets counts (table)
    (each f files
      (each token (flat (readall (infile f)))
        (++ (counts token 0))))))

(def common-tokens ((o files loaded-files*))
  (let counts (tokcount files)
    (sort (compare > cadr)
          (each (k v) counts
            (unless (nonop k) (out k v))))))

(def nonop (x)
  (in x 'quote 'unquote 'quasiquote 'unquote-splicing))

(def common-operators ((o files loaded-files*))
  (keep [isa!sym&bound (car _)] (common-tokens files)))

(def top40 (xs)
  (map prn (firstn 40 xs))
  t)

(def space-eaters ((o files loaded-files*))
  (let counts (tokcount files)
    (sort (compare > last)
          (each (k v) counts
            (when (and (isa!sym k) (bound k))
              (out k v (* (len (string k)) v)))))))

;(top40:space-eaters)

(mac flatlen args `(len (flat ',args)))
