(in-package #:nerimux/terminal/csi)

;;;; Compile-time fact-table constructors for CSI reply helpers.
(defmacro define-fixed-reply-enqueuers (&rest specs)
  "Generate enqueuer functions for static (load-time) reply strings.
   Each SPEC is (fn-name reply-form docstring).
   REPLY-FORM is evaluated once at load time via load-time-value."
  `(progn
     ,@(mapcar
        (lambda (spec)
          (destructuring-bind (name reply doc) spec
            `(defun ,name (screen)
               ,doc
               (%enqueue-reply screen (load-time-value ,reply t)))))
        specs)))

(defmacro define-decrqm-mode-table (&rest specs)
  "Generate %DECRQM-MODE-STATE from a declarative (mode-number accessor-fn) table.
   SPECS forms:
     (mode-num accessor-fn)         — call (accessor-fn screen) and encode as flag
     (mode-num :alt-screen)         — flag code for (and (screen-alt-cells screen) t)
     (mode-num :fixed code)         — always return CODE (for modes not tracked dynamically)"
  `(defun %decrqm-mode-state (screen mode)
     "DECRQM reply value for DEC private MODE: 1 = set, 2 = reset, 0 = not recognised.
      Reports from the screen's tracked mode flags so an application querying support
      gets an accurate answer; an unknown mode reports 0 (so the app falls back)."
     (case mode
       ,@(mapcar
          (lambda (spec)
            (destructuring-bind (mode-number &rest rest) spec
              (cond
                ((and (= (length rest) 1) (eq (first rest) :alt-screen))
                 `(,mode-number
                   (%decrqm-flag-code (and (screen-alt-cells screen) t))))
                ((and (= (length rest) 2) (eq (first rest) :fixed))
                 `(,mode-number ,(second rest)))
                ((and (= (length rest) 1)
                      (symbolp (first rest))
                      (not (keywordp (first rest))))
                 `(,mode-number (%decrqm-flag-code (,(first rest) screen))))
                (t
                 (error "Unrecognised define-decrqm-mode-table spec: ~S" spec)))))
          specs)
       (t 0))))

(defconstant +xtwinops-text-area-query+
  18
  "XTWINOPS op 18: query text-area size in characters; reply uses code 8.")

(defconstant +xtwinops-screen-query+
  19
  "XTWINOPS op 19: query screen size in characters; reply uses code 9.")

(defconstant +xtwinops-text-area-reply+
  8
  "XTWINOPS reply code for op 18 (text-area query): ESC [ 8 ; rows ; cols t.")

(defconstant +xtwinops-screen-reply+
  9
  "XTWINOPS reply code for op 19 (screen query): ESC [ 9 ; rows ; cols t.")
