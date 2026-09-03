(in-package #:nerimux/test/model)

(describe "model-suite"


  (it "suppress-update-environment-is-variable"
    (let ((nerimux/session:*suppress-update-environment* t))
      (expect nerimux/session:*suppress-update-environment* :to-be-truthy))
    (expect (null nerimux/session:*suppress-update-environment*)))

  (it "default-update-environment-is-list-of-strings"
    (let ((val nerimux/session:+default-update-environment+))
      (expect (listp val))
      (expect (plusp (length val)))
      (dolist (item val)
        (expect (stringp item)))))

  (it "update-environment-dynamic-variable-rebindable"
    (let ((orig nerimux/session:*update-environment*))
      (let ((nerimux/session:*update-environment* (list "CUSTOM_VAR")))
        (expect (equal (list "CUSTOM_VAR") nerimux/session:*update-environment*)))
      (expect (equal orig nerimux/session:*update-environment*))))

  (it "get-update-environment-vars-returns-alist"
    (let ((result (get-update-environment-vars)))
      (expect (listp result))
      (dolist (entry result)
        (expect (consp entry))
        (expect (stringp (car entry)))
        (expect (stringp (cdr entry))))))

  (it "get-update-environment-vars-respects-star-update-environment"
    (let ((*update-environment* (list "__NERIMUX_NONEXISTENT_VAR_99999__")))
      (let ((result (get-update-environment-vars)))
        (expect (null result)))))

  (it "get-update-environment-vars-set-variable-included"
    (let ((*update-environment* (list "HOME")))
      (let ((result (get-update-environment-vars)))
        (when (sb-ext:posix-getenv "HOME")
          (expect (= 1 (length result)))
          (expect (string= "HOME" (caar result)))
          (expect (stringp (cdar result)))))))


  (it "session-environment-hash-table-by-default"
    (let ((sess (make-session :id 1 :name "s")))
      (expect (hash-table-p (session-environment sess)))))

  (it "session-environment-names-returns-list"
    (let ((sess (make-session :id 1 :name "s")))
      (expect (listp (session-environment-names sess)))))

  (it "session-set-and-get-environment"
    (let ((sess (make-session :id 1 :name "s")))
      (session-set-environment sess "MYVAR" "myval")
      (multiple-value-bind (value source)
          (session-environment-value sess "MYVAR")
        (expect (string= "myval" value))
        (expect (eq :session source)))))

  (it "session-unset-environment-hides-variable"
    (let ((sess (make-session :id 1 :name "s")))
      (session-unset-environment sess "NOSUCHENV_XYZ")
      (multiple-value-bind (value source)
          (session-environment-value sess "NOSUCHENV_XYZ")
        (expect (null value))
        (expect (eq :unset source)))))

  (it "session-environment-value-table"
    (dolist (row '(("NERIMUX_TEST_SESSION_ENV_A" :none  "from-process"  :process "absent overlay must inherit process value")
                   ("NERIMUX_TEST_SESSION_ENV_B" :set   "from-overlay"  :session "overlay must shadow process value")
                   ("NERIMUX_TEST_SESSION_ENV_C" :unset nil             :unset   "explicit unset must hide process value")))
      (destructuring-bind (name-str action expected-val expected-src desc) row
        (declare (ignore desc))
        (with-session-and-env-var (sess name name-str "from-process")
          (ecase action
            (:none  nil)
            (:set   (session-set-environment sess name "from-overlay"))
            (:unset (session-unset-environment sess name)))
          (multiple-value-bind (value source) (session-environment-value sess name)
            (expect (equal expected-val value))
            (expect (eq expected-src source)))))))


  (it "session-child-environment-returns-list"
    (let ((sess (make-session :id 1 :name "s")))
      (let ((env (session-child-environment sess)))
        (expect (listp env))
        (dolist (entry env)
          (expect (stringp entry))
          (expect (position #\= entry))))))

  (it "session-child-environment-applies-term-override"
    (let* ((sess (make-session :id 1 :name "s"))
           (env  (session-child-environment sess
                                            :term "xterm-256color"
                                            :extra-env '(("NERIMUX_TEST" . "1")))))
      (expect (member "TERM=xterm-256color" env :test #'string=) :to-be-truthy)
      (expect (member "NERIMUX_TEST=1" env :test #'string=) :to-be-truthy)))


  (it "environment-entry-name-and-value-table"
    (dolist (row '(("FOO=bar"    "FOO" "bar" "simple pair")
                   ("A=B=C"      "A"   "B=C" "value itself may contain '='")
                   ("EMPTY="     "EMPTY" ""   "empty value after '='")
                   ("NOEQUALS"   nil   nil   "no '=' yields NIL for both")))
      (destructuring-bind (entry expected-name expected-value desc) row
        (declare (ignore desc))
        (expect (equal expected-name  (nerimux/session::%environment-entry-name  entry)))
        (expect (equal expected-value (nerimux/session::%environment-entry-value entry))))))

  (it "environment-strings-to-table-and-back"
    (let* ((entries '("B=2" "A=1" "C=3"))
           (table   (nerimux/session::%environment-strings-to-table entries)))
      (expect (hash-table-p table))
      (expect (string= "1" (gethash "A" table)))
      (expect (string= "2" (gethash "B" table)))
      (expect (string= "3" (gethash "C" table)))
      (expect (equal '("A=1" "B=2" "C=3")
                 (nerimux/session::%environment-table-to-list table)))))

  (it "environment-strings-to-table-skips-entries-without-equals"
    (let ((table (nerimux/session::%environment-strings-to-table '("GOOD=1" "BADENTRY"))))
      (expect (= 1 (hash-table-count table)))
      (expect (string= "1" (gethash "GOOD" table)))))

  (it "assert-environment-variable-name-accepts-valid-names"
    (dolist (name '("HOME" "PATH" "MY_VAR_1"))
      (finishes (nerimux/session::%assert-environment-variable-name name))))

  (it "assert-environment-variable-name-rejects-invalid-names"
    (dolist (bad (list nil "" "HAS=EQUALS" 42))
      (signals error (nerimux/session::%assert-environment-variable-name bad))))


  (it "process-environment-value-reads-live-process-environment"
    (with-process-env-var (name "NERIMUX_TEST_PROC_ENV_VAL" "hello")
      (expect (string= "hello" (nerimux/session:process-environment-value "NERIMUX_TEST_PROC_ENV_VAL"))))
    (expect (null (nerimux/session:process-environment-value "__NERIMUX_DEFINITELY_UNSET_VAR__"))))

  (it "process-environment-names-includes-known-set-variable"
    (with-process-env-var (name "NERIMUX_TEST_PROC_ENV_NAMES" "x")
      (let ((names (nerimux/session:process-environment-names)))
        (expect (listp names))
        (expect (member "NERIMUX_TEST_PROC_ENV_NAMES" names :test #'string=) :to-be-truthy)
        (expect (equal (sort (copy-list names) #'string<) names)))))

  (it "process-set-environment-writes-and-returns-value"
    (with-process-env-var (name "NERIMUX_TEST_PROC_SET_ENV" nil)
      (let ((result (nerimux/session:process-set-environment
                     "NERIMUX_TEST_PROC_SET_ENV" "written-value")))
        (expect (string= "written-value" result))
        (expect (string= "written-value"
                     (nerimux/session:process-environment-value "NERIMUX_TEST_PROC_SET_ENV"))))))

  (it "process-unset-environment-removes-value-and-returns-name"
    (with-process-env-var (name "NERIMUX_TEST_PROC_UNSET_ENV" "present")
      (let ((result (nerimux/session:process-unset-environment "NERIMUX_TEST_PROC_UNSET_ENV")))
        (expect (string= "NERIMUX_TEST_PROC_UNSET_ENV" result))
        (expect (null (nerimux/session:process-environment-value "NERIMUX_TEST_PROC_UNSET_ENV"))))))


  (it "apply-session-overlay-merges-set-and-removes-unset"
    (let ((table (make-hash-table :test #'equal))
          (sess  (make-session :id 1 :name "s")))
      (setf (gethash "KEEP" table) "process-value"
            (gethash "REMOVE" table) "process-value")
      (session-set-environment sess "KEEP" "overlay-value")
      (session-unset-environment sess "REMOVE")
      (nerimux/session::%apply-session-overlay sess table)
      (expect (string= "overlay-value" (gethash "KEEP" table)))
      (expect (null (gethash "REMOVE" table)))))

  (it "apply-session-overlay-nil-session-is-noop"
    (let ((table (make-hash-table :test #'equal)))
      (setf (gethash "UNTOUCHED" table) "value")
      (finishes (nerimux/session::%apply-session-overlay nil table))
      (expect (string= "value" (gethash "UNTOUCHED" table)))))


  (it "apply-extra-env-merges-valid-pairs"
    (let ((table (make-hash-table :test #'equal)))
      (nerimux/session::%apply-extra-env '(("A" . "1") ("B" . "2")) table)
      (expect (string= "1" (gethash "A" table)))
      (expect (string= "2" (gethash "B" table)))))

  (it "apply-extra-env-skips-malformed-pairs"
    (let ((table (make-hash-table :test #'equal)))
      (nerimux/session::%apply-extra-env (list '("OK" . "yes") 42 '(1 . 2) '("BAD" . 7)) table)
      (expect (= 1 (hash-table-count table)))
      (expect (string= "yes" (gethash "OK" table))))))
