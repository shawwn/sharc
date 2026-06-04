; Fetches the four context items from the prompt and asserts that each
; named comment has the expected flag combination.
;
; Examples (from prompt):
;   48106273 in 48085993  -> [flagged][dead]
;   48105810 in 48038191  -> [dead] only
;   48092598 in 48086190  -> [flagged][dead][collapsed]
;   48085067 in 48073201  -> [collapsed] live (no flagged/dead)

(load "scrape.arc")

(map ensure-dir (list scrape-dir* scrape-item-dir* scrape-user-dir*))
(ensure-login)

(def expect-fields (got-tbl want)
  (let bad nil
    (each (k v) (tablist want)
      (unless (is (got-tbl k) v)
        (push (list k 'want v 'got (got-tbl k)) bad)))
    bad))

(def find-comment (cs id)
  (some [if (is _!id id) _] cs))

(def verify-comment (context-id comment-id expected)
  (prn "fetching context " context-id "...")
  (flushout)
  (sleep scrape-crawl-delay*)
  (let html (curl-get (+ scrape-hn-host* "/item?id=" context-id))
    (prn "  html len: " (and html (len html)))
    (if (no html)
        (prn "FAIL " comment-id ": fetch failed")
        (let cs (parse-comments html context-id)
          (prn "  comments: " (len cs))
          (let c (find-comment cs comment-id)
            (if (no c)
                (prn "FAIL " comment-id ": comment not found in " context-id)
                (let bad (expect-fields c expected)
                  (if bad
                      (prn "FAIL " comment-id ": " bad)
                      (prn "PASS " comment-id " in " context-id
                           " dead=" c!dead " flagged=" c!flagged
                           " collapsed=" c!collapsed)))))))
    (flushout)))

(verify-comment 48085993 48106273 (obj dead t flagged t collapsed nil))
(verify-comment 48038191 48105810 (obj dead t flagged nil collapsed nil))
(verify-comment 48086190 48092598 (obj dead t flagged t collapsed t))
(verify-comment 48073201 48085067 (obj dead nil flagged nil collapsed t))
(flushout)
