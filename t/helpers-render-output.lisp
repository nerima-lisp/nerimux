;;;; Renderer output helpers for nerimux tests.

(in-package #:nerimux/test)

;;; ── Custom matcher: SGR escape-sequence assertions ──────────────────────────
;;;
;;; Renderer tests repeatedly assert that a rendered frame contains (or omits)
;;; the raw ANSI SGR sequence for a given parameter — previously spelled out
;;; by hand at each call site as (search (format nil "~C[~Am" #\Escape code)
;;; frame).  A cl-weave custom matcher collapses that into a single readable
;;; assertion: (expect frame :to-contain-sgr code) / (expect frame :not
;;; :to-contain-sgr code).
(cl-weave:defmatcher :to-contain-sgr (actual expected)
  "T when ACTUAL contains the SGR escape sequence ESC[CODEm for the given SGR
   CODE (an integer or a compound SGR parameter string, e.g. 42 or
   \"48;2;10;20;30\")."
  (and (search (format nil "~C[~Am" #\Escape (first expected)) actual) t))

(defun render-pane-output (session pane)
  "Render PANE to a string using the production renderer."
  (with-output-to-string (s)
    (nerimux/renderer::render-pane s session pane)))

(defmacro with-copy-mode-render-fixture ((session-var pane-var screen-var w h
                                          &key (content ""))
                                         &body body)
  "Bind a renderer session, its pane, and screen for copy-mode rendering tests.
   Copy-mode position text and line-number gutters have no config surface any
   more (R2.2/R2.3: both were fixed values or retired outright per
   docs/notes/workspace-requirements.md §1.4/§R6.8), so there is nothing left
   to isolate here beyond building the fixture itself."
  `(let* ((,session-var (make-renderer-test-session ,w ,h :content ,content))
          (,pane-var (first (window-panes (session-active-window ,session-var))))
          (,screen-var (pane-screen ,pane-var)))
     ,@body))

(defmacro with-copy-mode-selection-fixture ((session-var pane-var screen-var w h
                                             &key (content "")
                                                  (mark-row nil)
                                                  (mark-col nil)
                                                  (cursor-row nil)
                                                  (cursor-col nil)
                                                  (selecting-p t)
                                                  (copy-mode-p t))
                                            &body body)
  "Bind a copy-mode renderer fixture with selection state preconfigured."
  `(with-copy-mode-render-fixture (,session-var ,pane-var ,screen-var ,w ,h
                                   :content ,content)
     (setf (screen-copy-mode-p ,screen-var) ,copy-mode-p
           (screen-copy-selecting ,screen-var) ,selecting-p
           (screen-copy-offset ,screen-var) 0
           (screen-copy-mark ,screen-var)
           (and ,mark-row ,mark-col (cons ,mark-row ,mark-col))
           (screen-copy-cursor ,screen-var)
           (and ,cursor-row ,cursor-col (cons ,cursor-row ,cursor-col)))
     ,@body))

(defun render-status-bar-output (sess rows cols &key ((:status-row status-row)
                                                     nil
                                                     status-row-supplied-p))
  "Render the status bar for SESS to a string using the production renderer."
  (with-output-to-string (s)
    (if status-row-supplied-p
        (nerimux/renderer::render-status-bar s sess rows cols :status-row status-row)
        (nerimux/renderer::render-status-bar s sess rows cols))))

(defun render-overlay-output (width height)
  "Render the current overlay to a string using the production renderer."
  (with-output-to-string (buf)
    (nerimux/renderer::render-overlay buf width height)))

(defun render-tree-borders-output (tree active-pane width)
  "Render TREE borders for ACTIVE-PANE to a string using the production renderer."
  (with-output-to-string (s)
    (nerimux/renderer::render-tree-borders s tree active-pane width)))

(defmacro check-status-segment-clamp-cases (cases)
  "Assert %clamp-status-segment rows shaped (TEXT MAX EXPECTED DESC)."
  `(check-table
    (mapcar (lambda (row)
              (destructuring-bind (text max expected desc) row
                (list (nerimux/renderer::%clamp-status-segment text max)
                      expected
                      desc)))
            ,cases)
    :test #'string=))

(defmacro check-visible-truncate-cases (cases)
  "Assert %visible-truncate rows shaped (INPUT MAX EXPECTED DESC)."
  `(check-table
    (mapcar (lambda (row)
              (destructuring-bind (input max expected desc) row
                (list (nerimux/renderer::%visible-truncate input max)
                      expected
                      desc)))
            ,cases)
    :test #'string=))

(defmacro check-status-style-reset-cases (base-sgr bodies)
  "Assert %status-style-block-sgr reset cases against BASE-SGR."
  `(let ((base-sgr ,base-sgr))
     (check-table
      (mapcar (lambda (body)
                (list (nerimux/renderer::%status-style-block-sgr body base-sgr)
                      (format nil "~C[0;~Am" #\Escape base-sgr)
                      (format nil "~S must reset to base SGR" body)))
              ,bodies)
      :test #'string=)))

(defmacro check-status-expand-unchanged-cases (base-sgr inputs)
  "Assert %status-expand-style-blocks returns block-free INPUTS unchanged."
  `(let ((base-sgr ,base-sgr))
     (check-table
      (mapcar (lambda (input)
                (list (nerimux/renderer::%status-expand-style-blocks input base-sgr)
                      input
                      (format nil "~S has no inline style block" input)))
              ,inputs)
      :test #'string=)))
