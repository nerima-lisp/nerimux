(in-package #:nerimux/test)

;;;; session group helper tests

(describe "server-suite"

  ;;; -- session group helpers --------------------------------------------------

  ;; %next-group-id returns strictly increasing ids on successive calls.
  (it "next-group-id-monotonically-increases"
    (let ((nerimux::*group-id-counter* 0))
      (let ((id1 (nerimux::%next-group-id))
            (id2 (nerimux::%next-group-id))
            (id3 (nerimux::%next-group-id)))
        (expect (< id1 id2))
        (expect (< id2 id3)))))

  ;; %resolve-group-id allocates a fresh group-id for a session without one.
  (it "resolve-group-id-allocates-for-ungrouped-session"
    (let ((nerimux::*group-id-counter* 0)
          (sess (make-session :id 1 :name "ungrouped" :windows nil)))
      (let ((gid (nerimux::%resolve-group-id sess)))
        (expect (integerp gid))
        (expect (plusp gid))
        (expect (= gid (session-group sess))))))

  ;; %resolve-group-id returns the existing group-id for an already-grouped session.
  (it "resolve-group-id-reuses-existing-id"
    (let ((nerimux::*group-id-counter* 0)
          (sess (make-session :id 1 :name "grouped" :windows nil)))
      (setf (session-group sess) 77)
      (let ((gid (nerimux::%resolve-group-id sess)))
        (expect (= 77 gid)))))

  ;; %link-session-to-group copies existing-session's windows into new-session.
  (it "link-session-to-group-shares-windows"
    (let* ((w1  (make-fake-window 1 "w1"))
           (existing (make-session :id 1 :name "existing" :windows (list w1)))
           (new-sess (make-session :id 2 :name "new"      :windows nil)))
      (session-select-window existing w1)
      (nerimux::%link-session-to-group new-sess existing 42)
      (expect (equal (session-windows existing) (session-windows new-sess)))
      (expect (= 42 (session-group new-sess)))))

  ;; %register-in-group-alist adds a new entry when the group-id is not in the alist.
  (it "register-in-group-alist-creates-new-entry"
    (let ((nerimux::*session-groups* nil)
          (sess (make-session :id 1 :name "s" :windows nil)))
      (nerimux::%register-in-group-alist sess 10)
      (let ((entry (assoc 10 nerimux::*session-groups*)))
        (expect entry :to-be-truthy)
        (expect (member sess (cdr entry)) :to-be-truthy))))

  ;; %register-in-group-alist adds to an existing entry without duplicating it.
  (it "register-in-group-alist-pushes-to-existing"
    (let* ((s1   (make-session :id 1 :name "s1" :windows nil))
           (s2   (make-session :id 2 :name "s2" :windows nil))
           (nerimux::*session-groups* (list (list 10 s1))))
      (nerimux::%register-in-group-alist s2 10)
      (let ((entry (assoc 10 nerimux::*session-groups*)))
        (expect (member s2 (cdr entry)) :to-be-truthy)
        (expect (member s1 (cdr entry)) :to-be-truthy))))

  ;; server-new-session-in-group wires both sessions into the same group.
  (it "server-new-session-in-group-shares-windows"
    (let ((nerimux::*session-groups* nil)
          (nerimux::*group-id-counter* 0))
      (let* ((w1 (make-fake-window 1 "w1"))
             (existing (make-session :id 1 :name "existing" :windows (list w1)))
             (new-sess (make-session :id 2 :name "new-sess" :windows nil)))
        (session-select-window existing w1)
        (server-new-session-in-group new-sess existing)
        (expect (equal (session-windows existing) (session-windows new-sess)))
        (expect (= (session-group existing) (session-group new-sess)))))))
