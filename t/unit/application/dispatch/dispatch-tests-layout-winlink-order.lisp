(in-package #:nerimux/test)

;;;; Layout undo and per-session winlink ordering dispatch cases.

(describe "dispatch-suite"

  ;; select-layout -o restores the layout tree saved before the last layout
  ;; application; a second -o redoes (swap semantics).
  (it "select-layout-o-undoes-last-layout-change"
    (with-two-pane-h-session (s win p0 p1)
      (with-command-test-state (s :overlay t)
        (let ((before-tree (nerimux/model:window-tree win)))
          (nerimux::%run-command-line s "select-layout even-vertical")
          (let ((after-tree (nerimux/model:window-tree win)))
            (expect (not (eq before-tree after-tree)))
            (nerimux::%run-command-line s "select-layout -o")
            (expect (eq before-tree (nerimux/model:window-tree win)))
            (nerimux::%run-command-line s "select-layout -o")
            (expect (eq after-tree (nerimux/model:window-tree win))))))))

  ;; link-window -t sess:N links a window at index N in the destination while
  ;; the source session keeps the window's own index; target resolution and
  ;; #{window_index} follow the per-session winlink index.
  (it "link-window-per-session-winlink-index"
    (with-fake-session (a)
      (with-fake-session (b)
        (setf (nerimux/model:session-name a) "wla"
              (nerimux/model:session-name b) "wlb")
        (let ((win (nerimux/model:session-active-window a))
              (nerimux::*server-sessions* nil))
          (push (cons "wla" a) nerimux::*server-sessions*)
          (push (cons "wlb" b) nerimux::*server-sessions*)
          (let ((*overlay* nil))
            (nerimux::%cmd-link-window a '("-t" "wlb:7")))
          (expect (member win (nerimux/model:session-windows b)))
          (expect (= 7 (nerimux/model:session-window-index b win)))
          (expect (= (nerimux/model:window-id win)
                     (nerimux/model:session-window-index a win)))
          (expect (eq win (nerimux::%resolve-window-target b "7")))
          (expect (string= "7" (nerimux/format:expand-format
                                "#{window_index}"
                                (nerimux/format:format-context-from-session b win nil))))
          ;; Unlinking prunes the override so a later re-link starts clean.
          (setf (nerimux/model:session-windows b)
                (remove win (nerimux/model:session-windows b)))
          (nerimux/model:session-windows-changed b)
          (expect (zerop (hash-table-count (nerimux/model:session-window-index-map b))))))))

  ;; Window display order (status bar / list-windows) follows the per-session
  ;; winlink indexes: a window linked at a high index sorts after lower ones,
  ;; while sessions without overrides keep id order.
  (it "status-window-order-follows-winlink-indexes"
    (with-fake-session (s :nwindows 2)
      (let* ((wins (nerimux/model:session-windows s))
             (w0 (first wins))
             (w1 (second wins)))
        (expect (equal (list w0 w1)
                       (nerimux/model:session-windows-in-index-order s)))
        ;; Give the FIRST window a high per-session index: it must sort last.
        (nerimux/model:set-session-window-index s w0 99)
        (expect (equal (list w1 w0)
                       (nerimux/model:session-windows-in-index-order s)))))))
