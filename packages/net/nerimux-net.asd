;;; This form comes FIRST, before any other form. ASDF binds *package* to
;;; ASDF-USER only for a file it loads itself; read any other way — a REPL
;;; `load`, an editor evaluating the buffer — the file is read in whatever
;;; package happens to be current, and an unqualified `defsystem` then fails to
;;; read at all. See PACKAGE_STANDARD.md "asd の書き方".
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
  ;; No nerimux dependency at all: this unit speaks bytes on a socket and knows
  ;; nothing about the domain it carries.
  :depends-on (:cl-codec-kit)
  :pathname "src"
  :serial t
  :components ((:file "package")  ; nerimux/protocol, nerimux/transport, nerimux/net
               (:file "protocol-command")  ; wire constants and command payload codec
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
  ;; Only its own unit. nerimux-net depends on nothing, so its test system may
  ;; depend on no other unit's test system either -- which is why
  ;; helpers-fdefinition.lisp below is a copy rather than a shared file.
  ;; cl-host-kit is the fixtures' own dependency, not the unit's: the socket
  ;; fixtures build temporary paths with host-kit:temporary-directory. The unit
  ;; itself speaks only bytes and sockets.
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
  ;; See packages/text/nerimux-text.asd for why this form is repeated per unit
  ;; rather than shared, and why *PRINT-CIRCLE* is load-bearing.
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
