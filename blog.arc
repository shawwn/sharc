#!./sharc

; Blog tool example.  20 Jan 08, rev 21 May 09.

; To run:
; arc> (load "blog.arc")
; arc> (bsv)
; go to http://localhost:8080/blog

(= postdir* (string arcdir* "posts/"))

(or= maxid* 0  posts* (table))

(= blogtitle* "A Blog")

(deftem post  id nil  title nil  text nil)

(def load-posts ()
  (each id (map int (dir postdir*))
    (= maxid*      (max maxid* id)
       (posts* id) (temload 'post (string postdir* id)))))

(def save-post (p) (save-table p (string postdir* p!id)))

(def post (id) (posts* (errsafe:int id)))

(mac blogpage body
  `(whitepage 
     (center
       (widtable 600 
         (tag b (link blogtitle* "blog"))
         (br 3)
         ,@body
         (br 3)
         (w/bars (link "archive")
                 (link "new post" "newpost"))))))

(defop viewpost (blogop post-page))

(def blogop (f)
  (aif (post arg!id)
       (f it)
       (blogpage (pr "No such post."))))

(def permalink (p) (string "viewpost?id=" p!id))

(def post-page (p) (blogpage (display-post p)))

(def display-post (p)
  (tag b (link p!title (permalink p)))
  (when (me)
    (sp)
    (link "[edit]" (string "editpost?id=" p!id)))
  (br2)
  (pr p!text))

(defopl newpost
  (whitepage
    (aform (post-page (addpost arg!t arg!b))
      (tab (row "title" (input "t" "" 60))
           (row "text"  (textarea "b" 10 80))
           (row ""      (submit))))))

(def addpost (title text)
  (let p (inst 'post 'id (++ maxid*) 'title title 'text text)
    (save-post p)
    (= (posts* p!id) p)))

(defopl editpost (blogop edit-page))

(def edit-page (p)
  (whitepage
    (vars-form `((string title ,p!title t t)
                 (text   text  ,p!text  t t))
               (fn (name val) (= (p name) val))
               {do (save-post p)
                   (permalink p)})))

(defop archive
  (blogpage
    (tag ul
      (each p (map post (rev (range 1 maxid*)))
        (tag li (link p!title (permalink p)))))))

(defop blog (frontpage))

(defop || (frontpage))

(def frontpage ()
  (blogpage
    (for i 0 4
      (awhen (posts* (- maxid* i))
        (display-post it)
        (br 3)))))

(def bsv ()
  (ensure-dir postdir*)
  (load-posts)
  (asv))

(when (main)
  (bsv)
  (repl))
