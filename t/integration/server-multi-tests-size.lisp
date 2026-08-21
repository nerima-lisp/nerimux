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

  ;; The window-size option ("largest" / "latest" / "manual") is gone with
  ;; domain/options (R2.2): §1.4 hardcodes the shared size to always follow
  ;; the smallest attached client, with no other mode selectable, so a third
  ;; client joining at a smaller size than either of the two already covered
  ;; above still pulls the effective size down further.
  (it "multi-effective-size-smallest-still-wins-with-three-clients"
    (let ((nerimux::*clients*
            (list (nerimux::%make-client-conn :rows 50 :cols 200)
                  (nerimux::%make-client-conn :rows 40 :cols 120)
                  (nerimux::%make-client-conn :rows 24 :cols 80))))
      (multiple-value-bind (rows cols) (nerimux::%effective-client-size)
        (check-table (list (list rows 24 "effective rows = smallest of three clients")
                           (list cols 80 "effective cols = smallest of three clients")))))))
