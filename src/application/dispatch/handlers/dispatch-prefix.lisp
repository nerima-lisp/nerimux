(in-package #:nerimux)

;;;; Prefix-key command dispatch.
;;;;
;;;; This lived in application/dispatch/control/dispatch-control.lisp alongside
;;;; the control-mode (-C) REPL until control mode was removed.  It is NOT
;;;; control-mode code and never was: it is the dispatcher every prefix-key
;;;; binding in an attached client goes through, reached from
;;;; presentation/events/events-keystroke-repeat-states.lisp.  Keeping it in a
;;;; file named for control mode is what made it look deletable.

(defun dispatch-prefix-command (session byte)
  "Handle one byte received after the prefix key.
   Copy mode intercepts [ ] q before the normal binding table.  A binding whose
   value is a token LIST (from `bind key command args...`) runs as a command
   line; a keyword value dispatches as a built-in command.
   Returns :REPEATABLE when the binding had the -r (repeatable) flag set, so
   the caller can stay in after-prefix state for the next key."
  (let* ((ch  (and byte (code-char byte)))
         ;; Probe the prefix table by candidate spellings (raw char, named keys
         ;; like Tab/Enter/BSpace, and C-<letter>) so `bind Tab ...` / `bind
         ;; Enter ...` work — not just single printable chars.  Resolve the entry
         ;; once and derive BOTH the command and the -r flag from it.
         (entry (if (%copy-mode-active-p session)
                    nil
                    (and byte
                         (%key-table-entry-by-candidates
                          +table-prefix+ (%single-byte-key-candidates byte)))))
         (repeatable-p (and entry (key-table-repeatable-p entry)))
         (cmd (if (%copy-mode-active-p session)
                  (%copy-mode-cmd ch)
                  (and entry (key-table-command entry))))
         (result (cond
                   ;; (:sequence cmd1 cmd2 ...) — run each sub-command in order.
                   ((and (consp cmd) (eq (car cmd) :sequence))
                    (let (last-result)
                      (dolist (subcmd (cdr cmd) last-result)
                        (setf last-result (%run-command-tokens session subcmd)))))
                   ;; Token list (arg-bearing command).
                   ((consp cmd)
                    (%run-command-tokens session cmd))
                   ;; Built-in command keyword.
                   (t
                    (dispatch-command session cmd byte)))))
    ;; Propagate :quit/:detach outcomes to the caller.  For other outcomes,
    ;; signal :repeatable when the binding had the -r flag so the caller can
    ;; stay in after-prefix state (resize without re-pressing the prefix key).
    (or (and (member result '(:quit :detach)) result)
        (and repeatable-p :repeatable))))
