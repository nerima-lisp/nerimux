(in-package #:nerimux/hooks)

;;; A hooks system that allows user-defined Lisp functions to run on events.
;;;
;;; Hook event names follow the tmux convention:
;;;   "after-new-window"    — after a new window is created
;;;   "after-new-pane"      — after a pane is split
;;;   "pane-exited"         — when a pane's process exits
;;;   "session-created"     — when the session starts
;;;   "client-attached"     — when a client attaches to the server
;;;   "client-detached"     — when a client detaches from the server
;;;   "alert-bell"          — when a BEL character is received in a pane

;;; ── Hook event constant table ────────────────────────────────────────────

(defmacro define-hook-events (&rest specs)
  "Declare known hook events as a fact table.
Each SPEC is (constant-name event-string description-string).
Generates a DEFCONSTANT for each event-string constant.
Uses the safe SBCL idiom to avoid string-constant redefinition errors."
  `(progn
     ,@(mapcar (lambda (spec)
                 (destructuring-bind (constant-name event-string description-string) spec
                   (declare (ignore description-string))
                   `(defconstant ,constant-name
                      (if (boundp ',constant-name)
                          (symbol-value ',constant-name)
                          ,event-string))))
               specs)))

(define-hook-events
  (+hook-after-new-window+       "after-new-window"       "Fired after a new window is created")
  (+hook-after-new-pane+         "after-new-pane"         "Fired after a pane is split")
  (+hook-pane-exited+            "pane-exited"            "Fired when a pane's process exits")
  (+hook-session-created+        "session-created"        "Fired when a session is first created")
  (+hook-after-split-window+     "after-split-window"     "Fired after a window is split")
  (+hook-client-attached+        "client-attached"
   "Fired when a client attaches to the server")
  (+hook-client-detached+        "client-detached"
   "Fired when a client detaches from the server")
  (+hook-alert-bell+             "alert-bell"
   "Fired when a BEL character is received in a pane")
  (+hook-alert-activity+         "alert-activity"
   "Fired when monitor-activity detects activity in a window")
  (+hook-alert-silence+          "alert-silence"
   "Fired when monitor-silence detects silence in a window")
  (+hook-pane-focus-in+          "pane-focus-in"          "Fired when a pane gains focus")
  (+hook-pane-focus-out+         "pane-focus-out"         "Fired when a pane loses focus")
  (+hook-after-select-pane+      "after-select-pane"      "Fired after the select-pane command")
  (+hook-after-select-window+    "after-select-window"    "Fired after the select-window command")
  (+hook-session-window-changed+ "session-window-changed"
   "Fired when a session's active window changes")
  (+hook-window-pane-changed+    "window-pane-changed"
   "Fired when the active pane in a window changes")
  (+hook-window-renamed+         "window-renamed"         "Fired when a window is renamed")
  (+hook-session-renamed+        "session-renamed"        "Fired when a session is renamed")
  (+hook-after-resize-pane+      "after-resize-pane"      "Fired after a pane is resized")
  (+hook-client-resized+         "client-resized"
   "Fired when the client terminal is resized")
  (+hook-window-linked+          "window-linked"
   "Fired when a window is linked into a session")
  (+hook-window-unlinked+        "window-unlinked"
   "Fired when a window is unlinked from a session")
  (+hook-session-closed+         "session-closed"
   "Fired when a session is destroyed (kill-session)")
  (+hook-pane-output+            "pane-output"
   "Fired when a pane receives PTY output (args: pane bytes)")
  (+hook-pane-died+              "pane-died"
   "Fired when a pane's program exits and remain-on-exit keeps the pane visible"))

(defvar *hook-registry* (make-hash-table :test #'equal)
  "Maps event-name (string) to a list of callback functions.
   The first element of the list is the most recently added hook (front-push).")

(defun add-hook (event-name callback)
  "Push CALLBACK to the front of the hook list for EVENT-NAME.
   Subsequent add-hook calls for the same event-name prepend additional hooks,
   so hooks run newest-first."
  (setf (gethash event-name *hook-registry*)
        (cons callback (gethash event-name *hook-registry*))))

(defun remove-hook (event-name callback)
  "Remove CALLBACK (tested with #'eq) from the hook list for EVENT-NAME.
   All occurrences are removed."
  (setf (gethash event-name *hook-registry*)
        (remove callback (gethash event-name *hook-registry*) :test #'eq)))

(defun run-hooks (event-name &rest args)
  "Call each registered hook for EVENT-NAME with ARGS.
   Errors signalled by individual hooks are always suppressed so that a broken
   hook never prevents the rest from running."
  (dolist (cb (gethash event-name *hook-registry*))
    (ignore-errors (apply cb args))))

(defun clear-hooks (event-name)
  "Remove all hooks registered for EVENT-NAME."
  (remhash event-name *hook-registry*))

(defun list-hooks ()
  "Return an alist of (event-name . hook-count) for all registered events.
   Note: iteration order over the registry is undefined — callers must not
   rely on the order of entries in the returned alist."
  (let (result)
    (maphash (lambda (name hooks)
               (push (cons name (length hooks)) result))
             *hook-registry*)
    result))
