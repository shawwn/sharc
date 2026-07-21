(def parallel (f seq (o n 50) (o noisy nil))
  (accum a
    (withs (i 0 done [do (a _) (noisy-report (++ i) noisy)])
      (let threads nil
        (after (do (each batch (tuples seq n)
                     (let th (thread
                               (each x batch
                                 (done (f x))))
                       (push th threads)))
                   (until (all dead-thread threads)
                     (sleep 0))
                   (noisy-flush noisy))
          (each th threads
            (stop-thread th)))))))

