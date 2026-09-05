(in-package #:nerimux/test/model)

(defun make-fake-window (id name &key (npanes 1))
  "A window with NPANES fake panes (fd -1) and a matching tree; the first pane is active.
   Sets :active directly in make-window rather than calling window-select-pane to
   avoid stamping window-last-active-time during construction; that timestamp is a
   session-level concept updated only by session-select-window."
  (let* ((panes
          (loop for i below npanes
                collect (make-no-pty-pane (1+ i) 0 0 20 5)))
         (tree (%fake-window-tree panes)))
    (let ((win
           (make-window :id
                        id
                        :name
                        name
                        :width
                        20
                        :height
                        5
                        :panes
                        panes
                        :tree
                        tree
                        :active
                        (first panes))))
      (dolist (p panes)
        (setf (nerimux/pane:pane-window p) win))
      win)))

(defun %fake-window-tree (panes)
  "Build the left-spine layout tree used by fake-window fixtures."
  (if (null (rest panes))
      (make-layout-leaf (first panes))
      (make-layout-split :h
                         (make-layout-leaf (first panes))
                         (%fake-window-tree (rest panes))
                         1/2)))

(defun make-fake-session (&key (nwindows 1) (npanes 1))
  "A session of NWINDOWS fake windows (each with NPANES fake panes), no PTYs.
   Window ids start at 0 (base-index), matching the real session-new-window behaviour."
  (let* ((windows
          (loop for i below nwindows
                collect (make-fake-window i (format nil "~D" i) :npanes npanes)))
         (sess (make-session :id 1 :name "0" :windows windows)))
    (session-select-window sess (first windows))
    sess))

(defun make-single-pane-session (&key (session-name "s")
                                      (window-name "w")
                                      (width 80)
                                      (height 24)
                                      (session-id 1)
                                      (window-id 1)
                                      (pane-id 1))
  "Build and return a minimal (session window pane) triple.
   The pane is no-PTY (fd = -1, pid = -1) sized WIDTH x HEIGHT.
   The window wraps the pane in a leaf tree, with the pane as active.
   The session holds the window as its sole entry and active window.
   Returns (values session window pane).
   Callers that only need the session can ignore the extra values."
  (let* ((pane
          (make-pane :id
                     pane-id
                     :x
                     0
                     :y
                     0
                     :width
                     width
                     :height
                     height
                     :fd
                     -1
                     :pid
                     -1
                     :screen
                     (make-screen width height)))
         (win
          (make-window :id
                       window-id
                       :name
                       window-name
                       :width
                       width
                       :height
                       height
                       :panes
                       (list pane)
                       :tree
                       (make-layout-leaf pane)
                       :active
                       pane))
         (sess
          (make-session :id
                        session-id
                        :name
                        session-name
                        :windows
                        (list win)
                        :active
                        win)))
    (setf (pane-window pane) win)
    (window-select-pane win pane)
    (session-select-window sess win)
    (values sess win pane)))
