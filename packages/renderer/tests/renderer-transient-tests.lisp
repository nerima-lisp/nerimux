(in-package #:nerimux/test/renderer)

;;;; The magit transient panel (FR-010) and the `$` process log (FR-011).
(defun %render-transient-panel-output (view cols rows)
  "Draw VIEW into a fresh COLS x ROWS surface and return the plain ANSI
   frame -- RENDER-TRANSIENT-PANEL itself draws onto a caller-owned surface
   rather than returning a string, so tests need this much setup to see its
   output the way RENDER-TRANSIENT-FULL-SCREEN-TO-TUI-STRING's callers do."
  (let ((surface (cl-tui-kit/core:make-surface cols rows))
        (rectangle (cl-tui-kit/core:make-rectangle 0 0 cols rows)))
    (nerimux/renderer:render-transient-panel surface rectangle view)
    (nerimux/renderer::%surface-to-ansi-frame surface)))

(describe "renderer-suite/transient"

  (it "computes panel height as title + Arguments section + Actions section + q-back"
    (let ((with-arguments
            (nerimux/renderer:make-transient-view
             :title "Push"
             :arguments (list (list #\f "--force-with-lease" "--force-with-lease" nil #\P)
                              (list #\F "--force" "--force" t #\P))
             :actions (list (list #\p "push to origin/main" nil)
                            (list #\e "push to another remote" nil))))
          (without-arguments
            (nerimux/renderer:make-transient-view
             :title "Fetch"
             :arguments nil
             :actions (list (list #\f "fetch this repository" nil)))))
      ;; 1 title + (1 heading + 2 rows) + 1 heading + 2 rows + 1 q-back = 8.
      (expect (= 8 (nerimux/renderer:transient-view-height with-arguments)))
      ;; No Arguments section at all when ARGUMENTS is empty: 1 + 1 + 1 + 1 = 4.
      (expect (= 4 (nerimux/renderer:transient-view-height without-arguments)))))

  (it "renders an active argument as [x] and an inactive one as [ ]"
    (let* ((view (nerimux/renderer:make-transient-view
                  :title "Push"
                  :subtitle "main -> origin/main"
                  :arguments (list (list #\f "--force-with-lease" "--force-with-lease" nil #\P)
                                   (list #\F "--force" "--force" t #\P))
                  :actions (list (list #\p "push to origin/main" nil))))
           (visible (strip-sgr (%render-transient-panel-output view 60 12))))
      (expect (search "Push" visible))
      (expect (search "main -> origin/main" visible))
      (expect (search "Arguments" visible))
      (expect (search "--force-with-lease" visible))
      (expect (search "[ ]" visible))
      (expect (search "[x]" visible))
      (expect (search "Actions" visible))
      (expect (search "push to origin/main" visible))
      (expect (search "q" visible))
      (expect (search "back" visible))))

  (it "omits the Arguments section entirely when the transient has no arguments"
    (let* ((view (nerimux/renderer:make-transient-view
                  :title "Fetch" :arguments nil
                  :actions (list (list #\f "fetch this repository" nil))))
           (visible (strip-sgr (%render-transient-panel-output view 60 12))))
      (expect (not (search "Arguments" visible)))
      (expect (search "Actions" visible))
      (expect (search "fetch this repository" visible))))

  (it "falls back to a full-screen bordered box when the panel has no room in place"
    (let* ((view (nerimux/renderer:make-transient-view
                  :title "Push" :subtitle "main -> origin/main"
                  :arguments (list (list #\f "--force-with-lease" "--force-with-lease" nil #\P))
                  :actions (list (list #\p "push to origin/main" nil))))
           (output (nerimux/renderer:render-transient-full-screen-to-tui-string view 24 80))
           (visible (strip-sgr output)))
      (expect (stringp output))
      (expect (search "TRANSIENT" visible))
      (expect (search "Push" visible))
      (expect (search "push to origin/main" visible))))

  (it "clips rather than errors when the terminal is too short for every row"
    (let ((view (nerimux/renderer:make-transient-view
                 :title "Push"
                 :arguments (list (list #\f "--force-with-lease" "--force-with-lease" nil #\P))
                 :actions (list (list #\p "push to origin/main" nil)
                                (list #\e "push to another remote" nil)))))
      (expect (stringp (nerimux/renderer:render-transient-full-screen-to-tui-string view 3 40))))))

(describe "renderer-suite/process-log"

  (it "strips C0 control characters before anything is drawn (new trust boundary)"
    (let* ((esc (string (code-char 27)))
           (dirty (concatenate 'string "safe" esc "injected" (string #\Newline) "next")))
      (expect (string= (concatenate 'string "safe" "injected" (string #\Newline) "next")
                       (nerimux/renderer::%process-log-strip-control-characters dirty)))))

  (it "renders a zero-exit and a non-zero-exit entry, visually distinct"
    (let* ((entries (list (list "git push origin main" "0" "everything up to date")
                          (list "git rebase --abort" "1" "error: no rebase in progress")))
           (output (nerimux/renderer:render-process-log-to-tui-string entries 30 100))
           (visible (strip-sgr output)))
      (expect (search "PROCESS LOG" visible))
      (expect (search "git push origin main" visible))
      (expect (search "everything up to date" visible))
      (expect (search "git rebase --abort" visible))
      (expect (search "error: no rebase in progress" visible))
      (expect (search "[0]" visible))
      (expect (search "[1]" visible))
      ;; Zero and non-zero exits are drawn in genuinely different styles,
      ;; not merely different text -- derived from the real style objects
      ;; (renderer-tui-kit-help-tests.lisp's %EXPECTED-SGR-PARAMS pattern)
      ;; rather than hand-computed SGR parameters.
      (expect output :to-contain-sgr
              (%expected-sgr-params (nerimux/renderer::%process-log-exit-ok-style)))
      (expect output :to-contain-sgr
              (%expected-sgr-params (nerimux/renderer::%process-log-exit-fail-style)))))

  (it "neuters a crafted escape sequence into inert text"
    (let* ((esc (string (code-char 27)))
           (malicious (concatenate 'string "line one" esc "[31mFAKE" (string #\Newline) "line two"))
           (entries (list (list "git fetch" "0" malicious)))
           (output (nerimux/renderer:render-process-log-to-tui-string entries 40 100))
           (visible (strip-sgr output)))
      ;; `[31m` surviving as LITERAL TEXT is the whole assertion, and it is
      ;; strictly stronger than counting control bytes. STRIP-SGR removes CSI
      ;; sequences: had the ESC introducer survived, `[31m` would have been
      ;; eaten with it and VISIBLE would read "line oneFAKE". Seeing the
      ;; parameter bytes as text proves the introducer was stripped and the
      ;; remainder is inert.
      ;;
      ;; The obvious alternative -- asserting no character below 32 survives --
      ;; measures the wrong thing twice over: it cannot tell the attacker's SGR
      ;; from the frame's own, and it fires on the CR that
      ;; %SURFACE-TO-ANSI-FRAME writes between every pair of rows on purpose
      ;; (the client tty runs with OPOST off, so CR+LF is deliberate).
      (expect (search "[31mFAKE" visible))
      (expect (search "line one" visible))
      (expect (search "line two" visible))
      ;; No BARE escape byte anywhere: every ESC in a well-formed frame
      ;; introduces a CSI sequence STRIP-SGR consumes whole, so one left over
      ;; is one that did not parse as chrome -- i.e. injected.
      (expect (notany (lambda (character) (char= character (code-char 27)))
                      visible))))

  (it "shows a plain hint instead of an empty box when nothing has run yet"
    (let ((visible (strip-sgr (nerimux/renderer:render-process-log-to-tui-string nil 20 60))))
      (expect (search "no commands run yet" visible))))

  (it "clips rather than errors when the terminal is too short for every entry"
    (let ((entries (list (list "git push" "0" "line one
line two
line three"))))
      (expect (stringp (nerimux/renderer:render-process-log-to-tui-string entries 6 40))))))
