(in-package #:nerimux/test/model)

(defun %two-pane-session ()
  "Session with one window containing two fake panes side-by-side."
  (let* ((p0 (make-no-pty-pane 1 0 0 40 24))
         (p1 (make-no-pty-pane 2 41 0 40 24))
         (win
          (make-window :id
                       1
                       :name
                       "w"
                       :width
                       81
                       :height
                       24
                       :panes
                       (list p0 p1)
                       :tree
                       (make-layout-split :h
                                          (make-layout-leaf p0)
                                          (make-layout-leaf p1)
                                          1/2)))
         (sess (make-session :id 1 :name "0" :windows (list win))))
    (window-select-pane win p0)
    (session-select-window sess win)
    (values sess win p0 p1)))

(describe "advanced-suite"



  (it "layout-to-string-not-nil-for-window-with-tree"
    (multiple-value-bind (sess win p0 p1) (%two-pane-session)
      (declare (ignore sess p0 p1))
      (let ((str (nerimux/layout:layout->string win)))
        (expect str :to-be-truthy)
        (expect (stringp str))
        (expect (plusp (length str))))))

  (it "layout-to-string-nil-for-empty-window"
    (let ((win (make-window :id 1 :name "w" :width 80 :height 24
                            :tree nil)))
      (expect (null (nerimux/layout:layout->string win)))))

  (it "layout-checksum-4-hex-chars"
    (multiple-value-bind (_sess win p0 p1) (%two-pane-session)
      (declare (ignore _sess p0 p1))
      (let* ((str     (nerimux/layout:layout->string win))
             (comma   (position #\, str))
             (csum    (and comma (subseq str 0 comma))))
        (expect (and csum (= 4 (length csum))))
        (expect (every (lambda (ch) (or (digit-char-p ch) (find ch "ABCDEFabcdef")))
                       (or csum ""))))))


  (it "update-environment-default-list"
    (let ((vars nerimux/session:*update-environment*))
      (expect (listp vars))
      (expect (> (length vars) 0))
      (expect (every #'stringp vars)))))
