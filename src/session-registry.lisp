(in-package #:nerimux)

;;;; Session registry.
;;;;
;;;; *server-sessions* is the authoritative registry of all live sessions
;;;; (defvar lives in runtime.lisp so dispatch.lisp can reference it before
;;;; server loads).  run-server initialises it with the single initial session.
;;; ── Session registry ──────────────────────────────────────────────────────────
(defun server-add-session (session)
  "Register SESSION in *server-sessions* keyed by (session-name session).
   If a session with the same name already exists it is replaced."
  (setf *server-sessions* (cons (cons (session-name session) session)
                                (remove (session-name session)
                                        *server-sessions*
                                        :key
                                        #'car
                                        :test
                                        #'string=))))

(defun %find-session-by-exact-name (name)
  "Return the session whose registry key exactly matches NAME, or NIL."
  (cdr (assoc name *server-sessions* :test #'string=)))

(defun %find-session-by-id-notation (name)
  "Return the session referenced by $N notation in NAME, or NIL."
  (when (char= (char name 0) #\$)
    (let ((id (nerimux/text:parse-integer-or-nil (subseq name 1))))
      (when id
        (find id (mapcar #'cdr *server-sessions*) :key #'session-id)))))

(defun %find-session-by-prefix (name)
  "Return the first session whose registry key has NAME as a prefix, or NIL."
  (loop for (key . sess) in *server-sessions*
        when (and (stringp key)
                  (>= (length key) (length name))
                  (string= name key :end2 (length name)))
          return sess))

(defun server-find-session (name)
  "Find a session by NAME in *server-sessions*.
   Match order:
     1. Exact name match
     2. $N notation (session id)
     3. Name prefix match (first matching session wins)
   Returns the session or NIL."
  (when (and name (plusp (length name)))
    (or (%find-session-by-exact-name name)
        (%find-session-by-id-notation name)
        (%find-session-by-prefix name))))
