; JSON encoder + decoder.
;
;   (as-json x)             ; return x as a JSON string
;   (to-json x)             ; print x as JSON to current stdout
;   (to-json x nil stream)  ; print x as JSON to `stream`
;   (to-json x t stream)    ; pretty-print, indenting with two spaces
;   (to-json x 4 stream)    ; pretty-print, indenting with four spaces
;   (to-json x "\t" stream) ; pretty-print, indenting with a string
;   (save-json x path) ; write x as JSON to a file (atomic via .tmp)
;   (from-json s)      ; parse string s into Arc values
;   (load-json path)   ; parse a JSON file
;
; Decoded shapes:
;   JSON null  -> nil
;   JSON true  -> t
;   JSON false -> nil
;   JSON int   -> int
;   JSON num   -> num
;   JSON str   -> string
;   JSON array -> Arc list
;   JSON obj   -> Arc table keyed by symbols
;
; Encoder accepts those shapes plus Arc chars (encoded as 1-char strings)
; and anything else (encoded via `string`).  Object keys are sorted so
; output is deterministic.


; ----- Encoder -----

; `pretty` controls indentation: nil (the default) produces compact
; output; t indents each level by two spaces; an int indents by that
; many spaces; a string is used verbatim as the per-level indent.

(def to-json (x (o pretty) (o stream (stdout)))
  (w/stdout stream (json-write x (json-indent-step pretty) "")))

(def as-json (x (o pretty))
  (tostring (to-json x pretty)))

