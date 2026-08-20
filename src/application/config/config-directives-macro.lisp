(in-package #:nerimux/config)

;;; ── Runtime sb-posix helpers ─────────────────────────────────────────────────
;;; ── Environment-variable helper ─────────────────────────────────────────────
;;;
;;; set-environment directives need to mutate the process environment.
;;; SB-POSIX is looked up lazily at call time — it is not an ASDF dependency of
;;; nerimux so it may not be loaded when this file first loads, but it IS loaded
;;; before any runtime or test caller reaches these functions.

(defun %config-setenv (name value)
  "Set environment variable NAME to VALUE for child processes.
   Looks up SB-POSIX:SETENV lazily.  A no-op when sb-posix is absent."
  (let ((fn (nerimux/ports:find-posix-function "SETENV")))
    (when fn (ignore-errors (funcall fn name value 1)))))

;;; ── run-shell tilde expansion helper ─────────────────────────────────────────

(defun %expand-leading-tilde (cmd)
  "Expand a leading \"~/\" in CMD to \"$HOME/\" using the HOME environment
   variable, so `run '~/.tmux/plugins/tpm/tpm'` resolves to the user's home.
   Leaves absolute (\"/abs\") and relative (\"rel\") strings unchanged.  Pure
   string transformation: returns CMD unchanged when it does not begin with ~/."
  (if (and (> (length cmd) 2)
           (char= (char cmd 0) #\~)
           (char= (char cmd 1) #\/))
      (concatenate 'string
                   (or (ignore-errors (sb-ext:posix-getenv "HOME")) "~")
                   (subseq cmd 1))
      cmd))

(defun %flag-token-contains-any-p (tok flags)
  "Return T when TOK contains any character from FLAGS."
  (and (stringp tok)
       (some (lambda (flag) (find flag tok :test #'char=)) flags)))

(defun %join-config-tokens (tokens)
  "Join TOKENS into a single space-separated string.
   Returns NIL for an empty token list."
  (when tokens
    (format nil "~{~A~^ ~}" tokens)))

(defun %leading-flag-token-p (tok &key (allow-single-dash nil))
  "Return T when TOK looks like a leading directive flag token."
  (and (stringp tok)
       (if allow-single-dash
           (and (> (length tok) 0) (char= (char tok 0) #\-))
           (and (> (length tok) 1) (char= (char tok 0) #\-)))))

(defun %consume-leading-flag-tokens (tokens consumer
                                     &key (allow-single-dash nil))
  "Consume leading flag TOKENS using CONSUMER.
   CONSUMER is called as (funcall CONSUMER FLAG-TOKEN REST) and must return two
   values: the updated REST token list and a generalized boolean that says
   whether scanning should continue."
  (loop while (and tokens
                   (%leading-flag-token-p (first tokens)
                                          :allow-single-dash allow-single-dash))
        do (multiple-value-bind (next-tokens continue-p)
               (funcall consumer (pop tokens) tokens)
             (setf tokens next-tokens)
             (unless continue-p (return))))
  tokens)

(defmacro %consuming-flags ((tokens tok rest) &body cond-clauses)
  `(%consume-leading-flag-tokens
    ,tokens
    (lambda (,tok ,rest)
      (cond ,@cond-clauses)
      (values ,rest t))))

(defun %expand-config-directive-rule (rule)
  "Expand one canonical directive RULE into a COND clause."
  (destructuring-bind (name arity arglist &body body) rule
    (list `((and (string= cmd ,name) (= (length args) ,arity))
            (destructuring-bind ,arglist args
              (declare (ignorable ,@arglist))
              ,@body)))))

;;; ── Declarative directive dispatch macro ──────────────────────────────────

(defmacro define-config-directives (&rest rules)
  "Build %APPLY-CONFIG-DIRECTIVE-INNER from canonical directive RULES.

   Each RULE has the form:
     (NAME ARITY (ARG...) &body BODY)
       NAME   - the canonical directive keyword as a string (e.g. \"set-shell\")
       ARITY  - the exact number of arguments the directive takes
       (ARG...) - symbols bound to those arguments inside BODY
       BODY   - forms run when NAME matches with the right ARITY; their value is
                returned (non-NIL means the directive was applied).

   The macro intentionally accepts one name per rule. Config parsing is
   canonical-only; shorthand aliases must be rejected at the parser boundary.
   The outer APPLY-CONFIG-DIRECTIVE function wraps this inner dispatcher with
   the variable-arity handlers (set-option, if-shell, run-shell, source-file)."
  `(defun %apply-config-directive-inner (tokens)
     "Apply one fixed-arity config directive (list of string TOKENS) to live state.
      Returns T when applied, NIL for an unknown/invalid directive."
     (when tokens
       (let ((cmd (first tokens)) (args (rest tokens)))
         (declare (ignorable args))
         (cond
           ,@(mapcan #'%expand-config-directive-rule rules)
           (t nil))))))
