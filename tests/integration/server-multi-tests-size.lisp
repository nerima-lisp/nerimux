(in-package #:nerimux/test)

(describe "server-multi-suite"


  (it "client-fds-returns-fd-of-every-attached-client"
    (let ((nerimux::*clients*
            (list (nerimux::%make-client-conn :fd 11)
                  (nerimux::%make-client-conn :fd 22)
                  (nerimux::%make-client-conn :fd 33))))
      (expect (equal '(11 22 33) (nerimux::%client-fds)))))

  (it "client-fds-empty-when-no-clients"
    (let ((nerimux::*clients* nil))
      (expect (null (nerimux::%client-fds)))))

  (it "client-size-reduce-applies-fn-across-rows-and-cols"
    (let ((nerimux::*clients*
            (list (nerimux::%make-client-conn :rows 50 :cols 80)
                  (nerimux::%make-client-conn :rows 24 :cols 200)
                  (nerimux::%make-client-conn :rows 40 :cols 120))))
      (multiple-value-bind (min-rows min-cols) (nerimux::%client-size-reduce #'min)
        (check-table (list (list min-rows 24  "min reduce → smallest rows")
                           (list min-cols 80  "min reduce → smallest cols"))))
      (multiple-value-bind (max-rows max-cols) (nerimux::%client-size-reduce #'max)
        (check-table (list (list max-rows 50  "max reduce → largest rows")
                           (list max-cols 200 "max reduce → largest cols"))))))


  (it "multi-effective-size-is-smallest-client"
    (let ((nerimux::*clients*
            (list (nerimux::%make-client-conn :rows 50 :cols 200)
                  (nerimux::%make-client-conn :rows 24 :cols 80)
                  (nerimux::%make-client-conn :rows 40 :cols 120))))
      (multiple-value-bind (rows cols) (nerimux::%effective-client-size)
        (check-table (list (list rows 24 "effective rows = smallest client rows")
                           (list cols 80 "effective cols = smallest client cols"))))))

  (it "multi-effective-size-no-clients-falls-back"
    (let ((nerimux::*clients* nil)
          (nerimux::*term-rows* 30)
          (nerimux::*term-cols* 100))
      (multiple-value-bind (rows cols) (nerimux::%effective-client-size)
        (check-table (list (list rows 30 "no clients → rows fallback to *term-rows*")
                           (list cols 100 "no clients → cols fallback to *term-cols*"))))))

  (it "multi-effective-size-smallest-still-wins-with-three-clients"
    (let ((nerimux::*clients*
            (list (nerimux::%make-client-conn :rows 50 :cols 200)
                  (nerimux::%make-client-conn :rows 40 :cols 120)
                  (nerimux::%make-client-conn :rows 24 :cols 80))))
      (multiple-value-bind (rows cols) (nerimux::%effective-client-size)
        (check-table (list (list rows 24 "effective rows = smallest of three clients")
                           (list cols 80 "effective cols = smallest of three clients")))))))
