(in-package #:asdf-user)

(defsystem "nerimux-net"
  :description "INFRASTRUCTURE client/server transport for nerimux: wire protocol, framing, unix sockets"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.3.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  :depends-on (:cl-codec-kit)
  :pathname "src"
  :serial t
  :components ((:file "package")
               (:file "protocol-command")
               (:file "protocol")
               (:file "transport")
               (:file "net"))
  :in-order-to ((test-op (test-op "nerimux-net/test"))))

(defsystem "nerimux-net/test"
  :description "Test suite for nerimux-net"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.3.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  :depends-on ("nerimux-net" :cl-host-kit (:version "cl-weave" "1.3.0"))
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "helpers-fdefinition")
               (:file "helpers-net-protocol")
               (:file "helpers-network-listener")
               (:file "protocol-tests")
               (:file "protocol-tests-b")
               (:file "protocol-binary-layout-tests")
               (:file "protocol-command-payload-tests")
               (:file "protocol-command-malformed-utf8-tests")
               (:file "transport-tests")
               (:file "transport-tests-b"))
  :perform (test-op (op c)
             (declare (ignore op c))
             (let ((*print-circle* t)
                   (filter (uiop:getenv "CL_WEAVE_TEST_FILTER")))
               (unless (uiop:symbol-call
                        :cl-weave '#:run-all
                        :reporter :spec
                        :name-filter (when (and filter (plusp (length filter))) filter)
                        :max-workers 1
                        :pass-with-no-tests nil)
                 (error "nerimux-net test suite failed")))))
