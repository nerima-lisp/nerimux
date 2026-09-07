(in-package #:nerimux/test)

(describe "target-edge-cases-suite"

  (it "sigil-id-table"
    (dolist (row '(("$1"   #\$  1   "dollar single-digit")
                   ("$42"  #\$  42  "dollar multi-digit")
                   ("@3"   #\@  3   "at-sign")
                   ("%7"   #\%  7   "percent-sign")
                   ("$5"   #\@  nil "wrong sigil")
                   ("main" #\$  nil "non-sigil string")
                   (""     #\$  nil "empty string")))
      (destructuring-bind (input sigil expected desc) row
        (declare (ignore desc))
        (expect (equal expected (nerimux::%sigil-id input sigil))))))


  (it "name-prefix-p-table"
    (dolist (row '((t   "foo"    "foo"     "exact match")
                   (t   "fo"     "foobar"  "prefix of longer name")
                   (nil "foobar" "fo"      "prefix longer than name")
                   (nil "bar"    "foobar"  "strings diverge")
                   (t   ""       "anything" "empty prefix matches anything")))
      (destructuring-bind (expected prefix name desc) row
        (declare (ignore desc))
        (expect (eq expected (nerimux::%name-prefix-p prefix name))))))


  (it "find-session-by-target-empty-registry-returns-nil"
    (expect (null (nerimux::find-session-by-target nil "alpha"))))


  (it "find-window-by-target-empty-windows-returns-nil"
    (let ((sess (make-session :id 1 :name "s" :windows nil)))
      (expect (null (nerimux::find-window-by-target sess "any")))))

  (it "find-window-by-target-index-out-of-range-returns-nil"
    (let* ((w1   (make-window :id 1 :name "w1" :width 80 :height 24))
           (sess (make-session :id 1 :name "s" :windows (list w1))))
      (expect (null (nerimux::find-window-by-target sess "5")))
      (expect (null (nerimux::find-window-by-target sess "-1")))
      (expect (null (nerimux::find-window-by-target sess "not-an-index")))))


  (it "find-pane-by-target-empty-panes-returns-nil"
    (let ((win (make-window :id 1 :name "w" :width 80 :height 24 :panes nil)))
      (expect (null (nerimux::find-pane-by-target win "%1")))))

  (it "find-pane-by-target-index-out-of-range-returns-nil"
    (let* ((p1  (make-no-pty-pane 1 0 0 80 24))
           (win (make-window :id 1 :name "w" :width 80 :height 24
                             :panes (list p1))))
      (expect (null (nerimux::find-pane-by-target win "10")))
      (expect (null (nerimux::find-pane-by-target win "-1")))
      (expect (null (nerimux::find-pane-by-target win "not-an-index")))))


  (it "find-session-by-target-multi-digit-id"
    (let* ((sess (make-session :id 42 :name "big" :windows nil))
           (registry (list (cons "big" sess))))
      (expect (eq sess (nerimux::find-session-by-target registry "$42")))))


  (it "find-window-by-target-multi-digit-at-id"
    (let* ((w1   (make-window :id 99 :name "bigwin" :width 80 :height 24))
           (sess (make-session :id 1 :name "s" :windows (list w1))))
      (expect (eq w1 (nerimux::find-window-by-target sess "@99")))))


  (it "find-pane-by-target-multi-digit-percent-id"
    (let* ((p1  (make-no-pty-pane 15 0 0 80 24))
           (win (make-window :id 1 :name "w" :width 80 :height 24
                             :panes (list p1))))
      (expect (eq p1 (nerimux::find-pane-by-target win "%15")))))

  (it "sigil-id-rejects-invalid-integer"
    (expect (null (nerimux::%sigil-id "$not-an-id" #\$))))

  (it "define-target-lookup-supports-docstrings-and-nil-guards"
    (let ((name (gensym "TARGET-LOOKUP-")))
      (unwind-protect
           (progn
             (eval `(nerimux::define-target-lookup ,name (value)
                      "Lookup used to verify the macro contract."
                      (:nil-guard value)
                      ((and (eql value :hit) :matched))))
             (expect (null (funcall name nil)))
             (expect (eq :matched (funcall name :hit)))
             (expect (null (funcall name :miss))))
        (when (fboundp name)
          (fmakunbound name)))))

  (it "define-target-lookup-supports-rules-without-a-docstring"
    (let ((name (gensym "TARGET-LOOKUP-")))
      (unwind-protect
           (progn
             (eval `(nerimux::define-target-lookup ,name (value)
                      ((when (eql value :hit) :matched))))
             (expect (eq :matched (funcall name :hit)))
             (expect (null (funcall name :miss))))
        (when (fboundp name)
          (fmakunbound name))))))
