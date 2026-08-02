#'(require :sb-sprof)

(= ;prof-report-mode*      :flat  ; default, flat reporting
   ;prof-report-mode*      :graph ; call site graphing
   prof-output-stream*     (stderr)
   prof-sampling-interval* 0.001
   prof-max-samples*       (com (- (expt 2 31) 1)))

(mac profiling body
  (w/uniq prev-out
    `(let ,prev-out (stdout)
       (w/stdout prof-output-stream*
         #`(sb-sprof::with-profiling
             (:threads         (list sb-thread::*current-thread*) ; current thread only
              :loop            nil
              :max-samples     #,prof-max-samples*
              :sample-interval #,prof-sampling-interval*
              ;:report          #,prof-report-mode*
              :report          :graph ; can't specify via var, only literally
              ;:stream         #,(stderr) ; does this work?
              ;:mode           :alloc ; allocation profiling

              ; Darwin caveat, straight from the start-profiling docstring: "On
              ; some platforms (eg. Darwin) the signals used by the profiler are not
              ; properly delivered to threads in proportion to their CPU usage when
              ; doing :CPU profiling. If you see empty call graphs, or are obviously
              ; missing several samples from certain threads, you may be falling
              ; afoul of this." That's you. It's one more reason the cross-thread
              ; split in that report is soft, and an argument for :mode :time
              ; (wallclock, driven by a dedicated timer thread) if per-thread
              ; attribution keeps looking wrong.
              ;:mode :time
              )
             #,(w/stdout ,prev-out
                 ,@body))))))
