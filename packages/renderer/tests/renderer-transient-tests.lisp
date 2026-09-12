(in-package #:nerimux/test/renderer)

(defun %render-transient-panel-output (view cols rows)
  "Draw VIEW into a fresh COLS x ROWS surface and return the plain ANSI
   frame -- RENDER-TRANSIENT-PANEL itself draws onto a caller-owned surface
   rather than returning a string, so tests need this much setup to see its
   output the way RENDER-TRANSIENT-FULL-SCREEN-TO-TUI-STRING's callers do."
  (let ((surface (cl-tui-kit/core:make-surface cols rows))
        (rectangle (cl-tui-kit/core:make-rectangle 0 0 cols rows)))
    (nerimux/renderer:render-transient-panel surface rectangle view)
    (nerimux/renderer::%surface-to-ansi-frame surface)))

(defun %transient-panel-rows (view cols rows)
  "VIEW drawn into a fresh surface, one string per row. The ANSI frame cannot
   answer a question about rows: its own row separators are cursor moves,
   which STRIP-SGR removes."
  (let ((surface (cl-tui-kit/core:make-surface cols rows))
        (rectangle (cl-tui-kit/core:make-rectangle 0 0 cols rows)))
    (nerimux/renderer:render-transient-panel surface rectangle view)
    (uiop:split-string (cl-tui-kit/core:surface-string surface)
                       :separator (list #\Newline))))

(defun %frame-rows (frame rows cols)
  "FRAME parsed back into one string per row."
  (uiop:split-string (cl-tui-kit/core:surface-string
                      (nerimux/renderer::%surface-from-ansi-frame frame
                                                                  rows
                                                                  cols))
                     :separator (list #\Newline)))

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
      (expect (= 8 (nerimux/renderer:transient-view-height with-arguments)))
      (expect (= 4 (nerimux/renderer:transient-view-height without-arguments)))))

  (it "renders arguments as -key flag, highlighting the active ones"
    (let* ((view (nerimux/renderer:make-transient-view
                  :title "Push"
                  :subtitle "main -> origin/main"
                  :arguments (list (list #\f "--force-with-lease" "--force-with-lease" nil #\P)
                                   (list #\F "--force" "--force" t #\P))
                  :actions (list (list #\p "push to origin/main" nil))))
           (output (%render-transient-panel-output view 60 12))
           (visible (strip-sgr output)))
      (expect (search "Push" visible))
      (expect (search "main -> origin/main" visible))
      (expect (search "Arguments" visible))
      (expect (search "-f  --force-with-lease" visible))
      (expect (not (search "[ ]" visible)))
      (expect (not (search "[x]" visible)))
      (expect output :to-contain-sgr
              (%expected-sgr-params (nerimux/renderer::%transient-argument-active-style)))
      (expect output :to-contain-sgr
              (%expected-sgr-params (nerimux/renderer::%transient-argument-inactive-style)))
      (expect (search "Actions" visible))
      (expect (search "push to origin/main" visible))
      (expect (search "q" visible))
      (expect (search "back" visible))))

  (it "lays the actions out in two columns when both fit, and one when they do not"
    (let ((view (nerimux/renderer:make-transient-view
                 :title "Dispatch"
                 :actions (list (list #\c "commit" nil)
                                (list #\P "push" nil)
                                (list #\F "pull" nil)
                                (list #\b "branch" nil)))))
      (let ((actions (nerimux/renderer:transient-view-actions view)))
        (expect (= 1 (nerimux/renderer::%transient-action-columns actions 0)))
        (expect (= 2 (nerimux/renderer::%transient-action-columns actions 60))))
      (expect (= 6 (nerimux/renderer:transient-view-height view nil 0)))
      (expect (= 4 (nerimux/renderer:transient-view-height view nil 60)))
      (let ((rows (%transient-panel-rows view 60 8)))
        (expect (find-if
                 (lambda (line)
                   (and (search "commit" line) (search "pull" line)))
                 rows)))))

  (it "omits the Arguments section entirely when the transient has no arguments"
    (let* ((view (nerimux/renderer:make-transient-view
                  :title "Fetch" :arguments nil
                  :actions (list (list #\f "fetch this repository" nil))))
           (visible (strip-sgr (%render-transient-panel-output view 60 12))))
      (expect (not (search "Arguments" visible)))
      (expect (search "Actions" visible))
      (expect (search "fetch this repository" visible))))

  (it "draws a bottom-anchored panel titled after the transient, not a full-screen box"
    (let* ((view (nerimux/renderer:make-transient-view
                  :title "Push" :subtitle "main -> origin/main"
                  :arguments (list (list #\f "--force-with-lease" "--force-with-lease" nil #\P))
                  :actions (list (list #\p "push to origin/main" nil))))
           (output (nerimux/renderer:render-transient-panel-to-tui-string view 24 80))
           (rows (%frame-rows output 24 80))
           (visible (strip-sgr output)))
      (expect (stringp output))
      (expect (not (search "TRANSIENT" visible)))
      (expect (search " Push " (nth 16 rows)))
      (expect (search "push to origin/main" visible))
      (expect (every (lambda (line) (every (lambda (c) (char= c #\Space)) line))
                     (subseq rows 0 16)))))

  (it "keeps the view it was opened from visible above the panel"
    (let* ((view (nerimux/renderer:make-transient-view
                  :title "Worktree" :arguments nil
                  :actions (list (list #\c "create" nil))))
           (base (nerimux/renderer::%surface-to-ansi-frame
                  (let ((surface (cl-tui-kit/core:make-surface 40 10)))
                    (cl-tui-kit/core:surface-draw-text surface 0 0 "repolist row")
                    surface)))
           (rows (%frame-rows
                  (nerimux/renderer:render-transient-panel-to-tui-string
                   view 10 40 base)
                  10 40)))
      (expect (search "repolist row" (first rows)))
      (expect (search " Worktree " (nth 5 rows)))
      (expect (search "create" (nth 7 rows)))))

  (it "clips rather than errors when the terminal is too short for every row"
    (let ((view (nerimux/renderer:make-transient-view
                 :title "Push"
                 :arguments (list (list #\f "--force-with-lease" "--force-with-lease" nil #\P))
                 :actions (list (list #\p "push to origin/main" nil)
                                (list #\e "push to another remote" nil)))))
      (expect (stringp (nerimux/renderer:render-transient-panel-to-tui-string view 3 40))))))

(describe "renderer-suite/prompt-panels"

  (it "puts a one-line prompt in a four-row panel showing the whole placeholder"
    (let* ((widget (cl-tui-kit/widgets:make-input-widget
                    :placeholder "branch name" :focusable-p t))
           (rows (%frame-rows
                  (nerimux/renderer:render-text-prompt-to-tui-string
                   "Create branch" widget 20 60)
                  20 60)))
      (expect (search " Create branch " (nth 16 rows)))
      (expect (search "branch name" (nth 17 rows)))
      (expect (search "Enter submit  Esc cancel" (nth 18 rows)))
      (expect (every (lambda (line) (every (lambda (c) (char= c #\Space)) line))
                     (subseq rows 0 16)))))

  (it "gives the multiline commit prompt eight rows and its placeholder"
    (let* ((widget (cl-tui-kit/widgets:make-textarea-widget
                    :placeholder "commit message" :preferred-rows 6
                    :submit-on-enter-p nil :focusable-p t))
           (rows (%frame-rows
                  (nerimux/renderer:render-text-prompt-to-tui-string
                   "Commit message" widget 20 60)
                  20 60)))
      (expect (search " Commit message " (nth 12 rows)))
      (expect (search "commit message" (nth 13 rows)))
      (expect (search "C-s submit  Enter newline  Esc cancel" (nth 18 rows)))
      (expect (every (lambda (line) (every (lambda (c) (char= c #\Space)) line))
                     (subseq rows 0 12)))))

  (it "draws the message strip inside the panel, above the keys that end it"
    (let* ((widget (cl-tui-kit/widgets:make-input-widget
                    :placeholder "branch name" :focusable-p t))
           (rows (%frame-rows
                  (nerimux/renderer:render-text-prompt-to-tui-string
                   "Create branch" widget 20 60 nil (list "value required"))
                  20 60)))
      (expect (search " Create branch " (nth 15 rows)))
      (expect (search "value required" (nth 17 rows)))
      (expect (search "Enter submit  Esc cancel" (nth 18 rows)))))

  (it "keeps the view that asked visible above the prompt panel"
    (let* ((widget (cl-tui-kit/widgets:make-input-widget
                    :placeholder "branch name" :focusable-p t))
           (base (nerimux/renderer::%surface-to-ansi-frame
                  (let ((surface (cl-tui-kit/core:make-surface 60 20)))
                    (cl-tui-kit/core:surface-draw-text surface 0 0 "status buffer")
                    surface)))
           (rows (%frame-rows
                  (nerimux/renderer:render-text-prompt-to-tui-string
                   "Create branch" widget 20 60 base)
                  20 60)))
      (expect (search "status buffer" (first rows)))
      (expect (search " Create branch " (nth 16 rows)))))

  (it "shows the read view's search query as it is typed, with the keys that end it"
    (let* ((view (nerimux/renderer:make-read-view "LOG" "line one
line two"))
           (widget (cl-tui-kit/widgets:make-input-widget
                    :value "number 3" :focusable-p t))
           (rows (%frame-rows
                  (nerimux/renderer:render-read-view-to-tui-string view
                                                                   20
                                                                   60
                                                                   widget)
                  20 60)))
      (expect (search " Search " (nth 16 rows)))
      (expect (search "number 3" (nth 17 rows)))
      (expect (search "Enter accept  Esc cancel" (nth 18 rows)))
      (expect (search "line one" (nth 2 rows))))))

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
      (expect (search "exit 0" visible))
      (expect (search "exit 1" visible))
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
      (expect (search "[31mFAKE" visible))
      (expect (search "line one" visible))
      (expect (search "line two" visible))
      (expect (notany (lambda (character) (char= character (code-char 27)))
                      visible))))

  (it "draws no output row for an entry whose command printed nothing"
    (expect (null (nerimux/renderer::%process-log-output-lines "")))
    (expect (null (nerimux/renderer::%process-log-output-lines nil)))
    (expect (equal '("one" "two")
                   (nerimux/renderer::%process-log-output-lines
                    (format nil "one~%two")))))

  (it "shows a plain hint instead of an empty box when nothing has run yet"
    (let ((visible (strip-sgr (nerimux/renderer:render-process-log-to-tui-string nil 20 60))))
      (expect (search "no commands run yet" visible))))

  (it "clips rather than errors when the terminal is too short for every entry"
    (let ((entries (list (list "git push" "0" "line one
line two
line three"))))
      (expect (stringp (nerimux/renderer:render-process-log-to-tui-string entries 6 40))))))
