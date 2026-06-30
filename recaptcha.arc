; Conditional reCAPTCHA v2 on account creation.
;
; HN doesn't show a captcha on every signup; it shows one only when
; signups from an IP start to look abusive.  We do the same: once an IP
; has created `threshold` accounts within the last day, both the
; create-account form (the v2 widget) and the POST handler (server-side
; siteverify) require a solved captcha for that IP.
;
; Keys come from recaptcha.json (see recaptcha.example.json) or the
; environment.  The site key is public (it is embedded in the page);
; the secret must stay server-side.  When no keys are configured the
; whole feature no-ops, so local dev and tests need no setup.

(= recaptcha-config-file* "recaptcha.json")

(def recaptcha-config ()
  ; merge env overrides over recaptcha.json, falling back to defaults.
  (let cfg (or (and (file-exists recaptcha-config-file*)
                    (load-json recaptcha-config-file*))
               (table))
    (obj site-key  (or (getenv "RECAPTCHA_SITE_KEY") cfg!site-key)
         secret    (or (getenv "RECAPTCHA_SECRET")   cfg!secret)
         ; how many accounts one IP may create per day before a captcha
         ; starts being required on the next signup from that IP.
         threshold (let n (or (getenv "RECAPTCHA_THRESHOLD") cfg!threshold 2)
                     (if (isa n 'string) (int n) n)))))

(def recaptcha-keys ()
  ; the config iff both keys are present, else nil (feature disabled).
  (let cfg (recaptcha-config)
    (and cfg!site-key cfg!secret cfg)))


; ----- per-IP account-creation tracking -----
;
; In-memory ip -> list of unix-second creation times.  Resets on
; restart, which at worst grants one extra captcha-free signup window
; per IP after a bounce; fine for an abuse speed bump.

(= recaptcha-day* 86400)

(or= acct-creations* (table))

(def note-acct-creation ((t ip) (o t (seconds)))
  ; record a creation and prune entries older than the look-back window.
  (= (acct-creations* ip)
     (cons t (keep [> _ (- t recaptcha-day*)] (acct-creations* ip)))))

(def recent-acct-creations ((t ip) (o now (seconds)))
  (len (keep [> _ (- now recaptcha-day*)] (acct-creations* ip))))

(def recaptcha-required ((t ip))
  ; true iff the feature is configured and this IP is at/over threshold.
  (whenlet cfg (recaptcha-keys)
    (>= (recent-acct-creations ip) cfg!threshold)))


; ----- the widget (client side) -----

(def recaptcha-widget ((o cfg (recaptcha-config)))
  ; load Google's script and render the v2 checkbox.  On submit the
  ; widget injects a hidden g-recaptcha-response field into the form,
  ; so the token rides along with the fnid post.
  (pr "<script src=\"https://www.google.com/recaptcha/api.js\" async defer></script>")
  (pr "<div class=\"g-recaptcha\" data-sitekey=\"" cfg!site-key "\"></div>")
  (br))


; ----- server-side verification (siteverify) -----

(def recaptcha-url (secret token (t ip))
  ; siteverify accepts GET query params.  urlencode emits only
  ; unreserved chars, so every value is shell-safe (no quote/space/
  ; semicolon survives) and the curl string can wrap the URL in single
  ; quotes without any injection risk.
  (string "https://www.google.com/recaptcha/api/siteverify"
          "?secret="   (urlencode secret)
          "&response="  (urlencode token)
          (if ip (string "&remoteip=" (urlencode ip)))))

(def recaptcha-siteverify (secret token (t ip))
  ; returns Google's raw JSON reply, or nil on any failure.  curl is a
  ; runtime dependency (already used by the scraper); self-contained
  ; here so this works without scrape.arc loaded.
  (errsafe
    (allchars
      (pipe-from
        (string "curl -sS --max-time 15 '"
                (recaptcha-url secret token ip) "'")))))

(def recaptcha-pass (token (t ip) (o cfg (recaptcha-config)))
  ; fail closed: a missing token, network/curl error, or success=false
  ; all yield nil.  Only a genuine success=true returns t.
  (and cfg!secret token (~empty token)
       (whenlet reply (recaptcha-siteverify cfg!secret token ip)
         (whenlet parsed (errsafe (from-json reply))
           parsed!success))))
