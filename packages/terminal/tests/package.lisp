;;;; Test package for nerimux-terminal.

(defpackage #:nerimux/test/terminal
  ;; The test framework is cl-weave, used natively: every file registers its own
  ;; top-level (describe "name" (it "case" ...) ...) block.
  (:use #:cl)
  (:shadowing-import-from #:cl-weave #:describe)
  (:import-from #:cl-weave
                #:it #:it-only #:it-concurrent #:it-sequential
                #:it-each #:describe-each
                #:describe-only #:describe-concurrent #:describe-sequential
                #:expect #:expect-not
                #:signals #:finishes #:fail #:skip
                #:before-each #:after-each #:before-all #:after-all #:around-each
                #:make-mock-function #:with-mocked-functions #:mock-calls
                #:it-property #:it-fuzz #:gen-integer #:gen-list #:gen-boolean #:gen-string
                #:gen-vector #:gen-member #:gen-one-of
                #:defmatcher)
  ;; The unit under test. These were in tests/package.lisp's one shared import
  ;; list; they move with the tests that use them.
  (:import-from #:nerimux/terminal
                #:make-screen
                #:screen-resize
                #:screen-process-bytes
                #:screen-cell
                #:screen-display-cell
                #:screen-cursor-x
                #:screen-cursor-y
                #:screen-width
                #:screen-height
                #:screen-clear-dirty
                #:cell-char
                #:cell-fg
                #:cell-bg
                #:cell-attrs
                #:cell-width)
  (:import-from #:nerimux/terminal/types
                #:screen-copy-mode-p
                #:screen-copy-offset
                #:screen-scrollback
                #:screen-copy-selecting
                #:screen-copy-mark
                #:screen-copy-mark-offset
                #:screen-copy-cursor
                #:screen-title
                #:screen-copy-line-selection-p
                #:screen-copy-rect-select-p
                #:screen-app-cursor-keys
                #:screen-dirty-p
                #:char-width
                #:screen-p)
  ;; Fixtures the units above terminal, and the root suite, reach for. Every
  ;; caller of these depends on nerimux-terminal, so this is the lowest unit that
  ;; can host them.
  (:export #:with-screen
           #:octets
           #:feed
           #:esc
           #:csi
           #:row-string
           #:cell-at
           #:char-at
           #:fg-at
           #:bg-at
           #:attrs-at
           #:check-cursor
           #:check-table
           #:row-blank-p
           #:utf8-feed
           #:feed-lines
           #:display-row-string
           #:check-row
           #:check-cell
           #:check-sgr-state))
