(in-package #:nerimux/test)

;;;; Pure size-selection helpers for multi-client server behavior.

(describe "server-multi-suite"

  ;;; ── %client-fds / %client-size-reduce: pure registry helpers ─────────────────

  ;; %client-fds returns the socket fd of every entry in *clients*, in order.
  (it "client-fds-returns-fd-of-every-attached-client"
    (let ((nerimux::*clients*
            (list (nerimux::%make-client-conn :fd 11)
                  (nerimux::%make-client-conn :fd 22)
                  (nerimux::%make-client-conn :fd 33))))
      (expect (equal '(11 22 33) (nerimux::%client-fds)))))

  ;; %client-fds returns NIL when no clients are attached.
  (it "client-fds-empty-when-no-clients"
    (let ((nerimux::*clients* nil))
      (expect (null (nerimux::%client-fds)))))

  ;; %client-size-reduce applies the given reducing FN independently across every
  ;; attached client's rows and cols.
  (it "client-size-reduce-applies-fn-across-rows-and-cols"
    (let ((nerimux::*clients*
            (list (nerimux::%make-client-conn :rows 50 :cols 80)
                  (nerimux::%make-client-conn :rows 24 :cols 200)
                  (nerimux::%make-client-conn :rows 40 :cols 120))))
      (multiple-value-bind (min-rows min-cols) (nerimux::%client-size-reduce #'min)
        (check-table (list (list min-rows 24  "min reduce → smallest rows")
                           (list min-cols 80  "min reduce → smallest cols"))))
      (multiple-value-bind (max-rows max-cols) (nerimux::%client-size-reduce #'max)
        (check-table (list (list max-rows 50  "max reduce → largest rows")
                           (list max-cols 200 "max reduce → largest cols"))))))

  ;;; ── %effective-client-size: smallest attached client ─────────────────────────

  ;; The session renders at the SMALLEST attached client's geometry so every client
  ;; can display the shared broadcast frame.
  (it "multi-effective-size-is-smallest-client"
    (let ((nerimux::*clients*
            (list (nerimux::%make-client-conn :rows 50 :cols 200)
                  (nerimux::%make-client-conn :rows 24 :cols 80)
                  (nerimux::%make-client-conn :rows 40 :cols 120))))
      (multiple-value-bind (rows cols) (nerimux::%effective-client-size)
        (check-table (list (list rows 24 "effective rows = smallest client rows")
                           (list cols 80 "effective cols = smallest client cols"))))))

  ;; With no clients attached, %effective-client-size falls back to *term-rows*/cols.
  (it "multi-effective-size-no-clients-falls-back"
    (let ((nerimux::*clients* nil)
          (nerimux::*term-rows* 30)
          (nerimux::*term-cols* 100))
      (multiple-value-bind (rows cols) (nerimux::%effective-client-size)
        (check-table (list (list rows 30 "no clients → rows fallback to *term-rows*")
                           (list cols 100 "no clients → cols fallback to *term-cols*"))))))

  ;; window-size "largest" sizes to the biggest attached client.
  (it "multi-effective-size-largest-mode"
    (with-fresh-options
      (nerimux/options:set-option "window-size" "largest")
      (let ((nerimux::*clients*
              (list (nerimux::%make-client-conn :rows 50 :cols 200)
                    (nerimux::%make-client-conn :rows 24 :cols 80))))
        (multiple-value-bind (rows cols) (nerimux::%effective-client-size)
          (check-table (list (list rows 50 "largest rows")
                             (list cols 200 "largest cols")))))))

  ;; window-size "latest" sizes to the most-recent client (front of *clients*).
  (it "multi-effective-size-latest-mode"
    (with-fresh-options
      (nerimux/options:set-option "window-size" "latest")
      (let ((nerimux::*clients*
              (list (nerimux::%make-client-conn :rows 40 :cols 120)   ; most recent
                    (nerimux::%make-client-conn :rows 24 :cols 80))))
        (multiple-value-bind (rows cols) (nerimux::%effective-client-size)
          (check-table (list (list rows 40 "latest rows")
                             (list cols 120 "latest cols")))))))

  ;; window-size "manual" ignores client sizes and keeps *term-rows*/cols.
  (it "multi-effective-size-manual-mode-keeps-current"
    (with-fresh-options
      (nerimux/options:set-option "window-size" "manual")
      (let ((nerimux::*clients* (list (nerimux::%make-client-conn :rows 99 :cols 99)))
            (nerimux::*term-rows* 30)
            (nerimux::*term-cols* 100))
        (multiple-value-bind (rows cols) (nerimux::%effective-client-size)
          (check-table (list (list rows 30 "manual keeps current rows")
                             (list cols 100 "manual keeps current cols"))))))))
