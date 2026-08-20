(in-package #:nerimux/options)

;;;; Option accessor API: type coercions, get/set functions, scoped overrides.
;;;;
;;;; Scope-resolution helpers (%scope-*, %array-*, %option-spec-for-name, and
;;;; the option-present-for-* predicates) live in options-scope.lisp which is
;;;; loaded before this file.
;;;;
;;;; Display helpers (show-options, show-option, show-window-options, etc.)
;;;; live in options-display.lisp which is loaded after this file.

;;; ── Type coercions ────────────────────────────────────────────────────────
;;;
;;; define-type-coercions generates %coerce-value from a declarative table of
;;; (TYPE-KEYWORD &rest BODY) facts, consistent with define-csi-rules and
;;; define-config-directives in style.

(defmacro define-type-coercions (&rest specs)
  "Generate a %COERCE-VALUE (type value) function from a declarative fact table.
   Each SPEC has the form (TYPE-KEYWORD &rest BODY) where BODY is evaluated with
   VALUE bound to the argument.  The generated function dispatches via ECASE."
  `(defun %coerce-value (type value)
     "Coerce VALUE to the Lisp type indicated by the TYPE keyword."
     (ecase type
       ,@(mapcar (lambda (spec)
                   (destructuring-bind (type-keyword &rest body) spec
                     `(,type-keyword (progn ,@body))))
                 specs))))

(define-type-coercions
  (:boolean
   (cond
     ((stringp value)
      (and (member value '("on" "true" "1") :test #'equal) t))
     (t (and value t))))
  (:integer
   ;; Non-numeric and non-number inputs (including nil) fall back to 0.
   ;; Callers that need to distinguish "unset" from "zero" should check
   ;; option presence via get-option before calling set-option.
   (cond
     ((stringp value)
      (or (nerimux/text:parse-integer-or-nil value :junk-allowed t) 0))
     ((numberp value)
      (truncate value))
     (t 0)))
  (:string
   (format nil "~A" value)))

;;; ── define-option-accessor ────────────────────────────────────────────────
;;;
;;; Generates a matched get/set pair for one option storage hash-table plus
;;; registry hash-table, eliminating the structural duplication between the
;;; global and server option APIs.

