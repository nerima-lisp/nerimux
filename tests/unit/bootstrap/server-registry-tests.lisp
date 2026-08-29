(in-package #:nerimux/test)

;;;; Session registry and lookup behavior.

(describe "server-suite"

  ;; server-add-session registers a session; server-find-session retrieves it.
  (it "server-add-and-find-session"
    (with-empty-registry
      (let ((sess (make-session :id 1 :name "alpha" :windows nil)))
        (nerimux::server-add-session sess)
        (let ((found (nerimux::server-find-session "alpha")))
          (expect (eq sess found))))))

  ;; server-find-session returns NIL for an unknown name, NIL, or an empty string.
  (it "server-find-session-nil-inputs-table"
    (dolist (row '(("no-such-session" "unknown name -> nil")
                   (nil               "nil input -> nil")
                   (""                "empty string -> nil")))
      (destructuring-bind (input desc) row
        (declare (ignore desc))
        (with-empty-registry
          (expect (null (nerimux::server-find-session input)))))))

  ;; Adding a session whose name already exists replaces the old one.
  (it "server-add-session-replaces-existing-name"
    (with-empty-registry
      (let ((s1 (make-session :id 1 :name "same" :windows nil))
            (s2 (make-session :id 2 :name "same" :windows nil)))
        (nerimux::server-add-session s1)
        (nerimux::server-add-session s2)
        (expect (eq s2 (nerimux::server-find-session "same"))))))

  ;; server-find-session with a name prefix 'my' finds the session named 'mysession'.
  (it "server-find-session-fuzzy"
    (with-empty-registry
      (let ((sess (make-session :id 1 :name "mysession" :windows nil)))
        (nerimux::server-add-session sess)
        (let ((found (nerimux::server-find-session "my")))
          (expect (eq sess found))))))

  ;; server-find-session '$N' matches by id when present; returns NIL when absent.
  ;; Each row: (session-id query expect-found description).
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
