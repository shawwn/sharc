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
; No lock-order assert can catch this.  Nothing is acquired out of order;
; the bug is that B is not required to take a lock A holds at all, and an
; assert can only observe acquisitions that happen.  That is what makes an
; executable test the only way to see it.
;
; Expected TODAY: *** INTERLEAVED ***.
;
; NO KNOWN INSTANCE IN THE TREE.  An earlier version of this comment
; claimed init-user (news.arc) was vulnerable to load-prof's bare
; (= (profs* p!id) p) landing inside its atomic block.  That was wrong.
; load-prof only writes when (file-exists (prof-path it)), and both
; callers of init-user guard with (unless (profile u) ...), where profile
; checks memory and then disk.  So if the file exists init-user never
; runs, and if it does not exist load-prof writes nothing.  The one real
; invariant there, two concurrent init-user calls for the same new user,
; is already protected, because both racers take atomic.
;
; So this file documents a live hazard in the locking design rather than
; a live bug in news.arc.  It matters when converting any remaining
; atomic site: if you move a composite invariant onto its own lock, every
; other writer of that data has to take the same lock, or you get exactly
; this.  Re-check it after each conversion.

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
