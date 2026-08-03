#!./sharc

; Regression test for the "already holds *arc-mutex*, so skip
; place-lock*" short circuit.
;
; Skipping a lock you already hold is fine, and atomic-invoke still does
; exactly that for re-entrancy.  Skipping lock B because you hold lock A
; is a different claim, and it is only sound if every acquirer of B also
; holds A.  That is false here: the bare (++ (h 'n)) below takes
; place-lock* and never touches *arc-mutex* at all, so the two threads
; end up on different locks and interleave.
;
; With the short circuit in place this loses roughly 880 of 60000
; increments.
;
; Expected: "expected 60000, got 60000" / "OK: no lost updates".

(= h (table))
(= (h 'n) 0)
(= iters 30000)
(= t1done nil t2done nil)

(thread (repeat iters (atomic (++ (h 'n)))) (= t1done t))  ; inside atomic
(thread (repeat iters (++ (h 'n)))          (= t2done t))  ; bare

(while (no (and t1done t2done)) (sleep 0.05))

(prn "expected " (* 2 iters) ", got " (h 'n))
(if (is (h 'n) (* 2 iters))
    (prn "OK: no lost updates")
    (prn "*** LOST UPDATES: " (- (* 2 iters) (h 'n)) " ***"))
