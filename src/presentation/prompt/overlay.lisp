(in-package #:nerimux/prompt)

;;;; Overlay, popup, and menu state.
;;;;
;;;; This file holds the three overlay concerns that were originally bundled in
;;;; prompt.lisp.  They share the nerimux/prompt package and are driven by
;;;; dispatch.lisp / rendered by renderer.lisp.  Splitting them here keeps
;;;; prompt.lisp focused solely on single-line editing.

;;; -- Dismissible overlay (e.g. list-keys help) --------------------------------

(defvar *overlay* nil
  "Active overlay text (a string, possibly multi-line) shown over the session,
   or NIL.  Dismissed by q or Esc; scrolled by j/k.  Main-thread-only, like *prompt*.")

(defvar *overlay-scroll-offset* 0
  "Current scroll offset (in lines) for the active overlay pager.
   0 means the first line is shown at the top.  Reset to 0 when a new overlay
   is displayed.  Main-thread-only.")

(defvar *overlay-shown-at* 0
  "Universal-time when the most recent transient overlay was shown.
   Set by show-transient-overlay for display-time auto-dismiss.")

(defun overlay-active-p ()
  "True when an overlay is currently displayed."
  (and *overlay* t))

(defun overlay-shown-at ()
  "Return the universal-time when the most recent transient overlay was shown.
   Returns 0 when no transient overlay has been shown in this session.
   Provided as a package-boundary accessor so callers never read the private
   *overlay-shown-at* variable directly."
  *overlay-shown-at*)

(defun %set-overlay (text)
  "Internal helper: install TEXT as the active overlay and reset the scroll
   offset.  Callers are responsible for setting *overlay-shown-at* as the
   variant requires."
  (setf *overlay* text
        *overlay-scroll-offset* 0))

(defun show-overlay (text)
  "Display TEXT as an overlay; navigated with j/k, dismissed with q or Esc."
  (%set-overlay text))

(defun show-transient-overlay (text &key (timestamp (get-universal-time)))
  "Display TEXT as a transient overlay that auto-dismisses after display-time ms.
   Used for display-message and similar short notifications.
   TIMESTAMP defaults to (get-universal-time); supply an explicit value in tests
   so assertions can verify the recorded value deterministically."
  (%set-overlay text)
  (setf *overlay-shown-at* timestamp))

(defun clear-overlay ()
  "Dismiss the active overlay and reset the scroll offset."
  (setf *overlay* nil
        *overlay-scroll-offset* 0))

(defun overlay-lines ()
  "The active overlay split into a list of lines, or NIL when inactive."
  (when *overlay*
    (loop with text = *overlay*
          for start = 0 then (1+ newline-pos)
          for newline-pos = (position #\Newline text :start start)
          collect (subseq text start (or newline-pos (length text)))
          while newline-pos)))

(defun overlay-scroll (delta)
  "Scroll the active overlay by DELTA lines (positive = down, negative = up).
   Clamps to valid range.  No-op when no overlay is active."
  (when *overlay*
    (let* ((lines (overlay-lines))
           (max-offset (max 0 (1- (length lines)))))
      (setf *overlay-scroll-offset*
            (max 0 (min max-offset (+ *overlay-scroll-offset* delta)))))))

;;; -- Singleton overlay lifecycle (popup, menu) -------------------------------
;;;
;;; A "singleton overlay" is one at most one of which is active at a time, held
;;; in a single special variable.  Popups and menus share the identical
;;; show/dismiss/predicate lifecycle, so it is generated once from a declarative
;;; (kind, backing-variable) pair rather than hand-written per kind.

(defmacro define-singleton-overlay (kind var)
  "Generate the SHOW-KIND / CLOSE-KIND / KIND-ACTIVE-P lifecycle accessors for a
   singleton overlay of type KIND backed by the special variable VAR.  Callers go
   through these accessors so the lifecycle boundary stays inside this module
   instead of touching VAR directly."
  (flet ((sym (control) (intern (format nil control (symbol-name kind))
                                (symbol-package kind))))
    (let ((show (sym "SHOW-~A"))
          (close (sym "CLOSE-~A"))
          (active-p (sym "~A-ACTIVE-P")))
      `(progn
         (defun ,show (,kind)
           ,(format nil "Register ~(~A~) as the active ~(~:*~A~) overlay.  Any ~
                         currently-active one is silently replaced (not torn ~
                         down); call ~(~A~) first when the previous overlay needs ~
                         cleanup." (symbol-name kind) (symbol-name close))
           (setf ,var ,kind))
         (defun ,close ()
           ,(format nil "Dismiss the active ~(~A~) overlay by setting ~(~A~) to ~
                         NIL.  Safe to call when none is active (a no-op)."
                    (symbol-name kind) (symbol-name var))
           (setf ,var nil))
         (defun ,active-p ()
           ,(format nil "Return T when a ~(~A~) overlay is currently displayed, ~
                         NIL otherwise." (symbol-name kind))
           (and ,var t))))))

;;; -- Popup overlay -----------------------------------------------------------

(defconstant +default-popup-width+  40
  "Default width (columns) for a newly created popup overlay.")

(defconstant +default-popup-height+ 10
  "Default height (rows) for a newly created popup overlay.")

(defstruct popup
  "A floating overlay window with its own PTY and screen."
  (width  +default-popup-width+  :type fixnum)
  (height +default-popup-height+ :type fixnum)
  (screen nil)             ; screen struct for the popup (or NIL for text-only)
  (pane   nil)             ; pane struct for the popup (or NIL for text-only)
  (title  "" :type string)
  (close-on-exit t :type boolean))

(defvar *active-popup* nil
  "The currently displayed POPUP overlay, or NIL.
   Session-persistent: use defvar so image reloads do not reset live state.")

(define-singleton-overlay popup *active-popup*)

;;; -- Menu overlay ------------------------------------------------------------

(defstruct menu
  "An interactive text menu overlay."
  (title "" :type string)
  (items '() :type list)          ; list of (label . keyword) pairs
  (selected-index 0 :type fixnum)
  ;; Position (display-menu -x/-y): NIL = centre on screen, integer = fixed column/row.
  (x nil)
  (y nil)
  ;; display-menu -O: the menu stays open after a selection runs its command.
  (keep-open nil :type boolean))

(defvar *active-menu* nil
  "The currently displayed MENU overlay, or NIL.
   Session-persistent: use defvar so image reloads do not reset live state.")

(define-singleton-overlay menu *active-menu*)
