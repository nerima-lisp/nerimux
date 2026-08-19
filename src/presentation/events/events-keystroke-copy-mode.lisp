(in-package #:nerimux)

;;;; Copy-mode ground-state dispatch.

;;; Extracted from %ground-input-state so the top-level CPS state stays a flat
;;; ordered list of clauses.  %make-copy-mode-digit-k builds the small CPS
;;; continuation *copy-mode-prefix-k* threads across calls (mirroring
;;; events-core.lisp's MAKE-PROMPT-UTF8-K): a digit byte closes over the count
;;; accumulated so far and returns a further continuation to keep waiting, or
;;; the resolved repeat COUNT (>= 1) once a non-digit byte arrives — a
;;; FUNCTIONP/non-FUNCTIONP return distinguishes "still accumulating" from
;;; "done" at the call site, %dispatch-copy-mode-ground-byte.

(defun %make-copy-mode-digit-k (accumulator)
  "Return a continuation that folds the next digit BYTE into ACCUMULATOR when
   it continues a numeric copy-mode prefix.  The continuation returns a fresh
   continuation (via %MAKE-COPY-MODE-DIGIT-K) while BYTE extends the prefix, or
   the resolved repeat COUNT (>= 1, ACCUMULATOR clamped to a minimum of 1) once
   BYTE is not a prefix digit — i.e. once the accumulated count is ready to be
   applied to a navigation command.  '0' with ACCUMULATOR=0 is NOT accumulated
   (vi convention: bare 0 = beginning of line, only 1-9 or a non-zero prefix
   followed by 0 continue the prefix)."
  (lambda (byte)
    (if (and (>= byte +byte-digit-0+) (<= byte +byte-digit-9+)
             (or (> byte +byte-digit-0+) (plusp accumulator)))
        (%make-copy-mode-digit-k (+ (* accumulator 10) (- byte +byte-digit-0+)))
        (max 1 accumulator))))

(defparameter +copy-mode-char-argument-handlers+
  '((:copy-mode-jump-forward . copy-mode-jump-forward)
    (:copy-mode-jump-backward . copy-mode-jump-backward)
    (:copy-mode-jump-to . copy-mode-jump-to)
    (:copy-mode-jump-to-backward . copy-mode-jump-to-backward))
  "Copy-mode key-table commands that consume the next byte as a character argument.")

(defun %copy-mode-char-argument-handler (entry)
  "Return the character-argument handler function for ENTRY, or NIL."
  (let ((handler (cdr (assoc (key-table-command entry)
                             +copy-mode-char-argument-handlers+))))
    (and handler (symbol-function handler))))

(defun %copy-mode-char-argument-continuation (screen handler count)
  "Return a CPS continuation that applies HANDLER to the next input byte."
  (lambda (_ignored-session byte2)
    (declare (ignore _ignored-session))
    (loop repeat count
          do (funcall handler screen (code-char byte2)))
    (setf *dirty* t)
    (%ground-values)))

(defun %run-copy-mode-key-table-entry (session byte count)
  "Resolve BYTE against the active copy-mode key table and run the binding.
   Control bytes and single-byte special keys are probed by their canonical
   tmux name (\"C-b\", \"Enter\", \"BSpace\", ...), matching keys stored by
   the key-binding table.  Character-argument commands return a continuation
   that consumes the next byte; otherwise COUNT repeats count-consuming
   commands (COPY-MODE-COUNT-COMMAND-P) and entries the user bound with -r,
   while other entries run once."
  (let ((entry (%key-table-entry-by-candidates
                (%active-copy-mode-table)
                (%single-byte-key-candidates byte))))
    (when entry
      (let ((char-handler (%copy-mode-char-argument-handler entry)))
        (if char-handler
            (return-from %run-copy-mode-key-table-entry
              (%copy-mode-char-argument-continuation (%active-screen session)
                                                     char-handler
                                                     count))
            (loop repeat (if (or (key-table-repeatable-p entry)
                                 (copy-mode-count-command-p
                                  (key-table-command entry)))
                             count
                             1)
                  do (%run-key-table-binding session entry byte))))))
  nil)

(defun %dispatch-copy-mode-ground-byte (session byte)
  "Handle one BYTE of unprefixed copy-mode navigation from ground state.
   Copy mode has its own active table, so ordinary bytes are resolved there.
   Numeric prefix digits accumulate via *copy-mode-prefix-k*
   (%make-copy-mode-digit-k); once a non-digit byte resolves the count, the
   byte is resolved via %run-copy-mode-key-table-entry.  Returns
   (%GROUND-VALUES) when no new state is entered."
  (let ((screen (%active-screen session)))
    (when screen
      (let ((result (funcall (or *copy-mode-prefix-k* (%make-copy-mode-digit-k 0))
                             byte)))
        (if (functionp result)
            (setf *copy-mode-prefix-k* result)
            (progn
              (setf *copy-mode-prefix-k* nil)
              (let ((new-state (%run-copy-mode-key-table-entry session byte result)))
                (when new-state
                  (setf *dirty* t)
                  (return-from %dispatch-copy-mode-ground-byte
                    (values nil new-state)))))))))
  (setf *dirty* t)
  (%ground-values))
