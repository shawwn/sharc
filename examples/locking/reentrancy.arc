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

; the same lock acquired twice, nested.  Must use a real lock: lockable
; rejects a plain data table, so (w/lock h ...) would error "Not a lock".
(= mylock (make-lock 50 "example"))
(w/lock mylock (w/lock mylock (prn "same-lock nested w/lock: ok")))

; a complex = inside a dedicated lock.  The lock's level must be LOWER
; than place-lock*'s 40, because locks are acquired in increasing order:
; outer (10) then place-lock* (40) is legal, the reverse is not.  This is
; the intended use of w/lock, and the reason grouping mutations under a
; dedicated lock works while doing it under a data table's own lock does
; not.
(= outer (make-lock 10 "example-outer"))
(w/lock outer (= (h 'e) 5))
(prn "assignment under an outer lock: " (h 'e))

(prn "ALL OK")
