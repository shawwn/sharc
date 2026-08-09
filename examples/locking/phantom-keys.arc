#!./sharc

; Regression test for phantom keys handed back by maphash.
;
; maptable walks a table with a bare maphash, and keys, vals and tablist
; are all built on it.  When another thread inserts a new key the table
; rehashes, and a walk already in flight can visit storage slots
; mid-move.  What comes back is 0, SBCL's fill value for an unused key
; slot: a "key" that was never in the table.
;
; That is how it surfaced.  The update-avg background thread walked
; profs* while a scrape inserted users into it, the test lambda was
; handed 0, and (uvar 0 submitted) expanded to ((profile 0) 'submitted).
; (profile 0) is nil because 0 is not a key, so nil got applied:
;
;   The value ARC::|submitted| is not of type (UNSIGNED-BYTE 45)
;
; The crash is the harmless half.  tablist feeds save-table, so a save
; racing an insert can write a (0 0) row into hpw, cooks or uids.  It
; survives the round trip and loads back as a genuine key, and
; (downcase 0) errors, so register-accts throws and the server will not
; boot -- silent at write time, fatal at read time, arbitrarily later.
;
; Detect phantoms by *type*, not by a failed lookup.  A key that fails a
; lookup may simply have been removed after the walk started, which is
; ordinary staleness and not a bug; conflating the two overstates the
; damage by hundreds of thousands.  Every real key here is a string, so
; a non-string key is unambiguous.  This writer never removes anything,
; but the type check keeps the test honest if someone adds a wipe.
;
; Before the fix this reports phantoms in the hundreds of thousands,
; every one of them 0.  To watch it fail, revert tabkeys in arc0.lisp to
; a bare maphash with no with-locked-hash-table around it.
;
; Expected: "0 phantom keys" / "OK: no phantom keys".

(= inserts* 300000)
(= h (table) writing t phantoms 0 sample nil walks 0)

; grows the table, so it rehashes repeatedly
(thread (for i 1 inserts* (= (h (string "user" i)) i))
        (wipe writing))

; walks the keys over and over while it grows
(thread (while writing
          (++ walks)
          (each k (keys h)
            (unless (isa!string k)
              (++ phantoms)
              (or= sample k)))))

(while writing (sleep 0.05))
(sleep 0.2)

(prn "grew to " (len (keys h)) " keys across " walks " concurrent walks")
(prn phantoms " phantom keys"
     (if sample (string ", first was " (tostring:write sample)) ""))
(if (is phantoms 0)
    (prn "OK: no phantom keys")
    (prn "*** PHANTOM KEYS: " phantoms " ***"))
