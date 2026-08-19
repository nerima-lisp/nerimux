(in-package #:nerimux)

;;; -- Message log -------------------------------------------------------------

(defconstant +max-message-log-entries+ 100
  "Maximum number of entries retained in *message-log*.")

(defvar *message-log* nil
  "A list of (timestamp . text) cons pairs for :show-messages.")

(defvar *current-client-conn* nil
  "The client connection currently being served by the server-side command path,
   or NIL when running commands without a specific client context.")

(defun %option-or-default (option default)
  "Return OPTION when set, otherwise DEFAULT."
  (or option default))

(defun %message-log-limit ()
  "The effective message-log cap: the `message-limit` option (tmux default 1000),
   falling back to +max-message-log-entries+ when unset."
  (%option-or-default (nerimux/options:get-option "message-limit")
                      +max-message-log-entries+))

(defun %append-message-log-entry (log entry)
  "Prepend ENTRY to LOG and cap the result at the effective message-log limit."
  (%cap-list (cons entry log) (%message-log-limit)))

(defun add-message-log (msg)
  "Prepend MSG to *message-log*, capping the list at the `message-limit` option
   (tmux default 1000), falling back to +max-message-log-entries+ when unset."
  (let ((entry (cons (get-universal-time) msg)))
    (setf *message-log* (%append-message-log-entry *message-log* entry))
    (when *current-client-conn*
      (setf (client-conn-message-log *current-client-conn*)
            (%append-message-log-entry
             (client-conn-message-log *current-client-conn*)
             entry)))))

;;; -- Prompt history ----------------------------------------------------------
;;;
;;; Storage, capacity, and (prefix-filtered) recall navigation are delegated
;;; entirely to cl-history-kit; this file only adds tmux's `prompt-history-limit`
;;; option and `history-file` persistence on top of it.

(defconstant +max-prompt-history+ 100
  "Default command-prompt history capacity when the prompt-history-limit option
   is unset (tmux default 100).")

(defvar *prompt-history* (history-kit:make-history :capacity +max-prompt-history+)
  "A history-kit:history store of the most recent command-prompt inputs.
   Populated by the :command-prompt handler; shown by :show-prompt-history;
   navigated by prompt-history-prev / prompt-history-next.")

(defun %prompt-history-path ()
  "The configured history-file path (a non-empty string) or NIL when unset —
   NIL means command-prompt history is in-memory only (no persistence)."
  (let ((p (ignore-errors (nerimux/options:get-option "history-file"))))
    (and (stringp p) (plusp (length p)) p)))

(defmacro %with-prompt-history-path ((path) &body body)
  "Evaluate BODY with PATH bound to the configured history-file path when present."
  `(let ((,path (%prompt-history-path)))
     (when ,path
       ,@body)))

(defun save-prompt-history ()
  "Write *prompt-history* to the history-file, one entry per line, OLDEST first
   (so a later load preserves recency order).  No-op when history-file is unset;
   best-effort (I/O errors are ignored)."
  (%with-prompt-history-path (path)
    (ignore-errors
      (with-open-file (s path :direction :output :if-exists :supersede
                              :if-does-not-exist :create)
        (dolist (entry (reverse (history-kit:history-entries *prompt-history*)))
          (write-line (history-kit:history-entry-text entry) s))))))

(defun %effective-prompt-history-limit ()
  "The effective command-prompt history cap: the `prompt-history-limit` option
   (tmux default 100), falling back to +max-prompt-history+ when unset."
  (%option-or-default (nerimux/options:get-option "prompt-history-limit")
                      +max-prompt-history+))

(defun %ensure-prompt-history-capacity ()
  "Resize *prompt-history* to the effective prompt-history-limit, when that
   differs from its current capacity, by merging its entries into a
   freshly-capacitated store.  cl-history-kit fixes capacity at creation, so a
   capacity change (via `set-option prompt-history-limit`) has no direct setter
   — history-merge is the sanctioned way to carry entries across stores."
  (let ((limit (%effective-prompt-history-limit)))
    (unless (= limit (history-kit:history-capacity *prompt-history*))
      (setf *prompt-history*
            (history-kit:history-merge (history-kit:make-history :capacity limit)
                                        *prompt-history*)))))

(defun %read-history-lines (stream)
  "Read all non-empty lines from STREAM, oldest first (matching file order)."
  (loop for line = (read-line stream nil nil) while line
        when (plusp (length line)) collect line))

(defun load-prompt-history ()
  "Load *prompt-history* from the history-file (one entry per line, oldest
   first), capped at the effective prompt-history-limit.  No-op when the
   option is unset or the file is unreadable."
  (%with-prompt-history-path (path)
    (when (probe-file path)
      (ignore-errors
        (with-open-file (stream path :direction :input :if-does-not-exist nil)
          (when stream
            (%ensure-prompt-history-capacity)
            (dolist (line (%read-history-lines stream))
              (history-kit:history-add *prompt-history* line))))))))

(defun add-prompt-history (entry)
  "Record ENTRY as the newest *prompt-history* entry, honoring the effective
   prompt-history-limit, and persist to the history-file when that option is
   set."
  (when (and (stringp entry) (plusp (length entry)))
    (%ensure-prompt-history-capacity)
    (history-kit:history-add *prompt-history* entry)
    (save-prompt-history)))
