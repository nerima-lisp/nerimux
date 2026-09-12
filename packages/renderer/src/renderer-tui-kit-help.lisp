(in-package #:nerimux/renderer)

(defparameter +help-view-sections+
  '(("Navigate (repolist and status)"
     (("n/p" . "move") ("Up/Down" . "move")
                       ("M-n/M-p" . "section")
                       ("Tab" . "expand")
                       ("Right/Left" . "expand/collapse")
                       ("S-Tab" . "cycle all")
                       ("1-4" . "detail level")
                       ("Enter" . "agent>terminal>assign")
                       ("q" . "back")
                       ("Esc" . "close")
                       ("g" . "refresh")
                       ("/" . "filter")
                       (":" . "command")
                       ("C-p" . "picker")
                       ("$" . "process log")
                       ("?" . "menu")
                       ("? k" . "this help")))
    ("Repolist"
     (("a" . "assign agent") ("v" . "status")
                             ("t" . "terminal")
                             ("c" . "Claude")
                             ("x" . "Codex")
                             ("?" . "commit/tag menus")))
    ("Status"
     (("s/S" . "stage") ("u/U" . "unstage")
                        ("k" . "discard")
                        ("c" . "commit")
                        ("t" . "tag")
                        ("!" . "shell command")))
    ("Menus (?)"
     (("c" . "commit") ("P" . "push")
                       ("F" . "pull")
                       ("b" . "branch")
                       ("m" . "merge")
                       ("r" . "rebase")
                       ("z" . "stash")
                       ("l" . "log")
                       ("d" . "diff")
                       ("f" . "fetch")
                       ("t" . "tag")
                       ("X" . "reset")
                       ("w" . "worktree")
                       ("!" . "shell command")))
    ("Worktree menu (w)"
     (("c" . "create+shell") ("n" . "create+agent")
                             ("a" . "assign agent")
                             ("k" . "delete")
                             ("l" . "lock")
                             ("u" . "unlock")
                             ("C" . "toggle complete")
                             ("p" . "prune")
                             ("P" . "prune all")
                             ("b" . "branch name")))
    ("Prefix C-q"
     (("-" . "split down") ("|" . "split right")
                           ("< / >" . "width")
                           ("{ / }" . "height")
                           ("x" . "close pane")
                           ("z" . "zoom")
                           ("h/j/k/l" . "focus")
                           ("n/p" . "cycle window")
                           ("t" . "new shell window")
                           ("w" . "repolist")
                           ("K" . "stop workspace agent")
                           ("[" . "scrollback")
                           ("d" . "detach")
                           ("C-q" . "drop modal")
                           ("Q" . "quit server")))
    ("Scrollback (C-q [)"
     (("j/k" . "line") ("C-u/C-d" . "half page")
                       ("g/G" . "top/bottom")
                       ("/" . "search")
                       ("?" . "search back")
                       ("n/N" . "next/prev")
                       ("Space" . "select")
                       ("y" . "yank+exit")
                       ("q" . "exit")))
    ("Panes"
     (("" . "typing goes straight to the shell -- no mode to enter first")
      ("" . "every nerimux key inside a pane starts with C-q"))))
  "The help view's static content: (SECTION-HEADING BINDINGS), BINDINGS a
   list of (KEY . DESCRIPTION). An empty KEY is a prose line rather than a
   binding; %HELP-VIEW-BINDING-TEXT formats it the same way, which just leaves
   a leading space.")

(defun %help-view-heading-style ()
  (cl-tui-kit/core:make-style :bold
                              t
                              :foreground
                              (cl-tui-kit/core:rgb-color 189 147 249)))

(defun %help-view-key-style ()
  (cl-tui-kit/core:make-style :foreground
                              (cl-tui-kit/core:rgb-color 139 233 253)))

(defun %help-view-binding-text (key description)
  (format nil "~A ~A" key description))

(defun %help-view-section-item-width (bindings)
  "One item's column width: its longest 'KEY DESCRIPTION' pair plus a 2-column
   gutter, so a section of short Overview/Prefix bindings packs several per
   row while Modes' long descriptions still get a row of their own -- no
   fixed magic-number column width to keep in sync with the content above."
  (+ 2
     (reduce #'max
             bindings
             :key
             (lambda (binding)
               (%display-width
                (%help-view-binding-text (car binding) (cdr binding))))
             :initial-value
             0)))

(defun %help-view-section-columns (bindings available-width)
  (max 1
       (min 4
            (floor (max 1 available-width)
                   (%help-view-section-item-width bindings)))))

(defun %draw-help-view-heading (surface row col text width)
  (cl-tui-kit/core:surface-draw-styled-text surface
                                            col
                                            row
                                            (list
                                             (cl-tui-kit/core:make-text-span
                                              text
                                              :style
                                              (%help-view-heading-style)))
                                            :max-width
                                            width))

