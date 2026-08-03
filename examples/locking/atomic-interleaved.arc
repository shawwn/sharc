#!./sharc

; Composite invariants guarded by `atomic` are no longer atomic against
; bare place operations, because the two now use different locks.
;
; Before the split, `atomic` and `=` both took *arc-mutex*, so an atomic
; block excluded everything.  Now it excludes only other atomic blocks:
; holding *arc-mutex* does not stop anyone from taking place-lock*.
;
; Thread A below does all of its writes inside ONE atomic block and
; checks its own invariant before releasing.  Thread B does a single bare
; assignment and never touches *arc-mutex*, so it runs straight through
; the middle of A's block.  Note that A did nothing wrong; it used atomic
; exactly as intended and still got torn.
;
; This is the shape of a real bug in the tree: init-user (news.arc) holds
; *arc-mutex* but releases place-lock* between its inner writes, so
; load-prof's bare (= (profs* p!id) p) can land inside it and clobber a
; profile that init-user just created.  Its save-prof then persists the
; wrong one.
;
; No lock-order assert can catch this.  Nothing is acquired out of order;
; the bug is that B is not required to take a lock A holds at all, and an
; assert can only observe acquisitions that happen.
;
; Expected TODAY: *** INTERLEAVED ***.
;
; This is the acceptance test for users-lock*.  Once every access to a
; shared structure takes one common lock, this should print
; "OK: atomic block was not interleaved".

(= h (table))
(= (h 'a) 0 (h 'b) 0)
(= broke nil stop nil)

; A: maintains the invariant "(h 'a) equals (h 'b)", all inside atomic
(= ta (thread
  (until stop
    (atomic (= (h 'a) 1)
            (= (h 'b) 1)
            (unless (is (h 'a) (h 'b)) (= broke t))))))

; B: one bare place op, no atomic, so it never blocks on *arc-mutex*
(= tb (thread
  (until stop
    (= (h 'a) 99))))

(sleep 2)
(= stop t)
(sleep 0.3)

(if broke
    (prn "*** INTERLEAVED: another thread wrote inside A's atomic block ***")
    (prn "OK: atomic block was not interleaved"))
