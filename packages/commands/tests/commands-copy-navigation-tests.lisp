(in-package #:nerimux/test/commands)

;;;; copy-mode search-next/search-prev/search-forward/search-backward: outside-copy-mode guards
(describe "commands-suite"

  ;;; ── copy-mode-search-next / copy-mode-search-prev: outside copy mode ────────

  ;; copy-mode-search-next and copy-mode-search-prev are no-ops when not in
  ;; copy mode, even with a saved search term.
  (it "copy-mode-search-next-and-prev-noop-outside-copy-mode-table"
    (dolist (fn '(nerimux/commands::copy-mode-search-next
                  nerimux/commands::copy-mode-search-prev))
      (let ((s (make-screen 20 5)))
        (setf (screen-copy-mode-p s) nil
              (screen-copy-cursor  s) (cons 0 3)
              (nerimux/terminal/types:screen-copy-search-term s) "abc")
        (funcall fn s)
        (expect (equal (cons 0 3) (screen-copy-cursor s))))))

  ;;; ── copy-mode-search-forward / copy-mode-search-backward: guard clause ──────

  ;; Neither search-forward nor search-backward moves the cursor or saves the
  ;; term when the screen is not in copy mode.
  (it "copy-mode-search-forward-and-backward-noop-outside-copy-mode-table"
    (dolist (fn '(nerimux/commands::copy-mode-search-forward
                  nerimux/commands::copy-mode-search-backward))
      (let ((s (make-screen 20 5)))
        (feed s "abc")
        (setf (screen-copy-mode-p s) nil
              (screen-copy-cursor  s) (cons 0 0))
        (funcall fn s "abc")
        (expect (equal (cons 0 0) (screen-copy-cursor s)))
        (expect (null (nerimux/terminal/types:screen-copy-search-term s))))))

  ;; An empty TERM is also a no-op (in copy mode): the guard is
  ;; `(and copy-mode-p term (plusp (length term)))`, so an empty string must
  ;; short-circuit before any cursor movement or term-saving happens.
  (it "copy-mode-search-forward-and-backward-noop-on-empty-term-table"
    (dolist (fn '(nerimux/commands::copy-mode-search-forward
                  nerimux/commands::copy-mode-search-backward))
      (let ((s (make-screen 20 5)))
        (feed s "abc")
        (nerimux/commands::copy-mode-enter s)
        (setf (screen-copy-cursor s) (cons 0 0))
        (funcall fn s "")
        (expect (equal (cons 0 0) (screen-copy-cursor s)))
        (expect (null (nerimux/terminal/types:screen-copy-search-term s)))))))
