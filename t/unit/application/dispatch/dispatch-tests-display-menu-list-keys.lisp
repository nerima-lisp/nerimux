(in-package #:nerimux/test)

;;;; Display-menu and list-keys dispatch cases.

(describe "dispatch-suite"

  ;; display-menu -O keeps the menu open after a selection runs its command;
  ;; without -O the menu closes (tmux -O).
  (it "display-menu-O-keeps-menu-open-after-selection"
    (dolist (row '((t "display-menu -O -T t lbl k \"set-option -g @menu-ran 1\"" "with -O")
                   (nil "display-menu -T t lbl k \"set-option -g @menu-ran 1\"" "without -O")))
      (destructuring-bind (expect-open command desc) row
        (declare (ignore desc))
        (with-fake-session (s)
          (let ((*overlay* nil)
                (nerimux/prompt:*active-menu* nil))
            (nerimux::%run-command-line s command)
            (expect nerimux/prompt:*active-menu* :to-be-truthy)
            (nerimux::dispatch-command s :menu-select 13)
            (expect (string= "1" (nerimux/options:get-option "@menu-ran" nil)))
            (if expect-open
                (expect nerimux/prompt:*active-menu* :to-be-truthy)
                (expect (null nerimux/prompt:*active-menu*))))))))

  ;; list-keys -N lists bindings carrying bind -N notes (with the note text);
  ;; -a additionally includes un-noted bindings.
  (it "list-keys-N-lists-only-noted-bindings"
    (with-isolated-config
     (with-fake-session (s)
      (let ((*overlay* nil))
        (nerimux::%run-command-line
         s "bind -N \"Split the pane\" Y split-window")
        (nerimux::%run-command-line s "bind Z kill-pane")
        (let ((*overlay* nil))
          (nerimux::%run-command-line s "list-keys -N -T prefix")
          (expect (search "Split the pane" *overlay*))
          (expect (null (search "Z " *overlay*))))
        (let ((*overlay* nil))
          (nerimux::%run-command-line s "list-keys -N -a -T prefix")
          (expect (search "Split the pane" *overlay*))
          (expect (search "Z" *overlay*))))))))
