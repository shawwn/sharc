; Email via SMTP.  Speaks SMTP over an implicit-TLS connection (port
; 465), which is what Resend offers (smtp.resend.com); the TLS comes
; for free from socket-connect (see the http-client handoff).  Auth is
; AUTH LOGIN, so the only new primitive needed is a base64 encoder.
;
; Configuration is read at send time from the environment, then from
; smtp.json (see smtp.example.json).  Nothing here is Resend-specific
; beyond the default host, so it works against any SMTP-AUTH server.

(= crlf* (string #\return #\newline))


; ----- standard base64 (RFC 4648) -----

(= base64-chars*
   "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(def base64-encode (input)
  ; encode a string (as its UTF-8 bytes) or a byte vector to base64.
  ; we have no bit ops at the arc level, so the 24-bit group is built
  ; with arithmetic and sliced into 6-bit indices the same way.
  (let bytes (if (isa!string input) (string->bytes input) input)
    (tostring
      (with (n (len bytes) i 0)
        (while (< i n)
          (withs (has1   (< (+ i 1) n)
                  has2   (< (+ i 2) n)
                  b0     (bytes i)
                  b1     (if has1 (bytes (+ i 1)) 0)
                  b2     (if has2 (bytes (+ i 2)) 0)
                  triple (+ (* b0 65536) (* b1 256) b2))
            (pr (base64-chars* (mod (trunc (/ triple 262144)) 64)))
            (pr (base64-chars* (mod (trunc (/ triple 4096)) 64)))
            (pr (if has2 (base64-chars* (mod (trunc (/ triple 64)) 64))
                    has1 (base64-chars* (mod (trunc (/ triple 64)) 64))
                    "="))
            (pr (if has2 (base64-chars* (mod triple 64)) "=")))
          (++ i 3))))))


; ----- config -----

(= smtp-config-file* "smtp.json")

(def smtp-config ()
  ; merge env overrides over smtp.json, falling back to sane defaults.
  ; env wins so secrets can stay out of the file in production.
  (let cfg (or (and (file-exists smtp-config-file*)
                    (load-json smtp-config-file*))
               (table))
    (withs (port (let p (or (getenv "SMTP_PORT") cfg!port 465)
                   (if (isa!string p) (int p) p))
            ; implicit TLS for SMTPS (and the https port); socket-connect
            ; only auto-enables SSL for 443, so 465 needs it spelled out.
            ; SMTP_TLS=0 forces plaintext (e.g. talking to a relay).
            tls (let v (or (getenv "SMTP_TLS") cfg!tls 'auto)
                  (if (in v "0" "false" 'false) nil
                      (in v "1" "true" 'true)  t
                                               (in port 465 443))))
      (obj host (or (getenv "SMTP_HOST") cfg!host
                    "smtp.resend.com")
           port port
           tls  tls
           user (or (getenv "SMTP_USER") cfg!user)
           pass (or (getenv "SMTP_PASS") cfg!pass)
           from (or (getenv "SMTP_FROM") cfg!from (errsafe site-email*))
           ; optional display name shown to recipients when `from` is a
           ; bare address (e.g. "HN Simulator").  Ignored if `from`
           ; already carries its own "Name <addr>" form.
           from-name (or (getenv "SMTP_FROM_NAME") cfg!from-name)
           ; replies go here instead of From, so you can send from a
           ; noreply address but still receive human replies.
           reply-to (or (getenv "SMTP_REPLY_TO") cfg!reply-to)))))


; ----- date header -----

(= email-weekdays* '("Sun" "Mon" "Tue" "Wed" "Thu" "Fri" "Sat")
   email-months*   '("" "Jan" "Feb" "Mar" "Apr" "May" "Jun"
                     "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))

(def pad2 (n) (string (if (< n 10) "0") n))

(def email-date ((o s (seconds)))
  ; RFC 822 date in UTC, e.g. "Sun, 22 Jun 2026 14:03:09 +0000".
  ; 1970-01-01 was a Thursday (index 4), so the weekday is just the
  ; day count since the epoch shifted by 4.
  (let (sec min hr d mon yr) (timedate s)
    (string (email-weekdays* (mod (+ (trunc (/ s 86400)) 4) 7)) ", "
            (pad2 d) " " (email-months* mon) " " yr " "
            (pad2 hr) ":" (pad2 min) ":" (pad2 sec) " +0000")))


; ----- message assembly -----

(def email-addr (s)
  ; the bare address out of a From-style string: "Name <a@b>" -> "a@b",
  ; a plain "a@b" -> "a@b".  Used for the SMTP envelope and EHLO, which
  ; must never carry a display name.
  (aif (pos #\< s)
       (cut s (+ it 1) (pos #\> s))
       (trim s)))

(def email-domain (addr)
  ; the part after the @ of an email address (for the EHLO name).
  (whenlet i (pos #\@ addr) (cut addr (+ i 1))))

(def extra-headers (hs)
  ; hs is an alist of (name value) pairs; render them as header lines.
  (apply string (map (fn ((k v)) (string k ": " v crlf*)) hs)))

(def smtp-lines (body)
  ; split on newlines, preserving blank lines and stripping any CRs;
  ; we re-add CRLF ourselves and dot-stuff lines that start with a dot
  ; (so a lone "." in the body can't terminate the DATA command).
  (withs (out nil cur (outstring))
    (each c body
      (if (is c #\newline) (do (push (inside cur) out) (= cur (outstring)))
          (is c #\return)  nil
                           (disp c cur)))
    (push (inside cur) out)
    (apply string
      (intersperse crlf*
        (map [string (if (and (> (len _) 0) (is (_ 0) #\.)) ".") _]
             (rev out))))))

(def email-message (from to subject body (o reply-to) (o headers))
  ; to is a list of recipient addresses.  from is the full From header
  ; (may include a display name, e.g. "HN Simulator <hn@x.com>").
  ; reply-to, if given, is where mail clients direct replies.  headers
  ; is an optional alist of extra header (name value) pairs.
  (string
    "From: " from crlf*
    "To: " (apply string (intersperse ", " to)) crlf*
    (if reply-to (string "Reply-To: " reply-to crlf*))
    "Subject: " subject crlf*
    "Date: " (email-date) crlf*
    "MIME-Version: 1.0" crlf*
    "Content-Type: text/plain; charset=UTF-8" crlf*
    "Content-Transfer-Encoding: 8bit" crlf*
    (extra-headers headers)
    crlf*
    (smtp-lines body)))


; ----- SMTP conversation -----

(def smtp-line (s)
  (or (readline s) (err "smtp: connection closed by server")))

(def smtp-final (line)
  ; a reply's final line has a space (not '-') as its 4th character.
  (and (>= (len line) 4) (is (line 3) #\space)))

(def smtp-status (line)
  (errsafe:int (cut line 0 3)))

(def smtp-recv (s)
  ; read a (possibly multiline) reply; return (status (line ...)).
  (let line (smtp-line s)
    (withs (lines (list line))
      (until (smtp-final line)
        (= line (smtp-line s))
        (push line lines))
      (list (smtp-status line) (rev lines)))))

(def smtp-cmd (s cmd expect)
  ; send cmd (nil = just read), then require the reply's status = expect.
  (when cmd (disp cmd s) (disp crlf* s) (flushout s))
  (let reply (smtp-recv s)
    (unless (is (reply 0) expect)
      (err (string "smtp: expected " expect " after "
                   (or cmd "connect") " but got: "
                   (apply string (intersperse " " (reply 1))))))
    (reply 0)))


; ----- the public entry point -----

(def send-email (to subject body . opts)
  ; opts is a plist; recognized keys: from, from-name, reply-to, headers
  ; (each overrides the smtp.json default).  `to` may be a single address
  ; string or a list of them.  `from` may carry a display name
  ; ("HN Simulator <hn@x.com>") or be a bare address; a separate
  ; `from-name` wraps a bare address into that display form.  Returns t,
  ; or errors.
  (withs (o     (listtab (pair opts))
          cfg   (smtp-config)
          raw-from (or o!from cfg!from)
          from-name (or o!from-name cfg!from-name)
          from-addr (and raw-from (email-addr raw-from))
          ; the full From header: keep an explicit display name as-is,
          ; else synthesize one from from-name, else just the address.
          from-hdr (if (no raw-from)        nil
                       (pos #\< raw-from)   raw-from
                       from-name            (string from-name " <" from-addr ">")
                                            raw-from)
          reply-to (or o!reply-to cfg!reply-to)
          headers  o!headers
          recips (if (alist to) to (list to))
          ehlo  (or (email-domain (or from-addr "")) "localhost"))
    (unless cfg!user (err "smtp: no SMTP_USER (set SMTP_USER or smtp.json)"))
    (unless cfg!pass (err "smtp: no SMTP_PASS (set SMTP_PASS or smtp.json)"))
    (unless raw-from (err "smtp: no from address (set SMTP_FROM or smtp.json)"))
    (let s (socket-connect cfg!host cfg!port (if cfg!tls (obj ssl t)))
      (after
        (do (smtp-cmd s nil 220)
            (smtp-cmd s (string "EHLO " ehlo) 250)
            (smtp-cmd s "AUTH LOGIN" 334)
            (smtp-cmd s (base64-encode cfg!user) 334)
            (smtp-cmd s (base64-encode cfg!pass) 235)
            (smtp-cmd s (string "MAIL FROM:<" from-addr ">") 250)
            (each r recips
              (smtp-cmd s (string "RCPT TO:<" (email-addr r) ">") 250))
            (smtp-cmd s "DATA" 354)
            (disp (email-message from-hdr recips subject body reply-to headers) s)
            (disp crlf* s) (disp "." s) (disp crlf* s)
            (flushout s)
            (smtp-cmd s nil 250)
            (smtp-cmd s "QUIT" 221))
        (close s)))
    t))
