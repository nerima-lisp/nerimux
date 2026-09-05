(in-package #:nerimux/test)

(describe "server-suite"

  (it "server-add-and-find-session"
    (with-empty-registry
      (let ((sess (make-session :id 1 :name "alpha" :windows nil)))
        (nerimux::server-add-session sess)
        (let ((found (nerimux::server-find-session "alpha")))
          (expect (eq sess found))))))

  (it "server-find-session-nil-inputs-table"
    (dolist (row '(("no-such-session" "unknown name -> nil")
                   (nil               "nil input -> nil")
                   (""                "empty string -> nil")))
      (destructuring-bind (input desc) row
        (declare (ignore desc))
        (with-empty-registry
          (expect (null (nerimux::server-find-session input)))))))

  (it "server-add-session-replaces-existing-name"
    (with-empty-registry
      (let ((s1 (make-session :id 1 :name "same" :windows nil))
            (s2 (make-session :id 2 :name "same" :windows nil)))
        (nerimux::server-add-session s1)
        (nerimux::server-add-session s2)
        (expect (eq s2 (nerimux::server-find-session "same"))))))

  (it "server-find-session-fuzzy"
    (with-empty-registry
      (let ((sess (make-session :id 1 :name "mysession" :windows nil)))
        (nerimux::server-add-session sess)
        (let ((found (nerimux::server-find-session "my")))
          (expect (eq sess found))))))

  (it "server-find-session-by-id-table"
    (dolist (row '((42 "$42"  t   "$42 should find the session with id 42")
                   (1  "$999" nil "$999 must return NIL when no session has id 999")))
      (destructuring-bind (id query expect-found desc) row
        (declare (ignore desc))
        (with-empty-registry
          (let ((sess (make-session :id id :name "s" :windows nil)))
            (nerimux::server-add-session sess)
            (let ((found (nerimux::server-find-session query)))
              (if expect-found
                  (expect (eq sess found))
                  (expect (null found))))))))))
