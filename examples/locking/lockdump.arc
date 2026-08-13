; Read-only deadlock diagnostics, for use from a repl attached to a
; wedged image.  Nothing here acquires a lock -- deliberately, since the
; lock you want to inspect is the one that is stuck.
;
;   (load "examples/locking/lockdump.arc")
;   (lockdump)          ; which locks are held, by whom, and who is waiting
;   (bt 'topstories)    ; backtrace of one bgthread, by its defbg id
;   (bt-all)            ; backtrace of every thread but this one
;
; Note that SBCL detects pure mutex cycles itself: a genuine A->B/B->A
; deadlock signals sb-thread:thread-deadlock rather than hanging, which
; kills the thread and prints a report.  So threads that are *blocked*
; rather than *dead* usually mean one holder is slow (an http fetch, a
; disk write) and everyone else is queued behind it -- not a cycle.

; An arc lock is a synchronized hash table; its mutex lives in a struct
; slot.  *arc-mutex* (atomic) is already a mutex, and passes through.

(def lock-mutex (l)
  (if (isa!table l) (sb-impl::hash-table-%lock l) l))

(def lock-owner (l)
  (sb-thread::mutex-owner (lock-mutex l)))

(def waiting-for (th)
  (sb-thread::thread-waiting-for th))

(mac iflive (name)
  `(if (bound ',name) ,name))

; Every named lock, in level order (see arc.arc's table).  Locks whose
; file is not loaded are skipped; striped locks expand per live stripe.

(def known-locks ()
  (accum a
    (each (nm l) (pair:list
                   'submit-lock*     (iflive submit-lock*)
                   'rank-lock*       (iflive rank-lock*)
                   'maxid-lock*      (iflive maxid-lock*)
                   'maxuid-lock*     (iflive maxuid-lock*)
                   'ignore-log-lock* (iflive ignore-log-lock*)
                   'fnid-lock*       (iflive fnid-lock*)
                   'queue-lock*      (iflive queue-lock*)
                   'scrape-lock*     (iflive scrape-lock*)
                   'place-lock*      (iflive place-lock*)
                   'log-lock*        (iflive log-lock*)
                   'scrapelog-lock*  (iflive scrapelog-lock*)
                   'ero-lock*        (iflive ero-lock*))
      (when l (a (list nm l))))
    (each (k l) (iflive vote-locks*)
      (a (list (sym:string "vote-lock*." k) l)))
    (each (k l) (iflive save-locks*)
      (a (list (sym:string "save-lock*." k) l)))
    ))

; A readable label for a thread: its bgthread id, the server thread, or
; this one.  new-thread names every arc thread "arc", so object identity
; is the only way to tell them apart.

(def thread-label (th)
  (if (no th)                        nil
      (id th (current-thread))       'repl
      (id th (iflive serve-thread*)) 'serve
      (or (car:keep [id ((iflive bgthreads*) _) th]
                    (if (bound 'bgthreads*) (keys bgthreads*)))
          th)))

; Reverse a mutex back to the arc lock it belongs to.  Arc table locks
; are all named "hash-table lock", so only identity works; *arc-mutex*
; carries a name of its own, hence the fallback.

(def lock-label (m)
  (or (car:car:keep [id (lock-mutex:cadr _) m] (known-locks))
      (errsafe (sb-thread::mutex-name m))
      m))

; srv.arc's bgthread heartbeat.  This is the part of the dump that
; distinguishes a thread merely between passes from one wedged inside its
; body -- "running" here only ever meant "not blocked on a mutex", and a
; thread in sleep, in a socket read, in a busy-wait or stopped for GC all
; report it.
;
;   idle 12s    slept 12s since finishing a pass; healthy
;   run 2847s   has been inside its body for 47 minutes; this is the one

(def bgtick-report (id)
  (if (no (bound 'bgticks*))
      ""
      (whenlet tick (bgticks* id)
        (let (state since runs) tick
          (string "  " state " " (- (seconds) since) "s"
                  "  runs " runs)))))

; Follow the wait-for graph: T waits on mutex M, M is owned by T2, what
; is T2 waiting on?  A chain ending in CYCLE! is a genuine deadlock.  A
; chain ending in (someone running) means nobody is deadlocked: one
; holder is slow, and its backtrace says why.

(def wait-chain (th)
  ((afn (th seen acc)
     (if (no th)
          (rev:cons 'gone acc)
         (some [id _ th] seen)
          (rev:cons 'cycle! acc)
         (let m (waiting-for th)
           (if (no m)
               (rev:cons (list (thread-label th) 'running) acc)
               (self (sb-thread::mutex-owner m)
                     (cons th seen)
                     (cons (list (thread-label th) '-> (lock-label m)) acc))))))
   th nil nil))

(def lockdump ()
  (prn "=== held locks ===")
  (each (nm l) (known-locks)
    (whenlet owner (lock-owner l)
      (prn "  " nm " held by " (thread-label owner))))
  (prn "=== threads ===")
  (each th (sb-thread::list-all-threads)
    (let w (waiting-for th)
      (prn "  " (thread-label th)
           (if (dead-thread th) " DEAD"
               w                (string " WAITING on " (lock-label w))
                                " running"))))
  (prn "=== bgthreads ===")
  (each k (if (bound 'bgthreads*) (keys bgthreads*))
    (prn "  " k
         (if (dead-thread (bgthreads* k)) " DEAD" " alive")
         (bgtick-report k)))
  (prn "=== wait chains ===")
  (each th (sb-thread::list-all-threads)
    (when (waiting-for th)
      (prn "  " (wait-chain th))))
  nil)

; Backtrace of another thread.  interrupt-thread runs the closure in the
; target and then lets it resume, so this is non-destructive.  It works
; reliably on a thread that is *running* (including one holding a lock
; while it sleeps or does I/O -- the case you usually want).  A thread
; already blocked on a mutex is inside a without-interrupts and often
; never answers; hence the timeout, and it matters little, since lockdump
; already names the lock it is stuck on.
;
; Three ways this can hang, all of them fixed here rather than papered
; over with a bigger timeout, because none of them ever time out:
;
;  1. The closure runs in the *wedged* thread, so it must not take a
;     lock.  `scar`, not `(= (car box) ...)`: assignment to a compound
;     place takes place-lock*, usually the very lock under investigation.
;  2. Frames must be rendered to strings *here*, under CL's printer with
;     :level/:length bounds.  A raw frame holds live arc data as its
;     arguments -- items*, comments*, whole hash tables -- and handing
;     one back to the repl makes arc's writer walk all of it.  Returning
;     strings means the caller can never touch that data again.
;  3. `count` bounds the frames.  reinsert-sorted and friends recurse
;     per list element, so a thread stuck in one has a stack hundreds of
;     thousands of frames deep, and an unbounded list-backtrace tries to
;     render every one.

(def thread-backtrace (th (o secs 15) (o count 40) (o depth 3) (o width 3))
  (if (dead-thread th)
      '("dead")
      (withs (box (list nil) sem (sb-thread::make-semaphore))
        (sb-thread::interrupt-thread th
          (fn ()
            (scar box
                  (map [#'write-to-string _ :level depth :length width
                                            :circle t :pretty nil]
                       (sb-debug::list-backtrace :count count)))
            (sb-thread::signal-semaphore sem)))
        (if (sb-thread::wait-on-semaphore sem :timeout secs)
            (car box)
            '("no-response")))))

; Collapse runs of frames from the same function into one line.  A thread
; stuck in a per-element recursion (reinsert-sorted, rem, merge) shows
; thousands of identical frames, and "x2000" is the whole story.

(def frame-head (s)
  (car (tokens s [in _ #\space #\( #\)])))

(def collapse-frames (fs)
  (if (no fs)
      nil
      (withs (h   (frame-head (car fs))
              run (len (keep [is (frame-head _) h] (firstn-that fs h))))
        (cons (if (is run 1)
                  (car fs)
                  (string (car fs) "   x" run))
              (collapse-frames (nthcdr run fs))))))

(def firstn-that (fs h)
  ((afn (fs acc)
     (if (and fs (is (frame-head (car fs)) h))
         (self (cdr fs) (cons (car fs) acc))
         (rev acc)))
   fs nil))

(def find-thread (x)
  (if (isa!sym x)
      (or (and (bound 'bgthreads*) (bgthreads* x))
          (and (is x 'serve) (iflive serve-thread*))
          (err "No such thread: @x"))
      x))

(def bt (x (o secs 15) (o count 40))
  (let th (find-thread x)
    (prn "--- " (thread-label th) " ---")
    (each f (collapse-frames (thread-backtrace th secs count)) (prn "  " f)))
  nil)

(def bt-all ((o secs 15) (o count 40))
  (each th (sb-thread::list-all-threads)
    (unless (id th (current-thread)) (bt th secs count)))
  nil)
