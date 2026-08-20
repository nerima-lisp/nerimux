(in-package #:nerimux/format)

;;;; Pane-geometry / screen / client section builders for format-context.
;;;;
;;;; Split out of format-context.lisp: these three section builders are more
;;;; mechanical getter tables (pane bounding-box arithmetic, copy-mode/screen
;;;; state, and client/server/host environment lookups) than the model-facing
;;;; session/window/pane-structural builders that remain in format-context.lisp.
;;;; format-context-from-session (format-context.lisp) appends all six slices.

;;; ── Client section helpers ──────────────────────────────────────────────────

(defun %current-time-string ()
  "Return HH:MM string from the system clock."
  (multiple-value-bind (sec min hour) (get-decoded-time)
    (declare (ignore sec))
    (format nil "~2,'0D:~2,'0D" hour min)))

(defun %short-hostname (h)
  "Return the hostname up to the first dot, or the full string if no dot."
  (subseq h 0 (or (position #\. h) (length h))))

;;; ── Context plist section builders ──────────────────────────────────────────

(defun %pane-geometry-context-plist (pane window)
  "Build the pane-geometry slice of the format-context plist for PANE within WINDOW."
  (list :pane-width           (if pane (nerimux/model:pane-width  pane) 0)
        :pane-height          (if pane (nerimux/model:pane-height pane) 0)
        :pane-pid             (if pane (nerimux/model:pane-pid    pane) 0)
        :pane-left            (if pane (nerimux/model:pane-x      pane) 0)
        :pane-top             (if pane (nerimux/model:pane-y      pane) 0)
        :pane-right           (if pane (+ (nerimux/model:pane-x pane)
                                          (nerimux/model:pane-width pane) -1) 0)
        :pane-bottom          (if pane (+ (nerimux/model:pane-y pane)
                                          (nerimux/model:pane-height pane) -1) 0)
        :pane-at-top          (if (and pane (= (nerimux/model:pane-y pane) 0)) "1" "0")
        :pane-at-left         (if (and pane (= (nerimux/model:pane-x pane) 0)) "1" "0")
        :pane-at-bottom       (if (and pane window
                                       (= (+ (nerimux/model:pane-y    pane)
                                             (nerimux/model:pane-height pane))
                                          (nerimux/model:window-height window)))
                                  "1" "0")
        :pane-at-right        (if (and pane window
                                       (= (+ (nerimux/model:pane-x   pane)
                                             (nerimux/model:pane-width pane))
                                          (nerimux/model:window-width window)))
                                  "1" "0")))

(defun %synthesized-client-key-table (pane-scr)
  "The name of the client's current key table (tmux client_key_table): either
   \"copy-mode\" or \"root\".

   tmux synthesizes this as prefix > copy-mode > custom key table > root.  The
   first and third arms are gone.  Both resolved a NERIMUX special by name --
   *PREFIX-ACTIVE* and *KEY-TABLE* -- and neither symbol has ever been defined
   anywhere in this tree, so find-symbol returned NIL and both arms were
   permanently unreachable while reading like live guards.  There are no
   user-definable key tables any more, and the workspace UI's prefix (C-q) is
   per-client state on the connection rather than a server-wide special."
  (if (and pane-scr (nerimux/terminal:screen-copy-mode-p pane-scr))
      "copy-mode"
      "root"))

(defmacro %if-copy-mode (pane-scr value-form)
  "Evaluate VALUE-FORM when PANE-SCR exists and is in copy mode; otherwise \"\".
   Factors out the (if (and pane-scr (screen-copy-mode-p pane-scr)) … \"\")
   guard repeated across the copy-mode-only format variables below."
  `(if (and ,pane-scr (nerimux/terminal:screen-copy-mode-p ,pane-scr))
       ,value-form
       ""))

(defmacro %copy-mode-flag (pane-scr &optional extra-condition)
  "\"1\"/\"0\" for PANE-SCR being in copy mode, optionally ANDed with
   EXTRA-CONDITION (e.g. an active selection)."
  `(if (and ,pane-scr
            (nerimux/terminal:screen-copy-mode-p ,pane-scr)
            ,@(when extra-condition (list extra-condition)))
       "1" "0"))

(defun %screen-context-plist (pane-scr cursor-x cursor-y)
  "Build the screen/copy-mode slice of the format-context plist for PANE-SCR.
   PANE-SCR is the pane's screen object (or NIL); CURSOR-X and CURSOR-Y are
   its pre-computed cursor coordinates."
  (list :cursor-x             cursor-x
        :cursor-y             cursor-y
        :cursor-character
        (if (and pane-scr
                 (< -1 cursor-x (nerimux/terminal:screen-width  pane-scr))
                 (< -1 cursor-y (nerimux/terminal:screen-height pane-scr)))
            (string (nerimux/terminal:cell-char
                     (nerimux/terminal:screen-cell pane-scr cursor-x cursor-y)))
            "")
        :pane-in-mode         (%copy-mode-flag pane-scr)
        ;; tmux #{client_key_table}: "copy-mode" while the active pane is in
        ;; copy mode, else "root".  See the function for why the "prefix" and
        ;; custom-key-table arms are gone.
        :client-key-table     (%synthesized-client-key-table pane-scr)
        :pane-mode            (%if-copy-mode pane-scr "copy-mode")
        :scroll-position
        (%if-copy-mode pane-scr
                       (format nil "~D" (nerimux/terminal:screen-copy-offset pane-scr)))
        :copy-position
        (%if-copy-mode pane-scr
                       (format nil "~D" (nerimux/terminal:screen-copy-offset pane-scr)))
        :copy-position-limit
        (%if-copy-mode pane-scr
                       (format nil "~D" (length (nerimux/terminal:screen-scrollback pane-scr))))
        :selection-active
        (%copy-mode-flag pane-scr (nerimux/terminal:screen-copy-selecting pane-scr))
        :selection-present
        (%copy-mode-flag pane-scr (nerimux/terminal:screen-copy-selecting pane-scr))
        :copy-cursor-x
        (%if-copy-mode pane-scr
                       (format nil "~D" (cdr (nerimux/terminal:screen-copy-cursor pane-scr))))
        :copy-cursor-y
        (%if-copy-mode pane-scr
                       (format nil "~D" (car (nerimux/terminal:screen-copy-cursor pane-scr))))
        :history-size         (format nil "~D"
                                      (if pane-scr
                                          (length (nerimux/terminal:screen-scrollback pane-scr))
                                          0))
        ;; Terminal-state flags (tmux exposes the pane's mode bits directly).
        :cursor-flag          (if (and pane-scr (nerimux/terminal:screen-cursor-visible pane-scr))
                                  "1" "0")
        :insert-flag          (if (and pane-scr (nerimux/terminal:screen-insert-mode pane-scr))
                                  "1" "0")
        :wrap-flag            (if (and pane-scr (nerimux/terminal:screen-autowrap pane-scr))
                                  "1" "0")
        :origin-flag          (if (and pane-scr (nerimux/terminal:screen-origin-mode pane-scr))
                                  "1" "0")
        :keypad-cursor-flag   (if (and pane-scr (nerimux/terminal:screen-app-cursor-keys pane-scr))
                                  "1" "0")
        :alternate-on         (if (and pane-scr (nerimux/terminal:screen-alt-cells pane-scr))
                                  "1" "0")
        :scroll-region-upper  (if pane-scr
                                  (format nil "~D" (nerimux/terminal:screen-scroll-top pane-scr))
                                  "")
        :scroll-region-lower  (if pane-scr
                                  (format nil "~D" (nerimux/terminal:screen-scroll-bottom pane-scr))
                                  "")
        ;; Mouse reporting flags (screen-mouse-mode: 0 off, 1/2/3 = ?1000/?1002/?1003).
        :mouse-any-flag       (if (and pane-scr
                                       (plusp (nerimux/terminal:screen-mouse-mode pane-scr)))
                                  "1" "0")
        :mouse-standard-flag  (if (and pane-scr
                                       (= 1 (nerimux/terminal:screen-mouse-mode pane-scr)))
                                  "1" "0")
        :mouse-button-flag    (if (and pane-scr
                                       (= 2 (nerimux/terminal:screen-mouse-mode pane-scr)))
                                  "1" "0")
        :mouse-all-flag       (if (and pane-scr
                                       (= 3 (nerimux/terminal:screen-mouse-mode pane-scr)))
                                  "1" "0")
        :mouse-sgr-flag       (if (and pane-scr
                                       (nerimux/terminal:screen-mouse-sgr-mode pane-scr))
                                  "1" "0")
        ;; Copy-mode search / selection details.
        :pane-search-string   (or (and pane-scr
                                       (nerimux/terminal:screen-copy-search-term pane-scr))
                                  "")
        :rectangle-toggle     (if (and pane-scr
                                       (nerimux/terminal:screen-copy-rect-select-p pane-scr))
                                  "1" "0")
        :selection-start-x    (let ((m (and pane-scr (nerimux/terminal:screen-copy-mark pane-scr))))
                                (if m (format nil "~D" (cdr m)) ""))
        :selection-start-y    (let ((m (and pane-scr (nerimux/terminal:screen-copy-mark pane-scr))))
                                (if m (format nil "~D" (car m)) ""))
        :selection-end-x      (let ((c (and pane-scr
                                            (nerimux/terminal:screen-copy-selecting pane-scr)
                                            (nerimux/terminal:screen-copy-cursor pane-scr))))
                                (if c (format nil "~D" (cdr c)) ""))
        :selection-end-y      (let ((c (and pane-scr
                                            (nerimux/terminal:screen-copy-selecting pane-scr)
                                            (nerimux/terminal:screen-copy-cursor pane-scr))))
                                (if c (format nil "~D" (car c)) ""))))

(defun %client-context-plist (client-width client-height client-tty hostname pid-str)
  "Build the client/server/host/environment slice of the format-context plist.
   CLIENT-WIDTH, CLIENT-HEIGHT, and CLIENT-TTY describe the attached client;
   HOSTNAME and PID-STR are pre-computed by the caller."
  (list ;; #{client_flags} is always "".  It read *CLIENT-FLAGS* out of the
        ;; NERIMUX package by find-symbol; that variable was only ever written
        ;; by `refresh-client -f', which went with the tmux command table, so
        ;; it sat bound to NIL forever and this rendered the empty string while
        ;; looking like a live lookup.  The variable is now deleted and the
        ;; constant stated outright -- same output, no booby trap.  Compare
        ;; :client-prefix below, which had the identical shape.
        :client-flags ""
        :client-readonly
        (let* ((sym (find-symbol "*CLIENT-READ-ONLY*" "NERIMUX"))
               (val (and sym (boundp sym) (symbol-value sym))))
          (if val "1" "0"))
        :socket-path
        (let* ((sym (find-symbol "*BOUND-SOCKET-PATH*" "NERIMUX"))
               (val (and sym (boundp sym) (symbol-value sym))))
          (or val ""))
        :client-width         client-width
        :client-height        client-height
        :client-tty           client-tty
        :client-name          client-tty
        :client-termname      (or (ignore-errors (sb-ext:posix-getenv "TERM")) "")
        :client-pid           pid-str
        ;; #{client_prefix} is always "0".  It read *PREFIX-ACTIVE* out of the
        ;; NERIMUX package by find-symbol, and that symbol has never existed in
        ;; this tree -- find-symbol returns NIL, (symbol-value nil) is legal CL
        ;; and yields NIL, so this silently rendered "0" while looking like a
        ;; live lookup.  With the tmux prefix key gone the symbol can never
        ;; appear, so the constant is stated outright rather than left as a
        ;; lookup that cannot resolve.  The workspace UI's own prefix (C-q) is
        ;; per-client state on the connection, not a server-wide special.
        :client-prefix        "0"
        :client-last-session  ""
        :server-pid           pid-str
        :version              (nerimux/version:version-string)
        :hostname             hostname
        :host                 hostname
        :host-short           (%short-hostname hostname)
        :time                 (%current-time-string)
        :term-program         (or (ignore-errors (sb-ext:posix-getenv "TERM_PROGRAM")) "")
        :colorterm            (or (ignore-errors (sb-ext:posix-getenv "COLORTERM")) "")
        :history-limit        (format nil "~D"
                                      (or (nerimux/options:get-option "history-limit") 2000))))
