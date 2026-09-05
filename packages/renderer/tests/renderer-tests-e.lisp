(in-package #:nerimux/test/renderer)

(describe "renderer-suite"


  (it "render-session-emits-cursor-shape"
    (let* ((sess  (make-renderer-test-session 20 5))
           (ap    (session-active-pane sess))
           (sc    (pane-screen ap)))
      (setf (nerimux/terminal/types:screen-cursor-shape sc) 2)
      (let ((out (render-session-to-string sess 6 20)))
        (expect (search (format nil "~C[2 q" #\Escape) out)))))


  (it "render-session-no-window-produces-output"
    (let* ((sess (make-session :id 1 :name "0" :windows nil)))
      (finishes
        (let ((out (render-session-to-string sess 5 20)))
          (expect (plusp (length out)))))))


  (it "render-panes-borders-nil-window-finishes"
    (finishes
      (let ((buf (make-string-output-stream)))
        (nerimux/renderer::%render-panes-and-borders buf nil nil nil nil 80))))


  (it "visible-length-escape-free-equals-length"
    (expect (= 5 (nerimux/renderer::%visible-length "hello")))
    (expect (= 0 (nerimux/renderer::%visible-length "")))
    (expect (= (length "a:b 12:34")
               (nerimux/renderer::%visible-length "a:b 12:34"))))

  (it "visible-length-skips-sgr-sequences"
    (let ((esc #\Escape))
      (expect (= 2 (nerimux/renderer::%visible-length
                    (format nil "~C[32mhi~C[0m" esc esc))))
      (expect (= 3 (nerimux/renderer::%visible-length
                    (format nil "~C[1;44;97mABC" esc))))))

  (it "visible-truncate-escape-free-equals-subseq"
    (check-visible-truncate-cases
     '(("hello" 3  "hel"   "truncate to 3")
       ("hello" 5  "hello" "truncate at exact length")
       ("hello" 99 "hello" "truncate past length -> unchanged")
       ("hello" 0  ""      "truncate to 0 -> empty string"))))

  (it "visible-truncate-passes-sgr-through"
    (let* ((esc  #\Escape)
           (in   (format nil "~C[32mABCDE" esc))
           (out  (nerimux/renderer::%visible-truncate in 2)))
      (expect (= 2 (nerimux/renderer::%visible-length out)))
      (expect (search "AB" out))
      (expect (char= esc (char out 0)))))

  (it "status-style-block-body-ignored-always-resets-to-base"
    (let ((out (nerimux/renderer::%status-style-block-sgr "fg=green" "44;97")))
      (expect (string= (format nil "~C[0;44;97m" #\Escape) out))
      (expect (not (search (format nil "~C[32m" #\Escape) out)))))

  (it "status-style-block-default-resets-to-base"
    (check-status-style-reset-cases "44;97" '("default" "none" "" "  ")))

  (it "status-expand-style-blocks-no-block-unchanged"
    (check-status-expand-unchanged-cases "44;97" '("plain text" " 0 1:1* ")))

  (it "status-expand-style-blocks-converts-blocks"
    (let* ((esc      #\Escape)
           (out      (nerimux/renderer::%status-expand-style-blocks
                      "#[fg=green]X#[default]Y" "44;97"))
           (expected (format nil "~C[0;44;97mX~C[0;44;97mY" esc esc)))
      (expect (null (search "#[" out)))
      (expect (string= expected out))))


  (it "render-session-background-bell-always-swallowed"
    (let* ((sess  (make-fake-session :nwindows 2))
           (win2  (second (nerimux/session:session-windows sess)))
           (pane2 (first (nerimux/window:window-panes win2))))
      (setf (nerimux/terminal/types:screen-bell-pending
             (nerimux/pane:pane-screen pane2)) t)
      (let ((out (nerimux/renderer::render-session-to-string sess 5 20)))
        (expect (null (find (code-char 7) (%bel-before-title-osc out))))
        (expect (null (nerimux/terminal/types:screen-bell-pending
                       (nerimux/pane:pane-screen pane2)))))))

  (it "emit-bell-always-audible"
    (let ((out (with-output-to-string (s) (nerimux/renderer::%emit-bell s))))
      (expect (find (code-char 7) out)))))
