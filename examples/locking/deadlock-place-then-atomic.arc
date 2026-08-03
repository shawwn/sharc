#!./sharc

; Lock-order violation: place-lock* (level 40) taken first, then
; *arc-mutex* (level 0).
;
; expand= evaluates the value expression INSIDE place-lock*, because
; placewiths wraps the whole (withs binds ... setter) form.  So any
; assignment whose value reaches `atomic` inverts the hierarchy.  The two
; threads below take the two locks in opposite orders; the sleeps are not
; load-bearing, they just make a rare race deterministic.
;
; Before lock levels existed this deadlocked outright.
;
; Expected TODAY: "Lock order violation: acquiring *arc-mutex* (level 0)
; while holding level 40".  That is the assert doing its job, but the
; edge still exists.  Hoisting the binds and the value expression out of
; the critical section is what eliminates it, and when that lands this
; file should print NO DEADLOCK with no violation reported.

(= h (table))
(= done1 nil done2 nil)

; holds *arc-mutex*, then wants place-lock*  (0 -> 40, legal)
(thread (atomic (sleep 0.3) (= (h 'a) 1)) (= done1 t))

; holds place-lock*, then wants *arc-mutex*  (40 -> 0, VIOLATION)
(thread (= (h 'b) (do (sleep 0.3) (atomic 2))) (= done2 t))

(sleep 3)
(prn "done1=" done1 "  done2=" done2)
(if (and done1 done2)
    (prn "NO DEADLOCK")
    (prn "*** DEADLOCK or lock-order error: both threads did not finish ***"))
