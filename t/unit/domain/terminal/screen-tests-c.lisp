(in-package #:nerimux/test)

(declaim (notinline nerimux/terminal/types:reset-sgr-pen))

;;;; Screen tests — part III: screen-clear-dirty, reset-sgr-pen, bell-pending, screen-consume-bell, miscellaneous slots, copy-mode extra slots.

(describe "terminal-suite/resize"

  ;;; ── screen-clear-dirty ───────────────────────────────────────────────────────

  ;; screen-clear-dirty sets dirty-p to NIL; calling it twice leaves the flag NIL.
  (it "screen-clear-dirty-resets-and-is-idempotent"
    (with-screen (s 10 5)
      (expect (nerimux/terminal/types:screen-dirty-p s) :to-be-truthy)
      (screen-clear-dirty s)
      (expect (nerimux/terminal/types:screen-dirty-p s) :to-be-falsy)
      (screen-clear-dirty s)
      (expect (nerimux/terminal/types:screen-dirty-p s) :to-be-falsy))))

;;; ── reset-sgr-pen ────────────────────────────────────────────────────────────

(describe "terminal-suite/reset-sgr-pen-suite"

  ;; reset-sgr-pen sets all five SGR pen fields to VT100 defaults.
  (it "reset-sgr-pen-restores-all-five-slots"
    (with-screen (s 10 5)
      ;; Dirty all five pen slots.
      (setf (nerimux/terminal/types:screen-cur-fg       s) 3
            (nerimux/terminal/types:screen-cur-bg       s) 4
            (nerimux/terminal/types:screen-cur-attrs    s) #b11111111
            (nerimux/terminal/types:screen-cur-attrs2   s) #b00000011
            (nerimux/terminal/types:screen-cur-ul-color s) 200)
      (nerimux/terminal/types:reset-sgr-pen s)
      (expect (= nerimux/terminal/types:+default-color+ (nerimux/terminal/types:screen-cur-fg       s)))
      (expect (= nerimux/terminal/types:+default-color+ (nerimux/terminal/types:screen-cur-bg       s)))
      (expect (= 0 (nerimux/terminal/types:screen-cur-attrs    s)))
      (expect (= 0 (nerimux/terminal/types:screen-cur-attrs2   s)))
      (expect (= 0 (nerimux/terminal/types:screen-cur-ul-color s)))))

  ;; Calling reset-sgr-pen twice leaves pen in the default state.
  (it "reset-sgr-pen-idempotent"
    (with-screen (s 10 5)
      (nerimux/terminal/types:reset-sgr-pen s)
      (nerimux/terminal/types:reset-sgr-pen s)
      (expect (= nerimux/terminal/types:+default-color+ (nerimux/terminal/types:screen-cur-fg s)))
      (expect (= nerimux/terminal/types:+default-color+ (nerimux/terminal/types:screen-cur-bg s)))))

  ;; A fresh screen's cur-fg and cur-bg SGR pen slots start at the default-colour sentinel.
  (it "screen-cur-fg-and-cur-bg-default-to-sentinel"
    (with-screen (s 10 5)
      (expect (= nerimux/terminal/types:+default-color+ (nerimux/terminal/types:screen-cur-fg s)))
      (expect (= nerimux/terminal/types:+default-color+ (nerimux/terminal/types:screen-cur-bg s))))))

;;; ── bell-pending slot ────────────────────────────────────────────────────────

(describe "terminal-suite/bell-pending-c-suite"

  ;; bell-pending defaults to NIL and can be toggled via setf.
  (it "bell-pending-default-and-toggle"
    (with-screen (s 10 5)
      (expect (nerimux/terminal/types:screen-bell-pending s) :to-be-falsy)
      (setf (nerimux/terminal/types:screen-bell-pending s) t)
      (expect (nerimux/terminal/types:screen-bell-pending s))
      (setf (nerimux/terminal/types:screen-bell-pending s) nil)
      (expect (nerimux/terminal/types:screen-bell-pending s) :to-be-falsy)))

  ;; Feeding a BEL byte (0x07) via screen-process-bytes sets bell-pending.
  (it "bel-byte-sets-bell-pending"
    (with-screen (s 10 5)
      (screen-clear-dirty s)
      ;; Feed BEL (7) directly
      (screen-process-bytes s (make-array 1 :element-type '(unsigned-byte 8)
                                            :initial-contents '(7)))
      (expect (nerimux/terminal/types:screen-bell-pending s) :to-be-truthy))))

;;; ── screen-consume-bell ──────────────────────────────────────────────────────

(describe "terminal-suite/screen-consume-bell-c-suite"

  ;; screen-consume-bell returns NIL and has no side effect when bell is not pending.
  (it "screen-consume-bell-returns-nil-when-no-bell-pending"
    (with-screen (s 10 5)
      ;; Fresh screen has no bell pending.
      (expect (nerimux/terminal/types:screen-consume-bell s) :to-be-falsy)
      ;; Flag must still be NIL.
      (expect (nerimux/terminal/types:screen-bell-pending s) :to-be-falsy)))

  ;; screen-consume-bell returns T when pending and clears the flag; second call returns NIL.
  (it "screen-consume-bell-returns-true-clears-then-nil"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-bell-pending s) t)
      (expect (nerimux/terminal/types:screen-consume-bell s) :to-be-truthy)
      (expect (nerimux/terminal/types:screen-bell-pending s) :to-be-falsy)
      (expect (nerimux/terminal/types:screen-consume-bell s) :to-be-falsy)))

  ;; screen-consume-bell clears the flag set by a real BEL byte.
  (it "screen-consume-bell-after-bel-byte"
    (with-screen (s 10 5)
      (screen-process-bytes s (make-array 1 :element-type '(unsigned-byte 8)
                                            :initial-contents '(7)))
      ;; Bell should be pending now.
      (expect (nerimux/terminal/types:screen-bell-pending s) :to-be-truthy)
      ;; Consume it.
      (expect (nerimux/terminal/types:screen-consume-bell s) :to-be-truthy)
      (expect (nerimux/terminal/types:screen-bell-pending s) :to-be-falsy))))

;;; ── SUITE: miscellaneous screen slots ────────────────────────────────────────

(describe "terminal-suite/screen-slots"

  ;; screen-last-char is NIL on a fresh screen and updates to the last character written.
  (it "screen-last-char-nil-then-updated"
    (with-screen (s 10 5)
      (expect (null (nerimux/terminal/types:screen-last-char s)))
      (feed s "Z")
      (expect (char= #\Z (nerimux/terminal/types:screen-last-char s)))))

  ;; Fresh screens have expected default values: charset :ascii, autowrap T, cursor-shape 1, etc.
  (it "screen-slot-defaults-table"
    (dolist (row (list (list #'nerimux/terminal/types:screen-charset        :ascii "charset defaults to :ascii")
                       (list #'nerimux/terminal/types:screen-autowrap        t      "autowrap defaults to T")
                       (list #'nerimux/terminal/types:screen-cursor-shape    1      "cursor-shape defaults to 1")
                       (list #'nerimux/terminal/types:screen-bracketed-paste nil    "bracketed-paste defaults to NIL")
                       (list #'nerimux/terminal/types:screen-app-cursor-keys nil    "app-cursor-keys defaults to NIL")
                       (list #'screen-title                                   ""     "title defaults to empty string")
                       (list #'screen-copy-mark                               nil    "copy-mark defaults to NIL")))
      (destructuring-bind (accessor expected desc) row
        (declare (ignore desc))
        (with-screen (s 10 5)
          (expect (equal expected (funcall accessor s))))))))

;;; ── SUITE: copy-mode extra slots ─────────────────────────────────────────────

(describe "terminal-suite/copy-mode-extra-slots"

  ;; copy-mode-entered-by-mouse-p defaults to NIL on a fresh screen.
  (it "copy-mode-entered-by-mouse-defaults-nil"
    (with-screen (s 10 5)
      (expect (nerimux/terminal/types:screen-copy-mode-entered-by-mouse-p s) :to-be-falsy)))

  ;; copy-mode-entered-by-mouse-p can be set and cleared via setf.
  (it "copy-mode-entered-by-mouse-can-be-set"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-copy-mode-entered-by-mouse-p s) t)
      (expect (nerimux/terminal/types:screen-copy-mode-entered-by-mouse-p s) :to-be-truthy)
      (setf (nerimux/terminal/types:screen-copy-mode-entered-by-mouse-p s) nil)
      (expect (nerimux/terminal/types:screen-copy-mode-entered-by-mouse-p s) :to-be-falsy)))

  ;; copy-exit-on-bottom defaults to NIL on a fresh screen.
  (it "copy-exit-on-bottom-defaults-nil"
    (with-screen (s 10 5)
      (expect (nerimux/terminal/types:screen-copy-exit-on-bottom s) :to-be-falsy)))

  ;; copy-exit-on-bottom can be set and cleared via setf.
  (it "copy-exit-on-bottom-can-be-set"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-copy-exit-on-bottom s) t)
      (expect (nerimux/terminal/types:screen-copy-exit-on-bottom s) :to-be-truthy)
      (setf (nerimux/terminal/types:screen-copy-exit-on-bottom s) nil)
      (expect (nerimux/terminal/types:screen-copy-exit-on-bottom s) :to-be-falsy))))

;;; ── SUITE: OSC 10/11 default colour slots ─────────────────────────────────

(describe "terminal-suite/osc-default-color-slots"

  ;; screen-osc-default-fg on a fresh screen equals +osc-default-fg+ (white).
  (it "osc-default-fg-initial-value-matches-constant"
    (with-screen (s 10 5)
      (expect (= nerimux/terminal/types:+osc-default-fg+
                 (nerimux/terminal/types:screen-osc-default-fg s)))))

  ;; screen-osc-default-bg on a fresh screen equals +osc-default-bg+ (black).
  (it "osc-default-bg-initial-value-matches-constant"
    (with-screen (s 10 5)
      (expect (= nerimux/terminal/types:+osc-default-bg+
                 (nerimux/terminal/types:screen-osc-default-bg s)))))

  ;; OSC 10 ; #RRGGBB changes osc-default-fg; OSC 110 resets it to white.
  (it "osc-default-fg-can-be-set-and-reset-via-sequence"
    (with-screen (s 10 5)
      ;; Set foreground to a custom colour via OSC 10 ; #112233 ST
      (feed s (format nil "~C]10;#112233~C\\" #\Escape #\Escape))
      (expect (= #x112233 (nerimux/terminal/types:screen-osc-default-fg s)))
      ;; Reset via OSC 110 ST
      (feed s (format nil "~C]110~C\\" #\Escape #\Escape))
      (expect (= nerimux/terminal/types:+osc-default-fg+
                 (nerimux/terminal/types:screen-osc-default-fg s)))))

  ;; OSC 11 ; #RRGGBB changes osc-default-bg; OSC 111 resets it to black.
  (it "osc-default-bg-can-be-set-and-reset-via-sequence"
    (with-screen (s 10 5)
      ;; Set background to a custom colour via OSC 11 ; #AABBCC ST
      (feed s (format nil "~C]11;#aabbcc~C\\" #\Escape #\Escape))
      (expect (= #xAABBCC (nerimux/terminal/types:screen-osc-default-bg s)))
      ;; Reset via OSC 111 ST
      (feed s (format nil "~C]111~C\\" #\Escape #\Escape))
      (expect (= nerimux/terminal/types:+osc-default-bg+
                 (nerimux/terminal/types:screen-osc-default-bg s))))))

;;; ── SUITE: OSC 8 current-hyperlink slot ──────────────────────────────────

(describe "terminal-suite/current-hyperlink-slots"

  ;; screen-current-hyperlink is NIL on a fresh screen.
  (it "screen-current-hyperlink-defaults-nil"
    (with-screen (s 10 5)
      (expect (null (nerimux/terminal/types:screen-current-hyperlink s)))))

  ;; OSC 8 ; ; URI sets screen-current-hyperlink to the URI string.
  (it "screen-current-hyperlink-set-by-osc8"
    (with-screen (s 10 5)
      (feed s (format nil "~C]8;;https://example.com~C\\" #\Escape #\Escape))
      (expect (string= "https://example.com"
                       (nerimux/terminal/types:screen-current-hyperlink s)))))

  ;; OSC 8 ; ; (empty URI) clears screen-current-hyperlink back to NIL.
  (it "screen-current-hyperlink-cleared-by-osc8-empty"
    (with-screen (s 10 5)
      (feed s (format nil "~C]8;;https://example.com~C\\" #\Escape #\Escape))
      (expect (nerimux/terminal/types:screen-current-hyperlink s))
      ;; Clear with empty URI
      (feed s (format nil "~C]8;;~C\\" #\Escape #\Escape))
      (expect (null (nerimux/terminal/types:screen-current-hyperlink s)))))

  ;; Characters written while a hyperlink is active carry the URI in their cell hyperlink slot.
  (it "screen-current-hyperlink-stamped-onto-written-cells"
    (with-screen (s 10 5)
      (feed s (format nil "~C]8;;https://cl.org~C\\" #\Escape #\Escape))
      (feed s "AB")
      ;; The hyperlink must be stamped on both cells
      (expect (string= "https://cl.org"
                       (nerimux/terminal/types:cell-hyperlink (cell-at s 0 0))))
      (expect (string= "https://cl.org"
                       (nerimux/terminal/types:cell-hyperlink (cell-at s 1 0))))
      ;; After clearing the hyperlink, new cells must have NIL
      (feed s (format nil "~C]8;;~C\\" #\Escape #\Escape))
      (feed s "C")
      (expect (null (nerimux/terminal/types:cell-hyperlink (cell-at s 2 0)))))))

;;; ── SUITE: %clear-line-wrapped ────────────────────────────────────────────

(describe "terminal-suite/clear-line-wrapped-suite"

  ;; %clear-line-wrapped removes a wrap flag that was previously set.
  (it "clear-line-wrapped-removes-set-flag"
    (with-screen (s 10 5)
      (nerimux/terminal/types:%mark-line-wrapped s 2)
      (expect (nerimux/terminal/types:%line-wrapped-p s 2) :to-be-truthy)
      (nerimux/terminal/types:%clear-line-wrapped s 2)
      (expect (nerimux/terminal/types:%line-wrapped-p s 2) :to-be-falsy)))

  ;; %clear-line-wrapped on a row that was never marked is a no-op (no error).
  (it "clear-line-wrapped-is-noop-on-unmarked-row"
    (with-screen (s 10 5)
      ;; No hash-table exists yet; calling clear on an unmarked row must not signal.
      (finishes (nerimux/terminal/types:%clear-line-wrapped s 3))
      (expect (nerimux/terminal/types:%line-wrapped-p s 3) :to-be-falsy)))

  ;; %clear-line-wrapped removes only the specified row's flag.
  (it "clear-line-wrapped-does-not-disturb-other-rows"
    (with-screen (s 10 5)
      (nerimux/terminal/types:%mark-line-wrapped s 0)
      (nerimux/terminal/types:%mark-line-wrapped s 1)
      (nerimux/terminal/types:%mark-line-wrapped s 2)
      (nerimux/terminal/types:%clear-line-wrapped s 1)
      (expect (nerimux/terminal/types:%line-wrapped-p s 0) :to-be-truthy)
      (expect (nerimux/terminal/types:%line-wrapped-p s 1) :to-be-falsy)
      (expect (nerimux/terminal/types:%line-wrapped-p s 2) :to-be-truthy)))

  ;; %clear-line-wrapped on a screen with no wrapped-rows hash-table is silent.
  (it "clear-line-wrapped-is-noop-when-no-hash-table"
    (with-screen (s 10 5)
      ;; Fresh screen has nil wrapped-rows — ensure there is no error.
      (expect (null (nerimux/terminal/types:screen-wrapped-rows s)))
      (finishes (nerimux/terminal/types:%clear-line-wrapped s 0))
      (expect (nerimux/terminal/types:%line-wrapped-p s 0) :to-be-falsy))))
