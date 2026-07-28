#'(require :sb-sprof)

(= arc-sampling-interval* 0.001)

(mac profiling body
  `#`(sb-sprof::with-profiling (:max-samples 1000 :sample-interval #,arc-sampling-interval* :report :flat :loop nil)
      #,(do ,@body)))
