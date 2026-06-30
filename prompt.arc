; Prompt: Web-based programming application.  4 Aug 06.

(= appdir* (string arcdir* "apps/"))

(defop prompt
  (if (admin)
      (prompt-page)
      (pr "Sorry.")))

(def prompt-page msg
  (let user (me)
    (ensure-dir appdir*)
    (ensure-dir (string appdir* user))
    (whitepage
      (prbold (link "Prompt" "prompt"))
      (hspace 20)
      (pr user " | ")
      (link "logout")
      (when msg (hspace 10) (apply pr msg))
      (br2)
      (tag (table border 0 cellspacing 10)
        (each app (dir (+ appdir* user))
          (tr (td app)
              (td (ulink 'edit   (edit-app app)))
              (td (ulink 'run    (run-app  app)))
              (td (hspace 40)
                  (ulink 'delete (del-app  app))))))
      (br2)
      (uform (aif (goodname arg!app)
                  (edit-app it)
                  (prompt-page "Bad name."))
        (tab (row "name:" (input "app" nil 20) (submit "create app")))))))

(def app-path (app (t user me))
  (and user app (+ appdir* user "/" app)))

(def read-app (app)
  (aand (app-path app)
        (file-exists it)
        (readfile it)))

(def write-app (app exprs)
  (awhen (app-path app)
    (w/outfile o it 
      (each e exprs (write e o)))))

(def del-app (app)
  (tab
    (tr (td)
        (td (uform (if (is arg!b "Yes")
                       (rem-app app)
                       (prompt-page))
               (prn "Do you want program " app " to be deleted?")
               (br2)
               (but "Yes" "b") (sp) (but "No" "b"))))))


(def rem-app (app)
  (let file (app-path app)
    (if (file-exists file)
        (do (rmfile file)
            (prompt-page "Program " app " deleted."))
        (prompt-page "No such app."))))

(def edit-app (app)
  (whitepage
    (pr "user: " (me) " app: " app)
    (br2)
    (uform (do (when (is arg!cmd "save")
                 (write-app app (readall arg!exprs)))
               (prompt-page))
      (textarea "exprs" 10 82
        (pprcode (read-app app)))
      (br2)
      (buts 'cmd "save" "cancel"))))

(def pprcode (exprs)
  (each e exprs
    (ppr e)
    (pr "\n\n")))

(def view-app (app)
  (whitepage
    (pr "user: " (me) " app: " app)
    (br2)
    (tag xmp (pprcode (read-app app)))))

(def report-prompt-error (c)
  (br)
  (tag pre
    (report-error c (stdout))))

(def run-app (app)
  (let exprs (read-app app)
    (if exprs
        (on-err report-prompt-error {map eval exprs})
        (prompt-page "Error: No application " app " for user " (me)))))

(wipe repl-history*)

(defop repl
  (if (admin)
      (replpage)
      (pr "Sorry.")))

(def replpage ()
  (whitepage
    (replform (readall (or arg!expr "")) "repl")))

(def replform (exprs url)
    (each expr exprs 
      (on-err (fn (c) (push (list expr c t) repl-history*))
              (fn () 
                (= that (eval expr) thatexpr expr)
                (push (list expr that) repl-history*))))
    (form url
      (textarea "expr" 8 60)
      (sp) 
      (submit))
    (tag xmp
      (each (expr val err) (firstn 20 repl-history*)
        (pr "> ")
        (ppr expr)
        (prn)
        (prn (if err "Error: " "")
             (ellipsize (tostring (write val)) 800)))))