(defmacro define-option-accessor (get-name set-name storage-var registry-var
                                  &key get-docstring set-docstring)
  "Generate GET-NAME (name &optional default) and SET-NAME (name value) functions
   operating on STORAGE-VAR (runtime values) and REGISTRY-VAR (type specs).
   GET-DOCSTRING and SET-DOCSTRING are optional docstring overrides."
  (let ((known-registry-var (if (eq registry-var '*server-option-registry*)
                                '*known-server-option-registry*
                                '*known-option-registry*)))
    `(progn
       (defun ,get-name (name &optional (default nil default-suppliedp))
         ,(or get-docstring
              (format nil "Return the current value of option NAME from ~A.~%~
                           When NAME is absent: returns the explicitly supplied DEFAULT~%~
                           if one was given; otherwise falls back to the registered~%~
                           spec default in ~A (mirroring tmux options_remove_or_default,~%~
                           so a `set -u` of a registered option reads as its table default)."
                      storage-var registry-var))
         (multiple-value-bind (value presentp)
             (gethash name ,storage-var)
           (cond
             (presentp value)
             ;; An explicit caller DEFAULT (even NIL) is always honored.
             (default-suppliedp default)
             ;; No caller default: fall back to the tmux spec default, so an unset
             ;; registered option reverts to its table default value.
             (t (let ((spec (or (gethash name ,registry-var)
                                (gethash name ,known-registry-var))))
                  (if spec
                      (option-spec-default spec)
                      nil))))))
       (defun ,set-name (name value)
         ,(or set-docstring
              (format nil "Coerce VALUE to the registered type for NAME and store it in ~A.~%~
                           Returns the coerced value.  Unregistered options are stored~%~
                           as-is (no coercion) for special-option side-effect handlers~%~
                           (prefix, default-shell) and user options (@ prefix)."
                      storage-var))
         (let* ((spec (%option-spec-for-name name
                                             ,registry-var
                                             ,known-registry-var))
                (coerced (if spec
                             (%coerce-value (option-spec-type spec) value)
                             value)))
           (setf (gethash name ,storage-var) coerced)
           coerced)))))

;;; ── Public session-option API ─────────────────────────────────────────────

(define-option-accessor get-option set-option
  *global-options* *option-registry*
  :get-docstring
  "Return the current value of option NAME from *GLOBAL-OPTIONS*.
   Returns DEFAULT (nil if not supplied) when NAME is not present."
  :set-docstring
  "Coerce VALUE to the registered type for NAME and store it in *GLOBAL-OPTIONS*.
   Returns the coerced value.  Unregistered options are stored as-is (no coercion).")

(defun option-defined-p (name)
  "Return T if NAME is a registered option in *OPTION-REGISTRY*."
  (not (null (gethash name *option-registry*))))

;;; ── Option scope classification (mirrors tmux options_scope_from_name) ─────
;;;
;;; tmux tags each option with a scope; without an explicit -g/-s/-w/-p flag,
;;; set-option infers the target store from that scope.  nerimux models SESSION
;;; and SERVER options via the global / server stores, so the only inference
;;; that changes routing is WINDOW scope.

(defparameter +window-scoped-option-name-list+
  '("aggressive-resize"
    "automatic-rename" "automatic-rename-format"
    "main-pane-height" "main-pane-width"
    "mode-keys"
    "mode-style"
    "monitor-activity" "monitor-bell"
    "other-pane-height" "other-pane-width"
    "pane-active-border-style" "pane-base-index"
    "pane-border-format" "pane-border-indicators"
    "pane-border-lines" "pane-border-status" "pane-border-style"
    "remain-on-exit" "remain-on-exit-format"
    "synchronize-panes" "window-active-style" "window-size"
    "window-status-activity-style" "window-status-bell-style"
    "window-status-current-format" "window-status-current-style"
    "window-status-format" "window-status-last-style"
    "window-status-separator" "window-status-style"
    "window-style" "wrap-search")
  "Names of tmux options whose scope is WINDOW (or window|pane) per tmux's
   options_scope_from_name.  Used to build *window-scoped-option-names*, which
   routes a flagless set-option call to the active window's local store
   rather than the global session store.")

(defun %string-list->presence-table (names)
  "Return a hash-table mapping each string in NAMES to T, :test #'equal.
   Generic converter for name-set membership tables in this file."
  (let ((ht (make-hash-table :test #'equal)))
    (dolist (name names ht)
      (setf (gethash name ht) t))))

(defparameter *window-scoped-option-names*
  (%string-list->presence-table +window-scoped-option-name-list+)
  "Names of WINDOW-scoped (and window|pane) tmux options, used by
   option-scope-from-name to route a flagless set-option to the active window.")

(defun option-scope-from-name (name)
  "Return the inferred scope keyword for option NAME when set-option is given no
   explicit scope flag: :window for a window-scoped option, else :session
   (which nerimux stores in the global table).  Mirrors tmux
   options_scope_from_name (server/pane scopes are flag-driven here)."
  (if (gethash name *window-scoped-option-names*) :window :session))

(defun style-option-p (name)
  "True when NAME is a tmux STYLE option (value is a comma-separated style
   string such as \"fg=red,bg=black,bold\").  tmux marks these OPTIONS_TABLE_IS_STYLE
   and `set -a` appends to them with a ',' separator, unlike plain string options
   which concatenate directly.  Every style option's name ends in \"-style\"."
  (and (stringp name)
       (let* ((suffix "-style") (suffix-len (length suffix)) (name-len (length name)))
         ;; name-len > suffix-len (strict): a style option must have a non-empty
         ;; prefix before the \"-style\" suffix.
         (and (> name-len suffix-len)
              (string= name suffix :start1 (- name-len suffix-len))))))

(defun append-option-value (name old value)
  "Compute the new value for `set -a NAME` given the option's current OLD value and
   the appended VALUE.  For STYLE options with a non-empty current value, tmux
   inserts a ',' separator (so `status-style bg=red` then `set -ag status-style
   fg=blue` yields `bg=red,fg=blue`); plain string options concatenate with no
   separator.  An empty OLD or empty VALUE never introduces a stray comma."
  (let ((old-str (princ-to-string (or old "")))
        (val-str (princ-to-string (or value ""))))
    (if (and (style-option-p name) (plusp (length old-str)) (plusp (length val-str)))
        (concatenate 'string old-str "," val-str)
        (concatenate 'string old-str val-str))))

(defun all-options ()
  "Return an alist of (name . value) for every entry in *GLOBAL-OPTIONS*.
   Note: iteration order over the hash-table is arbitrary and may differ
   between runs.  Do not rely on ordering of the returned alist."
  (let (result)
    (maphash (lambda (k v) (push (cons k v) result))
             *global-options*)
    result))

;;; ── Server option API ─────────────────────────────────────────────────────

(define-option-accessor get-server-option set-server-option
  *server-options* *server-option-registry*
  :get-docstring
  "Return the current value of server option NAME from *SERVER-OPTIONS*.
   Returns DEFAULT (nil if not supplied) when NAME is not present."
  :set-docstring
  "Coerce VALUE to the registered type for NAME and store in *SERVER-OPTIONS*.
   Returns the coerced value.  Unregistered options are stored as-is (no coercion).")

;;; ── Scoped option accessors (per-window / per-pane) ──────────────────────
;;;
;;; These functions implement the tmux fallback chain:
;;;   pane-local  → window-local → global → registered default
;;;
;;; The nerimux/model package is referenced by qualified name to avoid a
;;; circular dependency (model depends on config which depends on options).

(defun %resolve-option-in-scope-chain (name pane-options window-options)
  "Walk PANE-OPTIONS → WINDOW-OPTIONS → *global-options* → spec default.
   Each level is a hash-table or NIL (to skip that level).  Returns the first
   present value, honoring present-but-falsey overrides via gethash present-p.
   Pure logic: no side-effects beyond hash lookups."
  (dolist (table (list pane-options window-options *global-options*))
    (when table
      (multiple-value-bind (value present-p) (gethash name table)
        (when present-p (return-from %resolve-option-in-scope-chain value)))))
  (let ((spec (gethash name *option-registry*)))
    (when spec (option-spec-default spec))))

(defun get-option-for-context (name &key pane window)
  "Resolve option NAME with full tmux scope precedence: pane-local -> window-local
   -> global -> registered default.  PANE and/or WINDOW may be NIL (skip that
   level).  Uses gethash present-p so a present-but-falsey override is honored.
   When both PANE and WINDOW are NIL this is equivalent to get-option.

   This is the single source of truth for scoped option resolution;
   get-option-for-window and get-option-for-pane delegate here."
  (%resolve-option-in-scope-chain
   name
   (when pane   (nerimux/model:pane-local-options   pane))
   (when window (nerimux/model:window-local-options window))))

(defun get-option-for-window (name window)
  "Look up NAME in WINDOW's local options, falling back to *global-options*,
   then to the registered spec default.  Returns NIL when not found anywhere.

   Delegates to get-option-for-context with only :window supplied; the
   present-p resolution ladder lives in one place.  A window-local value
   explicitly set to a falsey value is honored and does NOT fall through."
  (get-option-for-context name :window window))

(defun %set-local-option (name value hash)
  "Coerce VALUE for NAME (via *OPTION-REGISTRY*) and store it in HASH.
   Returns the coerced value.  Shared by set-option-for-window and set-option-for-pane.
   Unregistered options are stored as-is (no coercion, no error)."
  (let* ((spec    (%option-spec-for-name name
                                         *option-registry*
                                         *known-option-registry*))
         (coerced (if spec
                      (%coerce-value (option-spec-type spec) value)
                      value)))
    (setf (gethash name hash) coerced)
    coerced))

(defun set-option-for-window (name value window)
  "Coerce VALUE and store under NAME in WINDOW's local-options hash.
   Returns the coerced value."
  (%set-local-option name value (nerimux/model:window-local-options window)))

(defun get-option-for-pane (name pane)
  "Look up NAME in PANE's local options, falling back to *global-options*,
   then to the registered spec default.  Returns NIL when not found anywhere.

   Delegates to get-option-for-context with only :pane supplied; the
   present-p resolution ladder lives in one place.  A pane-local value
   explicitly set to a falsey value is honored and does NOT fall through."
  (get-option-for-context name :pane pane))

(defun set-option-for-pane (name value pane)
  "Coerce VALUE and store under NAME in PANE's local-options hash.
   Returns the coerced value."
  (%set-local-option name value (nerimux/model:pane-local-options pane)))

;;; ── Status-bar row count ──────────────────────────────────────────────────
;;;
;;; How many rows the status bar occupies is derived from the `status' option,
;;; here, once.  It used to be computed in two places that could disagree:
;;; renderer-statusbar.lisp parsed the option live to decide how many rows to
;;; PAINT, while nerimux/config:*status-height* held a cached copy that the pane
;;; layout used to decide how many rows to RESERVE.
;;;
;;; They did disagree.  `set-status-height N' wrote the cache without touching
;;; the option, so after it the layout reserved N rows and the renderer painted
;;; one -- N-1 reserved rows that nothing ever drew into.  Deriving both from the
;;; option removes the second source of truth rather than trying to keep two in
;;; step.
;;;
;;; This lives in the domain, next to the option registry that owns "status",
;;; because the pane layout (domain) needs it as much as the renderer does --
;;; and a domain reaching up into application for it was the layering violation
;;; that made the split look acceptable in the first place.

(defconstant +max-status-lines+ 5
  "tmux caps the status bar at five rows; a larger `status' value clamps here.")

(defparameter +status-off-values+ '("off" "false" "0")
  "String `status' values that hide the bar entirely.")

(defun %clamp-status-lines (n)
  "Clamp a status row count into tmux's 0..5 range."
  (max 0 (min n +max-status-lines+)))

(defun %status-lines-from-string (value)
  "Row count for a string `status' value."
  (if (member value +status-off-values+ :test #'equal)
      0
      (let ((n (and (stringp value)
                    (ignore-errors (parse-integer value :junk-allowed t)))))
        (cond ((null n)  1)
              ((plusp n) (%clamp-status-lines n))
              (t         0)))))

(defun status-line-count ()
  "Rows the status bar occupies, 0..5, derived from the `status' option.

   off/false/0/NIL -> 0; a positive integer N -> min(N, 5); any other truthy
   value (on/t) -> 1.  This is the single source of truth: the renderer paints
   this many rows and the pane layout reserves this many."
  (let ((value (get-option "status" t)))
    (cond ((null value)      0)
          ((integerp value)  (%clamp-status-lines value))
          ((stringp value)   (%status-lines-from-string value))
          (t                 1))))
