#!./sharc

; Regression test for insert-items dropping concurrent submissions.
;
; insert-items used to read stories* outside place-lock* and assign it
; back inside:
;
;   (= stories* (merge-item-lists stories* items!story items!poll))
;
; expand= hoists the value expression out of the critical section, which
; is right for a plain = (there is no read of the *place*) and wrong
; here, because the value expression reads the place itself.  An
; (add-item s stories*) landing during the merge was correctly locked and
; still lost: the assignment that followed wrote back a list computed
; before the push.
;
; The submitted story survived in items*, on disk, and on the front page
; via ranked-stories*, so the symptom looked like a display bug: it never
; appeared on /newest or /newcomments until restart.
;
; This is not a rare interleaving.  w/loading-items runs insert-items on
; any request that lazily loads an item, including commentlink's
; (w/loading-items (- (visible-family i) 1)) once per story per
; front-page render.  "Someone submits while someone else loads a page"
; is the whole trigger.
;
; Before the fix this dropped about 170 of the 200 submissions below.
; The ratio is an artifact of the tuning here (a merge over 4000 items
; takes far longer than the 1ms between pushes); production loses a
; submission only when one lands inside a merge, which is why the bug
; survived so long.
;
; Expected: "dropped 0 of 200" / "OK: no dropped submissions".

(load "news.arc")

(= nseed*   4000    ; enough that one merge takes real time
   npush*    200 
   nmerge*   200)

; A plausible stories*: item tables in descending id order.
(= stories* (map [inst 'item 'id _ 'type 'story]
                 (rev (range 1 nseed*))))

(= pushed* nil t1done* nil t2done* nil)

; Thread A: the reader side.  Re-inserting an item already in stories*
; keeps the list length stable, so every merge does the same work.
(thread
  (let i (car stories*)
    (repeat nmerge*
      (insert-items (list i))
      (sleep 0.001)))
  (= t1done* t))

; Thread B: the submitter side, exactly what submit-story does.
(thread
  (for n 1 npush*
    (let s (inst 'item 'id (+ nseed* n) 'type 'story)
      (add-item s stories*)
      (push s!id pushed*))
    (sleep 0.001))
  (= t2done* t))

(while (no (and t1done* t2done*)) (sleep 0.05))

(let present (table)
  (each s stories* (set (present s!id)))
  (let lost (rem present pushed*)
    (prn "dropped " (len lost) " of " npush*)
    (if lost
        (prn "*** DROPPED SUBMISSIONS: " (firstn 10 lost) " ...")
        (prn "OK: no dropped submissions"))))
