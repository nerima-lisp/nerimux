(in-package #:nerimux/test)

;;;; config directive suite, basic apply/set directives — part I
;;;;
;;;; *bindable-commands*, apply-directive-bind-returns-t,
;;;; apply-directive-unknown-returns-nil, and
;;;; set-mouse-invokes-mouse-reporting-hook were removed: all asserted
;;;; key-table effects (lookup-key-binding / ensure-key-table) or, for the
;;;; mouse hook, an effect the directive no longer produces now that the
;;;; key-table config subsystem is gone.

;;; Import the config-directives symbols we need

(eval-when (:compile-toplevel :load-toplevel :execute)
  (import '(nerimux/config:apply-config-directive
            nerimux/config:load-config-from-string
            nerimux/config:load-config-from-stream
            nerimux/config:config-file-path
            nerimux/config:load-config-file)))

;;; NOTE: with-temp-config-file is defined in t/helpers-isolation.lisp so all
;;; test suites can reuse it.

(describe "config-directives-suite"

  ;;; set [-g|-a|...] name value  — flag handling (the canonical .tmux.conf form)

  ;; 'set-option -g status off' applies (3 tokens) — previously the fixed-arity table
  ;; silently dropped it.  Sets 'status', not an option named '-g'.
  (it "apply-set-directive-global-flag"
    (with-isolated-options ()
      (assert-set-directive-option-state '("set-option" "-g" "status" "off")
                                         "status" "off"
                                         :context "set-option -g status off")
      (expect (null (nerimux/options:get-option "-g")))))

  ;; 'set-option -ag <name> <value>' appends to the option's current value.
  (it "apply-set-directive-append-flag"
    (with-isolated-options ("status-left" "A")
      (assert-set-directive-option-state '("set-option" "-ag" "status-left" "B")
                                         "status-left" "AB"
                                         :context "set-option -ag")))

  ;; 'set-option -u <name>' removes the option from the current scope.
  (it "apply-set-directive-unset-flag"
    (with-isolated-options ("status-left" "keep-me")
      (assert-set-directive-option-state '("set-option" "-u" "status-left")
                                         "status-left" nil
                                         :context "set-option -u"
                                         :present-p nil)))

  ;; Plain 'set name value' (no flags) still flows through the normal directive
  ;; table and applies unchanged.
  (it "apply-set-directive-plain-unaffected"
    (with-isolated-options ()
      (assert-set-directive-option-state '("set-option" "status" "off")
                                         "status" "off"
                                         :context "plain set")))

  ;;; set mouse

  ;; 'set-option -g mouse on' still parses and applies without signalling a
  ;; condition, even though nothing consumes the value: the option's
  ;; side-effect handler, and the renderer callback it used to fire, were both
  ;; removed. It does now warn to *error-output* (see
  ;; inert-option-names-warn-but-still-apply below) -- "has no effect" still
  ;; holds, "no warning" no longer does. This pins the documented "parses, has
  ;; no effect" contract.
  (it "set-mouse-applies-without-signalling"
    (with-isolated-config
      (finishes
        (assert-config-directive-applied '("set-option" "-g" "mouse" "on")
                                         "set-option -g mouse on"))))

  ;;; set-shell / set-status-height directives

  ;; set-shell sets *default-shell*; set-status-height sets the `status' option,
  ;; the single source of truth nerimux/options:status-line-count reads.
  ;;
  ;; The status-line-count assertion below is a regression guard, not a
  ;; restatement.  set-status-height used to write a separate cached variable
  ;; (nerimux/config:*status-height*) and leave the `status' option alone, while
  ;; the renderer decided how many rows to PAINT from the option.  The pane
  ;; layout reserved the cached number.  So `set-status-height 2' reserved two
  ;; rows and painted one, leaving a blank reserved row that nothing drew into.
  ;; Asserting the count against the surviving source of truth is what would
  ;; have caught that.
  (it "set-shell-and-status-height-directives"
    (with-isolated-config
      (assert-config-directive-applied '("set-shell" "/usr/bin/zsh")
                                       "set-shell directive")
      ;; set-shell writes the `default-shell' option, which is what the PTY
      ;; layer and %shell-basename read.  It used to write a cached special that
      ;; left the option itself stale, so show-options could report one shell
      ;; while a different one was spawned.
      (expect (string= "/usr/bin/zsh"
                       (nerimux/options:get-option "default-shell")))
      (assert-config-directive-applied '("set-status-height" "2")
                                       "set-status-height directive")
      (expect (= 2 (nerimux/options:status-line-count)))))

  ;;; bind/unbind/set: arity and validity table

  ;; Every malformed or unknown directive returns NIL without mutating state.
  (it "invalid-directive-cases-return-nil"
    (with-isolated-config
      (dolist (tokens '(("bind")
                        ("bind" "z" "bogus-command")
                        ("unbind")
                        ("unbind" "z" "extra")
                        ("set-shell")
                        ("set-status-height")
                        ("totally-unknown" "arg")))
        (assert-config-directive-rejected tokens
                                          (format nil "~S" tokens)))))

  ;;; set-status-height: tolerant parsing

  ;; Non-integer or non-positive set-status-height values return NIL and do not signal.
  (it "set-status-height-noninteger-is-tolerated"
    (with-isolated-config
      (let ((before (nerimux/options:status-line-count)))
        (assert-config-directive-safe-nil '("set-status-height" "abc")
                                          "set-status-height with a non-integer value")
        (expect (eql before (nerimux/options:status-line-count)))
        (assert-config-directive-safe-nil '("set-status-height" "0")
                                          "set-status-height with a non-positive value (0)")
        (expect (eql before (nerimux/options:status-line-count))))))

  ;;; inert-but-recognized directives/options warn to *error-output*
  ;;
  ;; bind/unbind/unbind-all/set-hook still parse and return NIL exactly as
  ;; before (see invalid-directive-cases-return-nil above, which pins the
  ;; return value); this pins the additional *ERROR-OUTPUT* signal so a user
  ;; reusing an old config sees why the line did nothing, instead of silence.

  (it "inert-directive-verbs-warn-and-still-return-nil"
    (with-isolated-config
      (dolist (tokens '(("bind" "C-a" "split-window")
                        ("unbind" "C-a")
                        ("unbind-all")
                        ("set-hook" "after-new-session" "some-command")))
        (let (result errout)
          (setf errout
                (with-output-to-string (*error-output*)
                  (setf result (apply-config-directive tokens))))
          (expect (null result))
          (expect (search "directive" errout))
          (expect (search (first tokens) errout))))))

  ;; set-option -g prefix/prefix2/mouse still store (return T, same as before
  ;; the "set-mouse-applies-without-signalling" test above pins for mouse) but
  ;; now also warn, naming the option.
  (it "inert-option-names-warn-but-still-apply"
    (with-isolated-config
      (dolist (name+value '(("prefix" . "C-a") ("prefix2" . "C-b") ("mouse" . "on")))
        (let (result errout)
          (setf errout
                (with-output-to-string (*error-output*)
                  (setf result (apply-config-directive
                               (list "set-option" "-g" (car name+value) (cdr name+value))))))
          (expect (eq t result))
          (expect (search "option" errout))
          (expect (search (car name+value) errout))))))

  ;; A still-effective option (default-shell) must NOT trigger the inert-option
  ;; warning: the warning is scoped to prefix/prefix2/mouse only.
  (it "effective-option-does-not-warn"
    (with-isolated-config
      (let (result errout)
        (setf errout
              (with-output-to-string (*error-output*)
                (setf result (apply-config-directive
                             (list "set-option" "default-shell" "/bin/zsh")))))
        (expect (eq t result))
        (expect (zerop (length errout)))))))
