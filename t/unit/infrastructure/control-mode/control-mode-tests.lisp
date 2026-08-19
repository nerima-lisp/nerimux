(in-package #:nerimux/test)

;;;; Tests for nerimux/control: the control mode (-C) wire-protocol formatters.

(describe "control-suite"

  ;; ── %begin / %end / %error framing ──────────────────────────────────────────

  ;; %begin / %end / %error format as `%VERB <time> <number> <flags>`.
  (it "control-begin-end-error-lines"
    (expect (string= "%begin 5 7 1"
                 (nerimux/control:control-begin 7 :time 5)))
    (expect (string= "%end 5 7 1"
                 (nerimux/control:control-end 7 :time 5)))
    (expect (string= "%error 0 3 1"
                 (nerimux/control:control-error 3))))

  ;; A successful reply is %begin, the output lines, then %end.
  (it "control-format-reply-success"
    (let ((reply (nerimux/control:control-format-reply 9 (format nil "line1~%line2")
                                                       :time 100)))
      (expect (string= (format nil "%begin 100 9 1~%line1~%line2~%%end 100 9 1") reply))))

  ;; A failed reply closes with %error instead of %end.
  (it "control-format-reply-error"
    (let ((reply (nerimux/control:control-format-reply 4 "boom"
                                                       :success nil :time 2)))
      (expect (string= (format nil "%begin 2 4 1~%boom~%%error 2 4 1") reply))))

  ;; Empty output yields just the %begin/%end pair (no blank middle line).
  (it "control-format-reply-empty-output"
    (let ((reply (nerimux/control:control-format-reply 1 "" :time 0)))
      (expect (string= (format nil "%begin 0 1 1~%%end 0 1 1") reply))))

  ;; ── %output escaping ────────────────────────────────────────────────────────

  ;; Non-printable bytes are escaped as 3-digit octal; printable ASCII passes through.
  (it "control-escape-output-octal"
    (dolist (c `(("abc"                         "abc"     "plain ASCII passes through")
                 (,(format nil "a~Cb" #\Esc)    "a\\033b" "ESC escapes to \\033")
                 (,(format nil "x~C" #\Newline) "x\\012"  "newline (10 = octal 012) is escaped")))
      (destructuring-bind (input expected desc) c
        (declare (ignore desc))
        (expect (string= expected (nerimux/control:control-escape-output input))))))

  ;; %output prefixes the pane id with % and escapes the data.
  (it "control-output-notification"
    (expect (string= "%output %3 hello"
                 (nerimux/control:control-output 3 "hello")))
    (expect (string= "%output %12 a\\011b"
                 (nerimux/control:control-output 12 (format nil "a~Cb" #\Tab)))))

  ;; ── State-change notifications (sigils $ @ %) ───────────────────────────────

  ;; Session/window notifications use the $ and @ id sigils.
  (it "control-session-and-window-notifications"
    (dolist (c `(("%session-changed $1 main"
                  ,(nerimux/control:control-session-changed 1 "main")
                  "session-changed uses $ sigil")
                 ("%session-renamed $2 work"
                  ,(nerimux/control:control-session-renamed 2 "work")
                  "session-renamed uses $ sigil")
                 ("%window-add @4"
                  ,(nerimux/control:control-window-add 4)
                  "window-add uses @ sigil")
                 ("%window-close @4"
                  ,(nerimux/control:control-window-close 4)
                  "window-close uses @ sigil")
                 ("%window-renamed @4 editor"
                  ,(nerimux/control:control-window-renamed 4 "editor")
                  "window-renamed uses @ sigil")
                 ("%unlinked-window-add @9"
                  ,(nerimux/control:control-unlinked-window-add 9)
                  "unlinked-window-add uses @ sigil")))
      (destructuring-bind (expected actual desc) c
        (declare (ignore desc))
        (expect (string= expected actual)))))

  ;; %window-pane-changed and %session-window-changed use the @ / % / $ id sigils
  ;; (tmux control_notify_window_pane_changed / _session_window_changed).
  (it "control-active-change-notifications"
    (expect (string= "%window-pane-changed @4 %2"
                 (nerimux/control:control-window-pane-changed 4 2)))
    (expect (string= "%session-window-changed $1 @3"
                 (nerimux/control:control-session-window-changed 1 3))))

  ;; layout-change, client-session-changed, and exit notifications.
  (it "control-layout-and-client-and-exit"
    (dolist (c `(("%layout-change @1 abcd,80x24,0,0 abcd,80x24,0,0 *"
                  ,(nerimux/control:control-layout-change 1 "abcd,80x24,0,0"
                                                            "abcd,80x24,0,0" "*")
                  "layout-change lists window id then old and new layouts")
                 ("%client-session-changed client-1 $0 main"
                  ,(nerimux/control:control-client-session-changed "client-1" 0 "main")
                  "client-session-changed uses $ sigil for the session id")
                 ("%exit"
                  ,(nerimux/control:control-exit)
                  "bare exit has no reason")
                 ("%exit server exited"
                  ,(nerimux/control:control-exit "server exited")
                  "exit with reason appends it after the sigil")))
      (destructuring-bind (expected actual desc) c
        (declare (ignore desc))
        (expect (string= expected actual))))))
