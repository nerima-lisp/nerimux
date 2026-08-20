(in-package #:nerimux/config)

;;; ── Config file parsing + directive processing ───────────────────────────
;;;
;;; This file depends on the mutable specials defined in config.lisp
;;; (*default-shell*, *status-height*).  It used to depend on the key-table
;;; mutators there too; those went with the key-table store.

;;; ── Tokenizer phase helpers ──────────────────────────────────────────────

(defun %whitespace-p (ch)
  "True when CH is a configuration whitespace character (space or tab)."
  (or (char= ch #\Space) (char= ch #\Tab)))

;;; ── Tokenizer phase helpers ──────────────────────────────────────────────
;;;
;;; Each helper handles one tokenizer state and returns the updated character
;;; index.

(defun %tokenize-backslash-escape (line i len push-char)
  "Consume a backslash-escaped character starting at I.  Calls PUSH-CHAR on
   the escaped character.  Returns the new index past both characters."
  (let ((next (1+ i)))
    (if (< next len)
        (progn (funcall push-char (char line next))
               (+ next 1))
        (+ i 1))))

(defun %tokenize-double-quoted (line i len push-char)
  "Consume a double-quoted region beginning at I (the opening-quote position).
   Handles backslash escapes inside.  If no closing quote exists, treats the
   opening quote as a literal character.  Returns the new index."
  (let ((close-pos (position #\" line :start (1+ i))))
    (if (not close-pos)
        ;; No closing quote — treat the opening \" as a literal.
        (progn (funcall push-char (char line i))
               (1+ i))
        ;; Found a closing quote — process quoted content.
        (let ((j (1+ i)))            ; skip opening \"
          (loop while (and (< j len) (char/= (char line j) #\"))
                do (let ((quoted-char (char line j)))
                     (cond
                       ((and (char= quoted-char #\\) (< (1+ j) len))
                        (incf j)
                        (funcall push-char (char line j)))
                       (t
                        (funcall push-char quoted-char))))
                   (incf j))
          (when (< j len) (incf j))  ; skip closing \"
          j))))

(defun %tokenize-single-quoted (line i len push-char)
  "Consume a single-quoted region beginning at I.  No escapes inside.
   Returns the new index past the closing quote (or EOL if unmatched)."
  (let ((j (1+ i)))                  ; skip opening '
    (loop while (and (< j len) (char/= (char line j) #\'))
          do (funcall push-char (char line j))
             (incf j))
    (when (< j len) (incf j))        ; skip closing '
    j))

(defun %config-tokens (line)
  "Tokenize LINE into a list of strings, handling:
   - unquoted whitespace as delimiter
   - \"double quoted\" strings (spaces preserved, \\x escapes processed)
   - 'single quoted' strings (literal content, no escapes)
   - \\ (backslash) escaping of the next character outside quotes
   Returns a list of token strings."
  (let ((tokens   '())
        (current  (make-array 0 :element-type 'character :adjustable t :fill-pointer 0))
        (in-token nil)
        (len      (length line)))
    (flet ((push-char (ch)
             "Append CH to the in-progress token and mark it active.
              Shared by every character-class callback below so the
              append-and-flag dance is written once."
             (vector-push-extend ch current)
             (setf in-token t))
           (finish-token ()
             "Flush the in-progress token into TOKENS, when any is open."
             (when in-token
               (push (copy-seq current) tokens)
               (setf (fill-pointer current) 0
                     in-token nil))))
      (let ((i 0))
        (loop while (< i len) do
          (let ((ch (char line i)))
            (cond
              ((char= ch #\\)
               (setf i (%tokenize-backslash-escape line i len #'push-char)))
              ((char= ch #\")
               (setf i (%tokenize-double-quoted line i len #'push-char)
                     in-token t))
              ((char= ch #\')
               (setf i (%tokenize-single-quoted line i len #'push-char)
                     in-token t))
              ((char= ch #\;)
               ;; tmux cmd-parse: an unquoted, unescaped `;` is a command
               ;; separator even with no surrounding whitespace
               ;; (`set-option -g @a 1; set-option -g @b 2`), so it always lexes as its own
               ;; ";" token.  A literal `;` must be escaped (\;) or quoted —
               ;; both of those take the branches above and stay in-token.
               (finish-token)
               (push-char #\;)
               (finish-token)
               (incf i))
              ((%whitespace-p ch)
               (finish-token)
               (incf i))
              (t
               (push-char ch)
               (incf i))))))
      (finish-token))
    (nreverse tokens)))
