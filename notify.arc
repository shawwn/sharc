; Out-of-band alerts, for things worth knowing about while nobody is
; watching the terminal.
;
; Configured in notify.json (copy notify.example.json).  With no config,
; or with a channel left blank, that channel is a silent no-op -- so
; notify! is safe to call from anywhere, including a fresh checkout.
;
; Channels are independent on purpose.  iMessage needs Messages.app
; signed in and Automation permission granted once, and fails quietly
; when it isn't; email goes through the smtp.json that already exists.
; Sending to both means a single misconfigured channel doesn't swallow
; the alert.
;
;   "sms"    an iMessage handle: a phone number, best written E.164
;            (+12025550143), or the Apple ID email of the recipient.
;            Delivered over iMessage, not carrier SMS -- if the number is
;            not on iMessage this silently does nothing, since falling
;            back to green-bubble SMS needs Text Message Forwarding set
;            up from an iPhone on the same Apple ID.
;   "email"  any address; sent through email.arc using smtp.json.
;
; Leave either blank to turn that channel off.

(= notify-config-file* "notify.json")

(def notify-config ()
  ; read every time rather than caching: editing notify.json should take
  ; effect without a restart, and this runs rarely enough not to matter.
  (or (and (file-exists notify-config-file*)
           (errsafe:load-json notify-config-file*))
      (obj)))

; AppleScript string literals escape backslash and double quote, the same
; two as C.  The shell layer is handled separately by shellsafe.

(def applescript-string (s)
  (multisubst '(("\\" "\\\\") ("\"" "\\\"")) (string s)))

(def imessage (to text)
  (shellsafe "osascript" "-e"
             (+ "tell application \"Messages\" to send \""
                (applescript-string text)
                "\" to buddy \"" (applescript-string to)
                "\" of (1st service whose service type = iMessage)")))

; Returns an alist of (channel sent-or-failed) for whatever was tried, so
; a caller can log which ones actually got through.

(def notify! (subject body)
  (lets cfg (notify-config)
    (accumulate a
      (whenlet to (check cfg!sms ~blank)
        (a (list 'imessage (if (imessage to (+ subject " -- " body)) 'sent 'failed))))
      (whenlet to (check cfg!email ~blank)
        (a (list 'email (if (errsafe:send-email to subject body) 'sent 'failed)))))))

; Same, but off the calling thread: alerts shell out and talk to an smtp
; server, and the places worth alerting from tend to be holding a lock.

(def notify-async! (subject body)
  (start-thread (fn () (call-reporting {notify! subject body})) "notify"))
