(in-package #:nerimux/test/net)

(describe "protocol-suite"


  (it "target-field-p-table"
    (dolist (c '(("$"                        t   "bare '$' is a target")
                 (":"                        t   "bare ':' is a target")
                 ("."                        t   "bare '.' is a target")
                 ("0"                        nil "plain integer is not a target")
                 ("copy-mode-search-forward" nil "hyphenated command name is not a target")))
      (destructuring-bind (input expected desc) c
        (declare (ignore desc))
        (if expected
            (expect (nerimux/protocol:target-field-p input) :to-be-truthy)
            (expect (nerimux/protocol:target-field-p input) :to-be-falsy)))))

  (it "target-field-p-rejects-empty-fields"
    (expect (nerimux/protocol:target-field-p "") :to-be-falsy))

  (it "split-on-nul-bytes-rejects-an-incomplete-field"
    (expect (null (nerimux/protocol:split-on-nul-bytes #(108 115))) :to-be-truthy))


  (it "encode-command-payload-without-target-starts-with-command-name"
    (let* ((payload (encode-command-payload :list-sessions))
           (fields  (nerimux/protocol:split-on-nul-bytes payload)))
      (expect (equal '("list-sessions") fields))))

  (it "encode-command-payload-with-target-places-target-first"
    (let* ((payload (encode-command-payload :send-keys :target "$0:1.0"))
           (fields  (nerimux/protocol:split-on-nul-bytes payload)))
      (expect (equal '("$0:1.0" "send-keys") fields))))

  (it "encode-command-payload-with-args-appends-args-after-command"
    (let* ((payload (encode-command-payload :send-keys :args '("C-c" "q")))
           (fields  (nerimux/protocol:split-on-nul-bytes payload)))
      (expect (equal '("send-keys" "C-c" "q") fields))))

  (it "encode-command-payload-accepts-string-command-names"
    (let ((payload (encode-command-payload "list-sessions")))
      (expect (equal '("list-sessions")
                     (nerimux/protocol:split-on-nul-bytes payload)))))

  (it "decode-command-payload-keeps-unknown-command-names-as-strings"
    (multiple-value-bind (command target args)
        (nerimux/protocol:decode-command-payload
         (encode-command-payload "future-command" :target "$0" :args '("arg")))
      (expect (string= "future-command" command))
      (expect (string= "$0" target))
      (expect (equal '("arg") args)))))
