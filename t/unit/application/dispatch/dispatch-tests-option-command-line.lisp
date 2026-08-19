(in-package #:nerimux/test)

;;;; Dispatch set-option command-line tests.

(describe "dispatch-suite"

  ;; 'set-option monitor-activity off' stores NIL and 'set-option ... on' stores T (type-coerced).
  ;; Uses monitor-activity — a side-effect-free :boolean option — because `status` is
  ;; now a choice/string option (off|on|2..5), not a boolean.
  (it "run-command-line-set-option-coerces-boolean"
    (with-fake-session (s)
      (with-isolated-options ()
        (nerimux::%run-command-line s "set-option -g monitor-activity off")
        (expect (null (nerimux/options:get-option "monitor-activity")))
        (nerimux::%run-command-line s "set-option -g monitor-activity on")
        (expect (eq t (nerimux/options:get-option "monitor-activity"))))))

  ;; 'set-option' stores string option values, and a quoted value keeps its spaces/format.
  (it "run-command-line-set-option-string-and-quoted"
    (with-fake-session (s)
      (with-isolated-options ()
        (nerimux::%run-command-line s "set-option status-left bar")
        (expect (string= "bar" (nerimux/options:get-option "status-left")))
        (nerimux::%run-command-line s "set-option status-left \"#{session_name} x\"")
        (expect (string= "#{session_name} x" (nerimux/options:get-option "status-left"))))))

  ;; 'set-option -g status off' sets the 'status' option (not an option literally named
  ;; '-g') — the canonical tmux form must work.
  (it "run-command-line-set-option-scope-flag"
    (with-option-session (s)
      (nerimux::%run-command-line s "set-option -g status off")
      (expect (string= "off" (nerimux/options:get-option "status")))
      (expect (null (nerimux/options:get-option "-g")))))

  ;; %with-option-scope routes the -s flag to :server scope with a NIL target
  ;; (audit #9: -s previously fell through to :global).
  (it "with-option-scope-s-flag-selects-server-scope"
    (let ((scope-seen nil)
          (target-seen :unset))
      (nerimux::%with-option-scope (make-fake-session) '((#\s . t)) nil nil
                                   (lambda (scope target)
                                     (setf scope-seen scope
                                           target-seen target)))
      (expect (eq :server scope-seen))
      (expect (null target-seen))))

  ;; %scope-set with :server scope writes the server option store, readable via
  ;; get-server-option (audit #9 end-to-end: server routing reaches the store).
  ;; Uses the real store with restore — mirroring the config-path server tests —
  ;; because rebinding *server-options* in a test unit does not reliably shadow the
  ;; accessor's special binding.
  (it "scope-set-server-writes-server-store"
    (let ((original (nerimux/options:get-server-option "escape-time")))
      (unwind-protect
           (progn
             (nerimux::%scope-set "escape-time" "250" :server nil)
             (expect (eql 250 (nerimux/options:get-server-option "escape-time"))))
        (nerimux/options:set-server-option "escape-time" (or original 10)))))

  ;; 'set-option -a <name> <value>' appends to the option's current value.
  (it "run-command-line-set-option-append-flag"
    (with-fake-session (s)
      (with-isolated-options ("status-left" "A")
        (nerimux::%run-command-line s "set-option -a status-left B")
        (expect (string= "AB" (nerimux/options:get-option "status-left"))))))

  ;; Runtime dispatch accepts canonical option commands only.
  (it "run-command-line-set-option-short-aliases-are-rejected"
    (with-fake-session (s)
      (with-isolated-options ("status-left" "ORIG")
        (let ((*overlay* nil))
          (expect (null (nerimux::%run-command-line s "set -g status-left YES")))
          (expect (string= "ORIG" (nerimux/options:get-option "status-left")))
          (assert-overlay-active "set must show an error overlay"))))
    (with-fake-session (s :nwindows 1)
      (let ((*overlay* nil))
        (let ((win (session-active-window s)))
          (expect (null (nerimux::%run-command-line s "setw mode-keys vi")))
          (expect (not (nth-value 1 (gethash "mode-keys"
                                             (nerimux/model:window-local-options win)))))
          (assert-overlay-active "setw must show an error overlay")))))

  ;; set-option and set-window-option reject unknown flags before mutating option stores.
  (it "run-command-line-set-option-rejects-unsupported-flags"
    (with-fake-session (s)
      (with-isolated-options ("status-left" "ORIG")
        (let ((*overlay* nil))
          (expect (null (nerimux::%run-command-line s "set-option -x status-left bad")))
          (expect (string= "ORIG" (nerimux/options:get-option "status-left")))
          (assert-overlay-contains "unsupported argument" *overlay*
                                    "set-option -x"))))
    (with-fake-session (s :nwindows 1)
      (let ((nerimux/options:*global-options* (make-hash-table :test #'equal))
            (*overlay* nil))
        (let ((win (session-active-window s)))
          (expect (null (nerimux::%run-command-line s "set-window-option -x mode-keys vi")))
          (expect (not (nth-value 1 (gethash "mode-keys"
                                             (nerimux/model:window-local-options win)))))
          (assert-overlay-active "set-window-option -x must show an error overlay"))))))
