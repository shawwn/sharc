#!./sharc

; Lock-order violation: a data table's own lock (level 99, a leaf) taken
; via w/lock, then place-lock* (level 40) underneath it.
;
; Every arc table is :synchronized t, so each one already carries a lock
; that is taken implicitly on every read and write.  Those implicit
; acquisitions are always leaves and never cause trouble.  w/lock on a
; data table is what makes one explicit and holds it across other work,
; and then any assignment inside the body wants place-lock* beneath it.
;
; The practical conclusion is that w/lock on a data table is close to
; unusable: the hierarchy forbids doing anything inside it.  Keeping
; w/place-lock internal and not exposing the general w/lock form would
; close this off.
;
; Expected: "Lock order violation: acquiring table lock (level 40) while
; holding level 99".

(= h (table))
(= g (table))
(= done1 nil done2 nil)

; holds h's lock (99), then wants place-lock* (40)  -- VIOLATION
(thread (w/lock h (sleep 0.3) (= (g 'a) 1)) (= done1 t))

; holds place-lock* (40), then h's lock via sref (99)  -- legal
(thread (= (h 'b) (do (sleep 0.3) 2)) (= done2 t))

(sleep 3)
(prn "done1=" done1 "  done2=" done2)
(if (and done1 done2)
    (prn "NO DEADLOCK")
    (prn "*** DEADLOCK or lock-order error: both threads did not finish ***"))
