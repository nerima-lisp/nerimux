(in-package #:nerimux/test)

;;;; Tests for src/target.lisp — session/window/pane target resolution.
;;;;
;;;; Tests: target-suite — %parse-target, find-session-by-target,
;;;; find-window-by-target, find-pane-by-target.

(describe "target-suite"

  ;;; ── %parse-session-component direct tests ───────────────────────────────────
  ;;;
  ;;; %parse-session-component has non-trivial logic for the colon/dot cases.
  ;;; Testing it directly gives coverage independent of %parse-target's full path.

  ;; %parse-session-component extracts text before the colon or dot, returning NIL for empty.
  (it "parse-session-component-table"
    (dolist (c '(("sess:win"   4   nil "sess"      "text before colon")
                 ("sess.2"     nil 4   "sess"      "text before dot (no colon)")
                 ("mysession"  nil nil "mysession" "whole string (no colon or dot)")
                 (":win"       0   nil nil         "NIL when empty before colon")
                 (""           nil nil nil         "NIL for empty string")))
      (destructuring-bind (input colon-pos dot-pos expected desc) c
        (declare (ignore desc))
        (expect (equal expected (nerimux::%parse-session-component input colon-pos dot-pos))))))

  ;;; ── %parse-target ────────────────────────────────────────────────────────────

  ;; %parse-target with NIL or empty string returns (nil nil nil) for all three components.
  (it "parse-target-nil-and-empty-return-all-nil"
    (dolist (input '(nil ""))
      (multiple-value-bind (s w p) (nerimux::%parse-target input)
        (expect (null s))
        (expect (null w))
        (expect (null p)))))

  ;; %parse-target decomposes target strings into (session window pane) components.
  (it "parse-target-table"
    (dolist (c '(("mysession"  "mysession" nil   nil   "plain name → session only")
                 ("sess:win"   "sess"      "win" nil   "sess:win → session+window")
                 ("sess:win.3" "sess"      "win" "3"   "sess:win.pane → all three")
                 ("sess.2"     "sess"      nil   "2"   "sess.N (no colon) → session+pane")
                 (":win"       nil         "win" nil   ":win → window only")
                 ("$1:@2.%3"  "$1"        "@2"  "%3"  "sigil forms → session+window+pane")
                 ("%2"         nil         nil   "%2"  "bare %N → pane id")
                 ("@3"         nil         "@3"  nil   "bare @N → window id")
                 ("$1"         "$1"        nil   nil   "bare $N → session id")
                 ("work"       "work"      nil   nil   "plain name stays session")))
      (destructuring-bind (input expected-s expected-w expected-p desc) c
        (declare (ignore desc))
        (multiple-value-bind (s w p) (nerimux::%parse-target input)
          (expect (equal expected-s s))
          (expect (equal expected-w w))
          (expect (equal expected-p p))))))

  ;;; ── find-session-by-target ───────────────────────────────────────────────────

  ;; find-session-by-target returns NIL when target-str is NIL.
  (it "find-session-by-target-nil-target-returns-nil"
    (let ((sess (make-session :id 1 :name "main" :windows nil)))
      (expect (null (nerimux::find-session-by-target
                 (list (cons "main" sess)) nil)))))

  ;; find-session-by-target finds a session by exact name match.
  (it "find-session-by-target-exact-name"
    (let* ((s1 (make-session :id 1 :name "alpha" :windows nil))
           (s2 (make-session :id 2 :name "beta"  :windows nil))
           (registry (list (cons "alpha" s1) (cons "beta" s2))))
      (expect (eq s1 (nerimux::find-session-by-target registry "alpha")))
      (expect (eq s2 (nerimux::find-session-by-target registry "beta")))))

  ;; find-session-by-target matches $N by session-id.
  (it "find-session-by-target-dollar-id"
    (let* ((s1 (make-session :id 1 :name "first"  :windows nil))
           (s2 (make-session :id 2 :name "second" :windows nil))
           (registry (list (cons "first" s1) (cons "second" s2))))
      (expect (eq s1 (nerimux::find-session-by-target registry "$1")))
      (expect (eq s2 (nerimux::find-session-by-target registry "$2")))))

  ;; find-session-by-target matches by name prefix when no exact match.
  (it "find-session-by-target-prefix-match"
    (let* ((s1 (make-session :id 1 :name "longname" :windows nil))
           (registry (list (cons "longname" s1))))
      (expect (eq s1 (nerimux::find-session-by-target registry "long")))))

  ;; find-session-by-target returns NIL when no session matches.
  (it "find-session-by-target-no-match-returns-nil"
    (let* ((s1 (make-session :id 1 :name "alpha" :windows nil))
           (registry (list (cons "alpha" s1))))
      (expect (null (nerimux::find-session-by-target registry "beta")))))

  ;;; ── find-window-by-target ────────────────────────────────────────────────────

  ;; find-window-by-target returns NIL when session or target is NIL.
  (it "find-window-by-target-nil-inputs-return-nil"
    (let* ((w1 (make-window :id 1 :name "w1" :width 80 :height 24))
           (sess (make-session :id 1 :name "s" :windows (list w1))))
      (expect (null (nerimux::find-window-by-target nil "w1")))
      (expect (null (nerimux::find-window-by-target sess nil)))))

  ;; find-window-by-target finds by exact window name.
  (it "find-window-by-target-exact-name"
    (let* ((w1 (make-window :id 1 :name "editor" :width 80 :height 24))
           (w2 (make-window :id 2 :name "shell"  :width 80 :height 24))
           (sess (make-session :id 1 :name "s" :windows (list w1 w2))))
      (expect (eq w1 (nerimux::find-window-by-target sess "editor")))
      (expect (eq w2 (nerimux::find-window-by-target sess "shell")))))

  ;; find-window-by-target finds by @N notation.
  (it "find-window-by-target-at-id"
    (let* ((w1 (make-window :id 1 :name "win1" :width 80 :height 24))
           (w2 (make-window :id 2 :name "win2" :width 80 :height 24))
           (sess (make-session :id 1 :name "s" :windows (list w1 w2))))
      (expect (eq w1 (nerimux::find-window-by-target sess "@1")))
      (expect (eq w2 (nerimux::find-window-by-target sess "@2")))))

  ;; find-window-by-target finds by 0-based numeric index.
  (it "find-window-by-target-numeric-index"
    (let* ((w1 (make-window :id 1 :name "win1" :width 80 :height 24))
           (w2 (make-window :id 2 :name "win2" :width 80 :height 24))
           (sess (make-session :id 1 :name "s" :windows (list w1 w2))))
      (expect (eq w1 (nerimux::find-window-by-target sess "0")))
      (expect (eq w2 (nerimux::find-window-by-target sess "1")))))

  ;; find-window-by-target falls back to name prefix.
  (it "find-window-by-target-prefix-match"
    (let* ((w1 (make-window :id 1 :name "editwin" :width 80 :height 24))
           (sess (make-session :id 1 :name "s" :windows (list w1))))
      (expect (eq w1 (nerimux::find-window-by-target sess "edit")))))

  ;; find-window-by-target returns NIL when no window matches.
  (it "find-window-by-target-no-match-returns-nil"
    (let* ((w1 (make-window :id 1 :name "alpha" :width 80 :height 24))
           (sess (make-session :id 1 :name "s" :windows (list w1))))
      (expect (null (nerimux::find-window-by-target sess "beta")))))

  ;;; ── find-pane-by-target ──────────────────────────────────────────────────────

  ;; find-pane-by-target returns NIL when window or target is NIL.
  (it "find-pane-by-target-nil-inputs-return-nil"
    (let* ((p1  (make-no-pty-pane 1 0 0 40 24))
           (win (make-window :id 1 :name "w" :width 80 :height 24
                             :panes (list p1))))
      (expect (null (nerimux::find-pane-by-target nil "%1")))
      (expect (null (nerimux::find-pane-by-target win nil)))))

  ;; find-pane-by-target finds by %N notation.
  (it "find-pane-by-target-percent-id"
    (let* ((p1  (make-no-pty-pane 1  0 0 40 24))
           (p2  (make-no-pty-pane 2 41 0 40 24))
           (win (make-window :id 1 :name "w" :width 81 :height 24
                             :panes (list p1 p2))))
      (expect (eq p1 (nerimux::find-pane-by-target win "%1")))
      (expect (eq p2 (nerimux::find-pane-by-target win "%2")))))

  ;; find-pane-by-target finds by 0-based numeric index.
  (it "find-pane-by-target-numeric-index"
    (let* ((p1  (make-no-pty-pane 1  0 0 40 24))
           (p2  (make-no-pty-pane 2 41 0 40 24))
           (win (make-window :id 1 :name "w" :width 81 :height 24
                             :panes (list p1 p2))))
      (expect (eq p1 (nerimux::find-pane-by-target win "0")))
      (expect (eq p2 (nerimux::find-pane-by-target win "1")))))

  ;; find-pane-by-target returns NIL when pane id does not exist.
  (it "find-pane-by-target-no-match-returns-nil"
    (let* ((p1  (make-no-pty-pane 1 0 0 80 24))
           (win (make-window :id 1 :name "w" :width 80 :height 24
                             :panes (list p1))))
      (expect (null (nerimux::find-pane-by-target win "%99")))
      (expect (null (nerimux::find-pane-by-target win "5"))))))
