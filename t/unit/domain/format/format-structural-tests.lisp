;;;; structural pane/session/window/terminal format variables

(in-package #:nerimux/test)

;;; ── find-symbol target audit ────────────────────────────────────────────────
;;;
;;; src/domain/format/ reaches runtime state in the NERIMUX package BY NAME,
;;; through find-symbol, so the format layer carries no dependency on the
;;; umbrella package.  The indirection is deliberate and fine.  Its sharp edge
;;; is not: when the target is deleted, find-symbol returns NIL instead of
;;; signalling, (symbol-value nil) is legal CL and yields NIL, and the format
;;; variable it fed silently renders empty.  No compiler warning, no red test.
;;;
;;; Two variables rotted exactly that way and were found only by a hand audit:
;;; *PREFIX-ACTIVE*, which had never been defined anywhere in this tree, and
;;; *CLIENT-FLAGS*, whose only writer (`refresh-client -f') went with the tmux
;;; command table.  Both are now plain constants.  A third, *CURRENT-MOUSE-EVENT*,
;;; is knowingly dead and is listed as the exception below.
;;;
;;; The helpers rescan the format sources on every run rather than checking a
;;; hardcoded list, so a NEW find-symbol site is covered without editing this
;;; file.  Text scanning, not reading: the reader would need every package in
;;; those files to exist at test time.  It can therefore MISS a site (a computed
;;; name, or unusual spacing) but never reports a false one.

(defun %format-source-files ()
  "Every .lisp under src/domain/format/, located via the ASDF system root."
  (directory (merge-pathnames
              #P"src/domain/format/*.lisp"
              (asdf:system-source-directory :nerimux))))

(defun %file-text (path)
  (with-open-file (in path :external-format :utf-8)
    (let ((buffer (make-string (file-length in))))
      (subseq buffer 0 (read-sequence buffer in)))))

(defun %nerimux-find-symbol-targets (text)
  "Every NAME occurring as (find-symbol \"NAME\" \"NERIMUX\") in TEXT."
  (let ((needle "(find-symbol \"")
        (targets '())
        (from 0))
    (loop
      (let ((hit (search needle text :start2 from)))
        (unless hit (return))
        (let* ((name-start (+ hit (length needle)))
               (name-end   (position #\" text :start name-start)))
          (unless name-end (return))
          (let* ((pkg-open (position #\" text :start (1+ name-end)))
                 (pkg-end  (and pkg-open (position #\" text :start (1+ pkg-open)))))
            (when (and pkg-end
                       (string= "NERIMUX" (subseq text (1+ pkg-open) pkg-end)))
              (push (subseq text name-start name-end) targets)))
          (setf from (1+ name-end)))))
    (nreverse targets)))

(describe "format-suite"

  ;;; These are pure functions of the session/window/pane structs, wired into
  ;;; format-context-from-session and exercised end-to-end through expand-format.

  ;; format-context-from-session populates pane geometry/id/pid variables that
  ;; expand-format resolves (#{pane_width} #{pane_height} #{pane_id} #{pane_left}
  ;; #{pane_top} #{pane_pid}).
  ;; make-fake-window panes are 20x5 at (0,0), id 1, pid -1.
  ;; Inclusive far-edge: right = 0+20-1 = 19, bottom = 0+5-1 = 4.
  (it "format-context-exposes-structural-pane-variables"
    (with-format-context (sess win pane ctx) ()
      (dolist (c '(("#{pane_width}"  "20") ("#{pane_height}" "5")
                   ("#{pane_id}"     "1")  ("#{pane_left}"   "0")
                   ("#{pane_top}"    "0")  ("#{pane_right}"  "19")
                   ("#{pane_bottom}" "4")  ("#{pane_pid}"    "-1")))
        (destructuring-bind (spec expected) c
          (expect (string= expected (nerimux/format:expand-format spec ctx)))))))

  ;; With a NIL pane, structural pane variables default to 0 (empty-safe).
  (it "format-context-pane-variables-default-when-pane-nil"
    (let ((ctx (nerimux/format:format-context-from-session nil nil nil)))
      (dolist (spec '("#{pane_width}" "#{pane_id}" "#{pane_right}"
                      "#{pane_bottom}" "#{pane_active}"))
        (expect (string= "0" (nerimux/format:expand-format spec ctx))))))

  ;; #{window_bell_flag} shows ! only when monitor-bell is on (default); monitor-bell
  ;; off suppresses the bell alert even with the sticky window bell flag set.
  (it "window-bell-flag-respects-monitor-bell"
    (with-fresh-options
      (let* ((sess (make-fake-session :nwindows 1 :npanes 1))
             (win  (first (nerimux/model:session-windows sess)))
             (pane (first (nerimux/model:window-panes win))))
        (setf (nerimux/model:window-bell-flag win) t)
        (nerimux/options:set-option "monitor-bell" t)
        (expect (string= "!" (nerimux/format:expand-format
                              "#{window_bell_flag}"
                              (nerimux/format:format-context-from-session sess win pane))))
        (nerimux/options:set-option "monitor-bell" nil)
        (expect (not (string= "!" (nerimux/format:expand-format
                                   "#{window_bell_flag}"
                                   (nerimux/format:format-context-from-session sess win pane))))))))

  ;; #{pane_active} is 1 for the window's active pane, 0 otherwise — and drives
  ;; the #{?pane_active,t,f} conditional, the common real-world usage.
  (it "format-context-pane-active-distinguishes-active-pane"
    (let* ((sess       (make-fake-session :nwindows 1 :npanes 2))
           (win        (first (nerimux/model:session-windows sess)))
           (panes      (nerimux/model:window-panes win))
           (p-active   (nerimux/model:window-active-pane win))
           (p-inactive (find-if-not (lambda (p) (eq p p-active)) panes)))
      (let ((ctx-a (nerimux/format:format-context-from-session sess win p-active))
            (ctx-i (nerimux/format:format-context-from-session sess win p-inactive)))
        (dolist (c `((,ctx-a "#{pane_active}"            "1"    "active pane → #{pane_active} 1")
                     (,ctx-i "#{pane_active}"            "0"    "inactive pane → #{pane_active} 0")
                     (,ctx-a "#{?pane_active,HERE,away}" "HERE" "conditional picks the true branch")
                     (,ctx-i "#{?pane_active,HERE,away}" "away" "conditional picks the false branch")))
          (destructuring-bind (ctx spec expected desc) c
            (declare (ignore desc))
            (expect (string= expected (nerimux/format:expand-format spec ctx))))))))

  ;; #{window_panes} is the pane count; #{session_windows} is the window count.
  (it "format-context-window-panes-and-session-windows-counts"
    (with-format-context (sess win pane ctx) (:nwindows 3 :npanes 2)
      (expect (string= "2" (nerimux/format:expand-format "#{window_panes}" ctx)))
      (expect (string= "3" (nerimux/format:expand-format "#{session_windows}" ctx)))))

  ;; #{session_count} expands to a non-empty numeric string (server session total,
  ;; minimum 1 in the single-process model).
  (it "format-context-session-count-is-numeric"
    (with-format-context (sess win pane ctx) ()
      (let ((count (nerimux/format:expand-format "#{session_count}" ctx)))
        (expect (plusp (length count)))
        (expect (every #'digit-char-p count))
        (expect (>= (parse-integer count) 1)))))

  ;; #{pane_dead_status}/#{pane_dead_signal}/#{pane_dead_time} expand from the
  ;; pane's death record and are empty for a live pane (tmux empty defaults).
  (it "pane-dead-status-format-vars-table"
    (let* ((sess (make-fake-session :nwindows 1 :npanes 1))
           (win  (first (nerimux/model:session-windows sess)))
           (pane (first (nerimux/model:window-panes win))))
      (flet ((expand (spec)
               (nerimux/format:expand-format
                spec (nerimux/format:format-context-from-session sess win pane))))
        (dolist (spec '("#{pane_dead_status}" "#{pane_dead_signal}" "#{pane_dead_time}"))
          (expect (string= "" (expand spec))))
        (setf (nerimux/model:pane-dead-status pane) 1
              (nerimux/model:pane-dead-time pane) 3927584461)
        (expect (string= "1" (expand "#{pane_dead_status}")))
        (expect (string= "3927584461" (expand "#{pane_dead_time}")))
        (expect (string= "" (expand "#{pane_dead_signal}"))))))

  ;; The terminal-state / selection / key-table format variables added from the
  ;; tmux inventory diff expand from live screen state.
  ;; Each row: (spec expected description) against a fresh fake session.
  (it "format-terminal-state-vars-table"
    (let* ((sess (make-fake-session :nwindows 1 :npanes 1))
           (win  (first (nerimux/model:session-windows sess)))
           (pane (first (nerimux/model:window-panes win)))
           (h    (nerimux/terminal/types:screen-height
                  (nerimux/model:pane-screen pane))))
      (flet ((expand (spec)
               (nerimux/format:expand-format
                spec (nerimux/format:format-context-from-session sess win pane))))
        (dolist (row `(("#{cursor_flag}"         "1"  "cursor visible by default")
                       ("#{insert_flag}"         "0"  "IRM off by default")
                       ("#{wrap_flag}"           "1"  "autowrap on by default")
                       ("#{origin_flag}"         "0"  "origin mode off")
                       ("#{alternate_on}"        "0"  "primary screen")
                       ("#{scroll_region_upper}" "0"  "scroll region top")
                       ("#{scroll_region_lower}" ,(format nil "~D" (1- h))
                                                      "scroll region bottom")
                       ("#{mouse_any_flag}"      "0"  "mouse reporting off")
                       ("#{rectangle_toggle}"    "0"  "rect select off")
                       ("#{client_key_table}"    "root" "root key table at rest")
                       ("#{window_marked_flag}"  "0"  "no marked pane")
                       ("#{pane_last}"           "0"  "no last pane yet")))
          (destructuring-bind (spec expected desc) row
            (declare (ignore desc))
            (expect (string= expected (expand spec)))))
        (expect (plusp (parse-integer (expand "#{session_created}"))))
        (expect (string/= "" (expand "#{session_activity}")))
        ;; A marked pane and copy-mode key table flip their flags.
        (setf (nerimux/model:pane-marked pane) t)
        (expect (string= "1" (expand "#{window_marked_flag}")))
        (nerimux/commands:copy-mode-enter (nerimux/model:pane-screen pane))
        (expect (string= "copy-mode" (expand "#{client_key_table}"))))))

  ;; #{mouse_x}/#{mouse_y} resolve NERIMUX::*CURRENT-MOUSE-EVENT* by name (so the
  ;; format layer stays free of any umbrella package) rather than depending on it
  ;; directly.  That special was only ever bound by the mouse-dispatch pipeline in
  ;; presentation/events, which has been removed with no replacement, so it is now
  ;; permanently unbound in production and both variables always expand to "".
  (it "format-context-mouse-coordinates-empty-outside-dispatch"
    (with-format-context (sess win pane ctx) ()
      (declare (ignore sess win pane))
      (expect (string= "" (nerimux/format:expand-format "#{mouse_x}" ctx)))
      (expect (string= "" (nerimux/format:expand-format "#{mouse_y}" ctx)))))

  ;; #{client_prefix} and #{client_flags} are plain constants in
  ;; format-context-screen.lisp, not lookups.  Both used to resolve a NERIMUX
  ;; special by name: *PREFIX-ACTIVE*, which never existed anywhere in this tree,
  ;; and *CLIENT-FLAGS*, which was only ever written by `refresh-client -f' and
  ;; went with the tmux command table.  Each silently produced the empty answer
  ;; while looking like live wiring -- the same shape as #{mouse_x} above, but
  ;; without that one's explanatory comment or test.  This pins the values so a
  ;; future attempt to make either dynamic has to come with a test.
  (it "format-context-client-prefix-and-flags-are-constant"
    (with-format-context (sess win pane ctx) ()
      (declare (ignore sess win pane))
      (expect (string= "0" (nerimux/format:expand-format "#{client_prefix}" ctx)))
      (expect (string= "" (nerimux/format:expand-format "#{client_flags}" ctx)))))

  ;; Every NERIMUX symbol the format layer resolves by name must still exist.
  ;; See the header comment for why this is scanned rather than listed, and for
  ;; the two variables that rotted before this guard existed.
  (it "format-layer-find-symbol-targets-all-resolve"
    (let ((known-dead '("*CURRENT-MOUSE-EVENT*"))
          (unresolved '())
          (checked 0))
      (dolist (file (%format-source-files))
        (dolist (name (%nerimux-find-symbol-targets (%file-text file)))
          (incf checked)
          (unless (or (member name known-dead :test #'string=)
                      (find-symbol name "NERIMUX"))
            (push (list (file-namestring file) name) unresolved))))
      ;; Non-vacuity: if the scan matched nothing, the loop above asserts nothing.
      (expect (plusp checked))
      (expect (null unresolved)))))
