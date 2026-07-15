; an implementation of the sf-pwgen algorithm.

(= memorable-chars* (chars "!\"#&'()*,-./:;?@@[\\]_{}"))

(defmemo memorable-wordlist ()
  (table [each (k v) (load-json "wordlist.json")
           ; json keys are always symbols, so convert to int
           (= (_ (int:string k)) v)]))

(def memorable-words ((o n))
  ((memorable-wordlist) n))

(defmemo memorable-pool ((o min-end 3) (o max-end 5))
  (mappend memorable-words (range min-end max-end)))

(def memorable-pw ((o n 12) (o min-end 3) (o max-end 5))
  (with (pool (assert:memorable-pool min-end max-end)
         front nil  back nil  gap 0)
    ; pick two end words that leave room for a middle section
    (while (< gap 1)
      (= front (rand-elt pool)
         back  (rand-elt pool)
         gap   (- n (len front) (len back))))
    ; fill the middle: symbols when there's room, digits to finish
    (with (middle nil  i gap  cs (copylist memorable-chars*))
      (while (< (len middle) gap)
        (if (> (- gap (len middle)) 2)
            (let c (rand-elt cs)
              ; prevent using the same symbol twice
              (when (> (len cs) 1)
                (pull c cs))
              (push c middle))
            (push (inc #\0 (rand 10)) middle)))
      (+ front (as!string middle) back))))

(def memorable-name ((o n 12) (o min-end 3) (o max-end 5))
  (keep goodchar&~digit (memorable-pw n min-end max-end)))

(def memorable-names ((o count 5) (o n 12) (o min-end 3) (o max-end 5))
  (n-dedup count (memorable-name n min-end max-end)))

(def memorable-pws ((o count 5) (o n 12) (o min-end 3) (o max-end 5))
  (n-dedup count (memorable-pw n min-end max-end)))

