(in-package #:nerimux/test)

;;;; Help view menu keys against the transient table.
;;;;
;;;; Moved out of packages/renderer/tests/renderer-tui-kit-help-tests.lisp when
;;;; presentation/renderer became nerimux-renderer. The assertion compares the
;;;; renderer help sections against nerimux::+transient-definitions+, which is
;;;; BOOTSTRAP data -- checking the two agree is precisely a cross-layer claim.
(describe "renderer-help-transient-agreement-suite"

  ;; The help text is hand-written strings, so it drifts from the dispatch
  ;; tables silently -- it already did once, surviving the whole magit keymap
  ;; replacement while still advertising j/k, r, i, c and a "Modes" section.
  ;; Only one of the tables it documents is machine-readable data rather than a
  ;; COND over byte codes, so only this part can be checked mechanically; that
  ;; makes it worth checking rather than not.
  (it "every menu key the help advertises actually opens a transient"
    (let* ((section (find "Menus (?)" nerimux/renderer::+help-view-sections+
                          :key #'first :test #'string=))
           (advertised (mapcar #'car (second section))))
      (expect (plusp (length advertised)))
      (dolist (key advertised)
        ;; The help spells keys as strings, the table keys on characters.
        (expect (assoc (char key 0) nerimux::+transient-definitions+
                       :test #'char=)))))
)
