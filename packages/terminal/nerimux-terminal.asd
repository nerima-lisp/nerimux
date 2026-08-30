;;; This form comes FIRST, before any other form. ASDF binds *package* to
;;; ASDF-USER only for a file it loads itself; read any other way — a REPL
;;; `load`, an editor evaluating the buffer — the file is read in whatever
;;; package happens to be current, and an unqualified `defsystem` then fails to
;;; read at all. See PACKAGE_STANDARD.md "asd の書き方".
(in-package #:asdf-user)

(defsystem "nerimux-terminal"
  :description "DOMAIN terminal emulator for nerimux: screen, parser, CSI/OSC/SGR, character writing"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.3.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  ;; parser-osc-color calls nerimux/text:parse-integer-or-nil; csi-replies calls
  ;; nerimux/version:version-string for the XTVERSION reply.
  :depends-on ("nerimux-text" "nerimux-version"
               :cl-codec-kit :cl-host-kit :cl-concurrent-kit :cl-tty-kit :cl-regex-kit)
  :pathname "src"
  ;; The file order below is load-bearing and was carried over verbatim from
  ;; nerimux.asd's domain/terminal module: scroll before cursor/erase/edit,
  ;; each -definitions table before the file that composes it, and the CSI rule
  ;; sets before csi-compose folds them into EXECUTE-CSI.
  :serial t
  :components (
               (:file "package-types")
               (:file "package")
               (:file "cell")
               (:file "screen-data")
               (:file "screen")
               (:file "screen-metadata")
               (:file "screen-resize")
               (:file "screen-logic")
               (:file "scroll")
               (:file "erase")
               (:file "edit")
               (:file "cursor")
               (:file "char-write-definitions")
               (:file "char-write-cells")
               (:file "char-write")
               (:file "modes-alt-screen")
               (:file "modes-dec-pm-definitions")
               (:file "modes-cursor-save")
               (:file "modes-reset")
               (:file "modes-charset-definitions")
               (:file "modes-charset")
               (:file "modes-ansi-sm-rm-definitions")
               (:file "screen-projection")
               (:file "screen-osc-state")
               (:file "sgr-definitions")
               (:file "sgr-colors")
               (:file "sgr")
               (:file "sgr-report")
               (:file "csi-replies-definitions")
               (:file "csi-replies")
               (:file "csi-parameters")
               (:file "csi-dispatch")
               (:file "csi")
               (:file "csi-device-rules")
               (:file "csi-extended-rules")
               (:file "csi-compose")
               (:file "parser-dcs")
               (:file "parser-core")
               (:file "parser-csi")
               (:file "parser-utf8")
               (:file "parser")
               (:file "parser-osc-clipboard")
               (:file "parser-osc-uri")
               (:file "parser-osc-color")
               (:file "parser-osc-dispatch")
               (:file "parser-osc")
               (:file "emulator")               )
  :in-order-to ((test-op (test-op "nerimux-terminal/test"))))

(defsystem "nerimux-terminal/test"
  :description "Test suite for nerimux-terminal"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.3.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  :depends-on ("nerimux-terminal" :cl-host-kit (:version "cl-weave" "1.3.0"))
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "helpers-terminal-builders")
               (:file "helpers-screen-assertions")
               (:file "cell-tests")
               (:file "cell-display-tests")
               (:file "screen-tests")
               (:file "screen-tests-b")
               (:file "screen-tests-c")
               (:file "screen-tests-d")
               (:file "screen-queue-palette-tests")
               (:file "screen-wrap-copy-tests")
               (:file "cursor-tests")
               (:file "cursor-tests-b")
               (:file "cursor-tests-c")
               (:file "cursor-tests-d")
               (:file "cursor-tests-e")
               (:file "char-write-tests")
               (:file "scroll-tests")
               (:file "scroll-erase-tests")
               (:file "scroll-region-tests")
               (:file "scroll-line-edit-tests")
               (:file "scroll-tests-b")
               (:file "scroll-tests-c")
               (:file "scroll-tests-d")
               (:file "modes-tests")
               (:file "modes-tests-b")
               (:file "modes-tests-c")
               (:file "modes-tests-d")
               (:file "modes-tests-e")
               (:file "sgr-tests")
               (:file "sgr-tests-b")
               (:file "csi-composition-tests")
               (:file "csi-tests")
               (:file "csi-tests-d")
               (:file "csi-tests-b")
               (:file "csi-tests-c")
               (:file "parser-utf8-tests")
               (:file "parser-osc-tests")
               (:file "parser-escape-tests")
               (:file "parser-tests-b")
               (:file "parser-control-state-tests")
               (:file "parser-osc-continuations-tests")
               (:file "parser-osc-dispatch-tests")
               (:file "parser-osc52-tests")
               (:file "parser-osc7-tests")
               (:file "parser-dcs-tests")
               (:file "parser-parser-utils-tests")
               (:file "parser-basic-text-tests")
               (:file "parser-inline-predicate-tests")
               (:file "parser-state-cps-tests")
               (:file "emulator-tests")
               (:file "parser-fuzz-tests")               )
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
                 (error "nerimux-terminal test suite failed")))))