(defun %draw-help-view-binding (surface row col key description width)
  (cl-tui-kit/core:surface-draw-styled-text surface
                                            col
                                            row
                                            (list
                                             (cl-tui-kit/core:make-text-span key
                                                                             :style
                                                                             (%help-view-key-style))
                                             (cl-tui-kit/core:make-text-span
                                              (format nil " ~A" description)))
                                            :max-width
                                            width))

(defun %draw-help-view-section (surface row
                                        indent
                                        available-width
                                        max-row
                                        section)
  "Draw SECTION -- (HEADING BINDINGS) -- starting at ROW, indented INDENT
   columns, wrapping BINDINGS into %HELP-VIEW-SECTION-COLUMNS side-by-side
   item columns. Returns the next free row: sections sit directly on top of
   each other, because the full binding list fits a 40-row terminal only
   without a blank line between them, and the styled heading already separates
   them. Drawing stops (silently clipping any remainder) once ROW exceeds
   MAX-ROW -- the box's bottom border row -- rather than overflowing it; this
   view has no scroll of its own."
  (destructuring-bind (heading bindings) section
    (when (<= row max-row)
      (%draw-help-view-heading surface row indent heading available-width)
      (incf row))
    (let* ((item-width (%help-view-section-item-width bindings))
           (columns (%help-view-section-columns bindings available-width)))
      (loop for start from 0 below (length bindings) by columns
            while (<= row max-row)
            do (loop for offset from 0 below columns
                     for index = (+ start offset)
                     while (< index (length bindings))
                     do (destructuring-bind (key . description) 
                            (nth index bindings)
                          (%draw-help-view-binding surface
                                                   row
                                                   (+ indent
                                                      (* offset item-width))
                                                   key
                                                   description
                                                   item-width))) (incf row)))
    row))

(defun %render-help-view-box (surface rectangle)
  (let ((box
         (cl-tui-kit/widgets:make-box-widget
          (cl-tui-kit/widgets:make-text-widget "" :id :nerimux-help-body)
          :id
          :nerimux-help-box
          :border-kind
          :single)))
    (cl-tui-kit/widgets:render-widget box surface rectangle)))

(defun %stamp-help-view-title (surface rectangle title)
  (let* ((inner-width (max 0 (- (cl-tui-kit/core:rectangle-width rectangle) 4)))
         (text (%display-clip (format nil " ~A " title) inner-width)))
    (cl-tui-kit/core:surface-draw-text surface
                                       (+
                                        (cl-tui-kit/core:rectangle-x rectangle)
                                        2)
                                       (cl-tui-kit/core:rectangle-y rectangle)
                                       text)))

(defun %stamp-help-view-footer (surface rectangle hint)
  (let* ((width (cl-tui-kit/core:rectangle-width rectangle))
         (text (%display-clip (format nil " ~A " hint) (max 0 (- width 4))))
         (x
          (max (+ (cl-tui-kit/core:rectangle-x rectangle) 2)
               (- (+ (cl-tui-kit/core:rectangle-x rectangle) width)
                  2
                  (%display-width text)))))
    (cl-tui-kit/core:surface-draw-text surface
                                       x
                                       (+
                                        (cl-tui-kit/core:rectangle-y rectangle)
                                        (1-
                                         (cl-tui-kit/core:rectangle-height
                                          rectangle)))
                                       text)))

(defun render-help-view-to-tui-string (rows cols)
  "Render the `?` full-screen help view: a Dracula-styled static reference
   covering the overview/detail keymap, the C-q prefix table, and each UI
   mode's enter/leave key."
  (let* ((rows (max 1 rows))
         (cols (max 1 cols))
         (surface (cl-tui-kit/core:make-surface cols rows))
         (rectangle (cl-tui-kit/core:make-rectangle 0 0 cols rows))
         (inner (%box-widget-inner-rectangle rectangle))
         (indent (cl-tui-kit/core:rectangle-x inner))
         (available-width (cl-tui-kit/core:rectangle-width inner))
         (max-row
          (max (cl-tui-kit/core:rectangle-y inner)
               (1-
                (+ (cl-tui-kit/core:rectangle-y inner)
                   (cl-tui-kit/core:rectangle-height inner))))))
    (%render-help-view-box surface rectangle)
    (%stamp-help-view-title surface rectangle "HELP")
    (%stamp-help-view-footer surface rectangle "q / ? / Enter / Esc close")
    (let ((row (cl-tui-kit/core:rectangle-y inner)))
      (dolist (section +help-view-sections+)
        (setf row (%draw-help-view-section surface
                                           row
                                           indent
                                           available-width
                                           max-row
                                           section))))
    (%surface-to-ansi-frame surface)))