(def json-indent-step (pretty)
  (if (no pretty)         nil
      (is pretty t)       "  "
      (isa!int pretty)    (newstring pretty #\space)
                          pretty))

; `step` is the per-level indent string (nil for compact output) and
; `ind` is the indentation accumulated so far.

(def json-write (x (o step) (o ind ""))
  (if (in x nil 'null) (pr "null")
      (in x t 'true)   (pr "true")
      (is x 'false)    (pr "false")
      (is x 'empty)    (pr "[]")
      (isa!int x)      (pr x)
      (isa!num x)      (pr x)
      (isa!string x)   (json-write-string x)
      (isa!sym x)      (json-write-string (string x))
      (isa!char x)     (json-write-string (string x))
      (isa!table x)    (json-write-object x step ind)
      (acons x)        (json-write-array x step ind)
                       (json-write-string (string x))))

(def json-write-string (s)
  (pr "\"")
  (each c s
    (let n (coerce c 'int)
      (case c
        #\"        (pr "\\\"")
        #\\        (pr "\\\\")
        #\newline  (pr "\\n")
        #\return   (pr "\\r")
        #\tab      (pr "\\t")
                   (if (< n 32)
                       (pr (string "\\u00"
                                   ("0123456789abcdef" (trunc (/ n 16)))
                                   ("0123456789abcdef" (mod n 16))))
                       (writec c)))))
  (pr "\""))

(def json-write-array (xs (o step) (o ind ""))
  (if (no xs)
      (pr "[]")
      (let ind2 (and step (+ ind step))
        (pr "[")
        (let first t
          (each x xs
            (if first (= first nil) (pr ","))
            (json-newline step ind2)
            (json-write x step ind2)))
        (json-newline step ind)
        (pr "]"))))

(def json-write-object (h (o step) (o ind ""))
  (if (empty h)
      (pr "{}")
      (let ind2 (and step (+ ind step))
        (pr "{")
        (let first t
          (each k (sort json-key-order (keys h))
            (if first (= first nil) (pr ","))
            (json-newline step ind2)
            (json-write-string (string k))
            (pr (if step ": " ":"))
            (json-write (h k) step ind2)))
        (json-newline step ind)
        (pr "}"))))

; In pretty mode, break the line and emit the current indentation;
; in compact mode (step nil) this is a no-op.

(def json-newline (step ind)
  (when step
    (writec #\newline)
    (pr ind)))

(def json-key-order (a b)
  (< (string a) (string b)))

(def save-json (x file (o pretty))
  (let tmp (+ file ".tmp")
    (w/outfile o tmp (to-json x pretty o))
    (mvfile tmp file))
  x)


; ----- Decoder -----
;
; Parser state lives in a table so we don't have to thread state through
; every recursion.

(def from-json (s)
  (let st (obj src s pos 0 n (len s))
    (json-ws st)
    (json-parse st)))

(def load-json (file)
  (errsafe (from-json (filechars file))))

(def json-peek (st)
  (and (< st!pos st!n)
       (st!src st!pos)))

(def json-bump (st) (= st!pos (+ st!pos 1)))

(def json-ws (st)
  (catch
    (whilet c (json-peek st)
      (if (whitec c) (json-bump st) (throw)))))

(def json-parse (st)
  (json-ws st)
  (let c (json-peek st)
    (if (no c)         nil
        (is c #\{)     (json-parse-object st)
        (is c #\[)     (json-parse-array st)
        (is c #\")     (json-parse-string st)
        (is c #\t)     (do (= st!pos (+ st!pos 4)) t)
        (is c #\f)     (do (= st!pos (+ st!pos 5)) nil)
        (is c #\n)     (do (= st!pos (+ st!pos 4)) nil)
                       (json-parse-number st))))

(def json-parse-object (st)
  (json-bump st)                                  ; consume {
  (let rec (table)
    (json-ws st)
    (if (is (json-peek st) #\})
        (do (json-bump st) rec)
        (do (catch
              (while t
                (json-ws st)
                (let k (json-parse-string st)
                  (json-ws st)
                  (when (is (json-peek st) #\:) (json-bump st))
                  (json-ws st)
                  (let v (json-parse st)
                    (= (rec (sym k)) v)
                    (json-ws st)
                    (case (json-peek st)
                      #\, (json-bump st)
                      #\} (do (json-bump st) (throw))
                          (throw))))))
            rec))))

(def json-parse-array (st)
  (json-bump st)                                  ; consume [
  (let acc nil
    (json-ws st)
    (if (is (json-peek st) #\])
        (do (json-bump st) nil)
        (do (catch
              (while t
                (json-ws st)
                (let v (json-parse st)
                  (push v acc)
                  (json-ws st)
                  (case (json-peek st)
                    #\, (json-bump st)
                    #\] (do (json-bump st) (throw))
                        (throw)))))
            (rev acc)))))

(def json-parse-string (st)
  (json-bump st)                                  ; consume opening "
  (tostring
    (catch
      (whilet c (json-peek st)
        (if (is c #\")
            (do (json-bump st) (throw))
            (is c #\\)
            (do (json-bump st)
                (let e (json-peek st)
                  (json-bump st)
                  (case e
                    #\" (writec #\")
                    #\\ (writec #\\)
                    #\/ (writec #\/)
                    #\n (writec #\newline)
                    #\r (writec #\return)
                    #\t (writec #\tab)
                    #\b (writec (coerce 8 'char))
                    #\f (writec (coerce 12 'char))
                    #\u (writec (json-parse-unicode-escape st))
                        (writec e))))
            (do (writec c) (json-bump st)))))))

(def json-parse-unicode-escape (st)
  (let n 0
    (repeat 4
      (let c (json-peek st)
        (json-bump st)
        (= n (+ (* n 16) (json-hex-digit c)))))
    (coerce n 'char)))

(def json-hex-digit (c)
  (let i (only&int c)
    (if (no i)
         0
        (<= i (int #\9))
         (- i (int #\0))
        (<= i (int #\F))
         (+ 10 (- i (int #\A)))
         (+ 10 (- i (int #\a))))))

(def json-parse-number (st)
  (let start st!pos
    (catch
      (whilet c (json-peek st)
        (if (or (digit c) (is c #\-) (is c #\+) (is c #\.) (is c #\e) (is c #\E))
            (json-bump st)
            (throw))))
    (let s (cut st!src start st!pos)
      (or (errsafe:int s)
          (errsafe:coerce s 'num)
          0))))
