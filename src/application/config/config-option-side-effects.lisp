(in-package #:nerimux/config)

;;; -- Option runtime side effects -----------------------------------------------
;;;
;;; %apply-set-directive (in config-directives-set.lisp) writes option values
;;; into the options tables, then calls apply-option-side-effects so that
;;; options which touch non-option runtime state (the default shell, the
;;; status-bar height, escape-time, update-environment) take effect immediately.
;;; The prefix-key and mouse-reporting arms went with the key-table store, and
;;; the set-hook directive handler that used to live here went with the
;;; command-hooks registry (nerimux/hooks:*command-hooks*, unwireable — no
;;; command dispatcher has existed since the tmux command table was deleted):
;;; both drove machinery that no longer exists, so those options now store and
;;; stop.

(declaim (special nerimux/model:*update-environment*
                  nerimux/model:+default-update-environment+))

;;; ── Option side-effect helpers ───────────────────────────────────────────────

(defun %nonempty-string-p (x)
  "T when X is a non-empty string."
  (and (stringp x) (plusp (length x))))

;;; ── Declarative option-side-effect dispatch ──────────────────────────────────
;;;
;;; define-option-side-effect-handlers builds apply-option-side-effects from a
;;; Prolog-style fact table: one (NAME-STRING &body BODY) arm per option.  Each arm
;;; is guarded by (string= name NAME-STRING); VALUE is bound in BODY.  This matches
;;; define-csi-rules / define-config-directives in style.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun %expand-option-side-effect-rule (rule)
    "Expand one option side-effect RULE into a list of COND clauses."
    (if (eq (first rule) :any-of)
        (destructuring-bind (names &body body) (rest rule)
          `((member name ',names :test #'string=) ,@body))
        (destructuring-bind (name-string &body body) rule
          `((string= name ,name-string) ,@body)))))

(defmacro define-option-side-effect-handlers (&rest rules)
  "Build APPLY-OPTION-SIDE-EFFECTS from a declarative table of RULES.
   Each RULE has the form:
     (NAME-STRING &body BODY)   — NAME-STRING matched via STRING=; VALUE bound in BODY.
     (:any-of (NAME...) &body BODY) — VALUE bound in BODY when NAME is one of the list.
   Generates a COND dispatch over NAME."
  `(defun apply-option-side-effects (name value unset-p)
     "Apply runtime side-effects for options that touch non-option state.
      Dispatches on NAME; VALUE holds the new option value string."
     (declare (ignorable value unset-p))
     (cond
       ,@(mapcar #'%expand-option-side-effect-rule rules))))

(define-option-side-effect-handlers
  ;; default-shell: update the shell used for new panes immediately.
  ("default-shell"
   (if unset-p
       (setf *default-shell* "/bin/sh")
       (when (%nonempty-string-p value)
         (setf *default-shell* value))))
  ;; escape-time: sync into server-options so every set form takes effect.
  ("escape-time"
   (if unset-p
       (nerimux/options:set-server-option "escape-time" 10)
       (when (%nonempty-string-p value)
         (nerimux/options:set-server-option "escape-time" value))))
  ;; update-environment: propagate the space-separated variable list into the model.
  ("update-environment"
   (if unset-p
       (setf nerimux/model:*update-environment*
             (copy-list nerimux/model:+default-update-environment+))
       (when (%nonempty-string-p value)
         (setf nerimux/model:*update-environment*
               (remove-if (lambda (s) (zerop (length s)))
                          (host-kit:split-string value :separator '(#\Space))))))))
