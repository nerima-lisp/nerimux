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

(defun %workspace-footer-line (mode prefix-code &optional tree-filter)
  "The overview footer: a mode chip followed by two-tone key hints."
  (format nil
          " ~A~A  ~{~A~^  ~}"
          (if (plusp (length (or tree-filter "")))
              (format nil "~A  " (%sgr-wrap (format nil "/~A" tree-filter) +sgr-muted+))
              "")
          (%sgr-wrap (format nil " ~:@(~A~) " mode) +sgr-mode-chip+)
          (append
           (when (eq mode :repolist)
             (list (%workspace-hint "n" "create+assign")
                   (%workspace-hint "a" "assign")))
           (list (%workspace-hint (if (eq mode :repolist) "Down/p" "n/p") "select")
                 (%workspace-hint "Enter" "agent>terminal>assign")
                 (%workspace-hint "Tab" "expand")
                 (%workspace-hint "g" "refresh")
                 (%workspace-hint "/" "filter")
                 (%workspace-hint ":" "command")
                 (%workspace-hint "?" "menu")
                 (%workspace-hint
                  (format nil "~A d" (%workspace-prefix-label prefix-code))
                  "detach")))))

(defun %workspace-key-panel-content (selected-object mode prefix-code tree-filter)
  "Two values -- the key panel's two content lines -- switching on
   SELECTED-OBJECT's row kind."
  (values
   (format nil " ~{~A~^  ~}"
           (append
            (when (eq mode :repolist)
              (list (%workspace-hint "n" "create+assign")
                    (%workspace-hint "a" "assign")))
            (cond
             ((keywordp selected-object)
              (list (%workspace-hint "Enter/Tab" "fold")
                    (%workspace-hint "M-n/M-p" "section")
                    (%workspace-hint "1-4" "level")
                    (%workspace-hint "/" "filter")
                    (%workspace-hint "C-p" "picker")
                    (%workspace-hint "g" "refresh")))
             ((typep selected-object 'repository)
              (list (%workspace-hint "Enter" "main:agent>terminal>assign")
                    (%workspace-hint "Tab" "expand")
                    (%workspace-hint "w" "worktree menu")
                    (%workspace-hint "f" "fetch menu")))
             ((and (consp selected-object) (eq (first selected-object) :file))
              (list (%workspace-hint "Tab" "diff")
                    (%workspace-hint "s/u" "stage")
                    (%workspace-hint "k" "discard")
                    (%workspace-hint (if (eq mode :repolist) "Down/p" "n/p") "move")))
             ((and (consp selected-object)
                   (member (first selected-object) '(:diff-line :diff-more)))
              (list (%workspace-hint (if (eq mode :repolist) "Down/p" "n/p") "move")))
             ((and (consp selected-object) (eq (first selected-object) :commit))
              (list (%workspace-hint (if (eq mode :repolist) "Down/p" "n/p") "select")
                    (%workspace-hint "Tab" "diff")))
             ((typep selected-object 'pane)
              (list (%workspace-hint "Enter" "focus")
                    (%workspace-hint (if (eq mode :repolist) "Down/p" "n/p") "select")))
             (t
              (list (%workspace-hint "Enter" "agent>terminal>assign")
                    (%workspace-hint "Tab" "expand")
                    (%workspace-hint "w" "worktree menu")
                    (if (eq mode :repolist)
                        (%workspace-hint "c/x" "Claude/Codex")
                        (%workspace-hint "c/P/F" "commit/push/pull"))
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
                                  "detach"))))))
