(in-package #:nerimux/renderer)

(defun %workspace-prefix-label (code)
  (if (and (integerp code) (<= 1 code) (<= code 26))
      (format nil "C-~A" (code-char (+ (char-code #\a) (1- code))))
      (format nil "key/~D" code)))

(defun %workspace-hint (key description)
  "One footer hint: KEY in bold accent, DESCRIPTION muted."
  (format nil
          "~A ~A"
          (%sgr-wrap key +sgr-accent-bold+)
          (%sgr-wrap description +sgr-muted+)))

(defparameter *workspace-footer-hints*
  '(("n/p" "select")
    ("Enter" "open")
    ("Tab" "expand")
    ("g" "refresh")
    ("/" "filter")
    (":" "command")
    ("?" "menu"))
  "Static key hints rendered in the workspace overview footer.")

(defun %workspace-footer-line (mode prefix-code &optional tree-filter)
  "The overview footer: a mode chip followed by two-tone key hints."
  (format nil
          " ~A~A  ~{~A~^  ~}"
          (if (plusp (length (or tree-filter "")))
              (format nil "~A  "
                      (%sgr-wrap (format nil "/~A" tree-filter) +sgr-muted+))
              "")
          (%sgr-wrap (format nil " ~:@(~A~) " mode) +sgr-mode-chip+)
          (append (mapcar (lambda (hint)
                            (apply #'%workspace-hint hint))
                          *workspace-footer-hints*)
                  (list
                   (%workspace-hint
                    (format nil "~A d" (%workspace-prefix-label prefix-code))
                    "detach")))))

(defun %workspace-key-panel-content (selected-object mode prefix-code tree-filter)
  "Return the two key-panel content lines for SELECTED-OBJECT."
  (values
   (format nil " ~{~A~^  ~}"
           (cond
             ((keywordp selected-object)
              (list (%workspace-hint "Enter/Tab" "fold")
                    (%workspace-hint "M-n/M-p" "section")
                    (%workspace-hint "1-4" "level")
                    (%workspace-hint "/" "filter")
                    (%workspace-hint "C-p" "picker")
                    (%workspace-hint "g" "refresh")))
             ((typep selected-object 'repository)
              (list (%workspace-hint "Enter" "shell(main)")
                    (%workspace-hint "Tab" "expand")
                    (%workspace-hint "w" "worktree menu")
                    (%workspace-hint "f" "fetch menu")))
             ((and (consp selected-object) (eq (first selected-object) :file))
              (list (%workspace-hint "Tab" "diff")
                    (%workspace-hint "s/u" "stage")
                    (%workspace-hint "k" "discard")
                    (%workspace-hint "n/p" "move")))
             ((and (consp selected-object)
                   (member (first selected-object) '(:diff-line :diff-more)))
              (list (%workspace-hint "n/p" "move")))
             ((and (consp selected-object) (eq (first selected-object) :commit))
              (list (%workspace-hint "n/p" "select")
                    (%workspace-hint "Tab" "diff")))
             ((typep selected-object 'pane)
              (list (%workspace-hint "Enter" "focus")
                    (%workspace-hint "n/p" "select")))
             (t
              (list (%workspace-hint "Enter" "shell")
                    (%workspace-hint "Tab" "expand")
                    (%workspace-hint "w" "worktree menu")
                    (%workspace-hint "c/P/F" "commit/push/pull")
                    (%workspace-hint "g" "refresh")))))
   (format nil " ~A~A  ~{~A~^  ~}"
           (if (plusp (length (or tree-filter "")))
               (format nil "~A  " (%sgr-wrap (format nil "/~A" tree-filter) +sgr-muted+))
               "")
           (%sgr-wrap (format nil " ~:@(~A~) " mode) +sgr-mode-chip+)
           (list (%workspace-hint "q" "back")
                 (%workspace-hint "?" "menu")
                 (%workspace-hint "$" "log")
                 (%workspace-hint ":" "command")
                 (%workspace-hint (format nil "~A w" (%workspace-prefix-label prefix-code))
                                  "status")
                 (%workspace-hint (format nil "~A d" (%workspace-prefix-label prefix-code))
                                  "detach")))))
