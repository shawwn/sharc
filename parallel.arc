(def parallel (f seq (o n 50) (o noisy nil) (o name "arc"))
  (if (is n 0)
      (map f seq)
      (withs (batches (tuples seq n)
              slots   (map [list nil] batches)
              threads nil)
        (after
          (do (map (fn (i slot batch)
                     (push (named-thread "@{name}-parallel-@{i}"
                             (scar slot (accum a
                                          (each x batch
                                            (a (f x))))))
                           threads))
                   (range 1 (len slots)) slots batches)
              (map0 join-thread threads)
              (noisy-flush noisy))
          (each th threads (stop-thread th)))
        (apply + nil (map car slots)))))

(def batch-size (total threads)
  (max 1 (+ 1 (trunc (/ total (max 1 threads))))))
