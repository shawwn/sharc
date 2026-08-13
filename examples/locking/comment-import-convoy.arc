#!./sharc

; Reproduces the rank-lock* convoy captured in a live image on
; 2026-08-13, where lockdump showed:
;
;   === held locks ===
;     rank-lock* held by scrape-stories-p1
;   === threads ===
;     scrape-stories-p2-p3      WAITING on rank-lock*
;     scrape-remaining-stories  WAITING on rank-lock*
;   === wait chains ===
;     ((scrape-stories-p2-p3 -> rank-lock*) (scrape-stories-p1 running))
;
; No cycle, no lock-order violation, no thread-deadlock from SBCL: the
; holder is *running*.  This is not a deadlock, it is oversubscription.
;
; import-scraped-comments (scrape.arc) loops over every comment of a
; story and calls (put-item it comments*) once per comment.  put-item is
;
;   (w/lock rank-lock* (= comments* (reinsert-sorted ...)))
;
; and reinsert-sorted rebuilds the whole list through rem, so each
; comment costs O(len comments*) *inside* the lock.  Three bgthreads
; (scrape-stories-p1, -p2-p3, -remaining-stories) all run that loop
; against the same list.  Total throughput across every thread in the
; image collapses to one insert at a time, while the arrival rate is
; hundreds of times higher, so the queue never drains and the two losers
; stay blocked indefinitely.
;
; Production numbers at the time: comments* held 259261 entries, so one
; insert was ~61 ms (11.8 ms at 50000, measured in the concurrency
; handoff, scaling linearly).  scrape-stories-p1 covers the top 30
; stories, which averaged 981 comments each: 29421 inserts = ~1800 s of
; rank-lock* per pass, on a 3 s schedule.
;
; The fix is the batching the same handoff applied at boot: build the
; new list outside, take the lock once per story, merge once.  This file
; measures both so the ratio is visible rather than asserted.
;
; Expected today: "CONVOY REPRODUCED", a batched/per-comment speedup of
; ~100x or more, and the two non-holder threads observed blocked in the
; large majority of samples.

(load "news.arc")
(load "examples/locking/lockdump.arc")

(= nseed*    40000   ; stand-in for comments*; production was 259261
   nthreads*     3   ; p1, p2-p3, remaining-stories
   nper*       200)  ; comments in the story each thread is importing

; A plausible comments*: item tables in descending id order.
(= comments* (map [inst 'item 'id _ 'type 'comment]
                  (rev (range 1 nseed*))))

; Each thread re-imports comments that are already present, which is the
; common case in the scraper (the log shows the same items re-imported
; every pass) and keeps the list length stable so every insert costs the
; same.  Distinct slices per thread, so they are not fighting over one
; item.
(def slice-for (n)
  (map [inst 'item 'id _ 'type 'comment]
       (range (+ 1 (* n nper*)) (* (+ n 1) nper*))))

(= ready* 0 go* nil done* 0)

(def barrier ()
  (++ ready*)
  (until go* (sleep 0.001)))

(def finish () (++ done*))

(def await-done ()
  (until (is done* nthreads*) (sleep 0.01)))

(def release ()
  (until (is ready* nthreads*) (sleep 0.01))
  (= go* t))

; ---- 1. the current shape: one lock acquisition per comment ----

(= blocked-samples* 0 total-samples* 0 dumped* nil)

; Register the workers in bgthreads* under the names the live image
; used, purely so lockdump labels them and its output can be compared
; against deadlock.txt line for line.  Nothing else runs in this script.
(= worker-names* '(scrape-stories-p1 scrape-stories-p2-p3 scrape-remaining-stories))

(each n (range 0 (- nthreads* 1))
  (let cs (slice-for n)
    (= (bgthreads* (worker-names* n))
       (thread (barrier)
               (each c cs (put-item c comments*))
               (finish)))))

(release)
(= t0 (msec))

; Sample the wait graph while they run, counting only threads blocked on
; rank-lock* itself rather than on any lock.
(= rank-mutex* (lock-mutex rank-lock*))

(until (is done* nthreads*)
  (let waiting (len (keep [id (waiting-for _) rank-mutex*]
                          (sb-thread::list-all-threads)))
    (++ total-samples*)
    (when (> waiting 0) (++ blocked-samples*)))
  (when (and (no dumped*) (> (- (msec) t0) 1500))
    (= dumped* t)
    (prn)
    (prn "---- lockdump while the convoy is running ----")
    (lockdump)
    (prn "----------------------------------------------")
    (prn))
  (sleep 0.02))

(= per-comment-ms (- (msec) t0))
(= inserts (* nthreads* nper*))

(prn "per-comment put-item: " (len comments*) " comments*, "
     inserts " inserts across " nthreads* " threads")
(prn "  wall time      " per-comment-ms " ms")
(prn "  per insert     " (/ per-comment-ms inserts) " ms")
(prn "  throughput     " (/ (* 1000 inserts) per-comment-ms) " inserts/sec (all threads)")
(prn "  samples with a thread blocked on a lock: "
     blocked-samples* " of " total-samples*)

; ---- 2. the fix: one lock acquisition per story ----

(= ready* 0 go* nil done* 0)

(each n (range 0 (- nthreads* 1))
  (let cs (slice-for n)
    (thread (barrier)
            ; the merge is the work; only the store needs the lock, but
            ; the read of comments* must stay inside it -- see the
            ; hoisting rule in the concurrency handoff.
            (w/lock rank-lock*
              (= comments* (merge-item-lists comments* cs)))
            (finish))))

(release)
(= t1 (msec))
(await-done)
(= batched-ms (- (msec) t1))

(prn "batched merge: " nthreads* " lock acquisitions total")
(prn "  wall time      " batched-ms " ms")

; ---- verdict ----

(prn)
(let speedup (/ per-comment-ms (max batched-ms 0.001))
  (prn "speedup: " speedup "x")
  (if (and (> speedup 20) (> blocked-samples* (/ total-samples* 2)))
      (prn "CONVOY REPRODUCED: per-comment locking serializes every "
           "importer, and threads are blocked in most samples.")
      (prn "not reproduced -- retune nseed*/nper* upward and re-run")))
