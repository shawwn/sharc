#!./sharc

; Sanity check: place-lock* and table locks are re-entrant.
;
; SBCL's synchronized hash table lock is recursive
; (sb-thread::call-with-recursive-lock), so a complex `=` nested inside
; another complex `=`, and (w/lock h (w/lock h ...)), must not
; self-deadlock. atomic-invoke gets its re-entrancy separately, via the
; *arc-atomic-owner* check.
;
; Expected: prints ALL OK.  A hang means re-entrancy regressed.

(= h (table))

(= (h 'a) 1)
(prn "simple complex-place =: " (h 'a))

; an inner complex = evaluated while the outer lock is already held
(= (h 'b) (do (= (h 'c) 3) 2))
(prn "nested complex =: b=" (h 'b) " c=" (h 'c))

; explicit w/lock, then a complex = re-entering the same lock
(w/lock place-lock* (= (h 'd) 4))
(prn "w/lock + inner =: " (h 'd))

; the same table locked twice
(w/lock h (w/lock h (prn "same-table nested w/lock: ok")))

(prn "ALL OK")
