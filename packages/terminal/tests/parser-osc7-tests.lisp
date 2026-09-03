(in-package #:nerimux/test/terminal)

(describe "terminal-suite/osc7-cwd-coverage"


  (it "osc7-path-extraction"
    (flet ((p (s) (nerimux/terminal/parser::%osc7-path s)))
      (dolist (c '(("file://host/home/u" "/home/u"   "with host")
                   ("file:///home/u"     "/home/u"   "empty host")
                   ("file://host"        "/"         "host but no path -> /")
                   ("not-a-url"          "not-a-url" "non-file:// -> unchanged")))
        (destructuring-bind (input expected desc) c
          (declare (ignore desc))
          (expect (string= expected (p input)))))))

  (it "osc7-sets-screen-cwd-end-to-end"
    (with-screen (s 20 5)
      (screen-process-bytes s
        (cl-codec-kit:string-to-octets
          (format nil "~C]7;file://myhost/home/user/project~C" #\Escape (code-char 7))
          :encoding :utf-8))
      (expect (string= "/home/user/project" (nerimux/terminal/types:screen-cwd s)))))

  (it "percent-decode-cases"
    (flet ((d (s) (nerimux/terminal/parser::%percent-decode s)))
      (dolist (c '(("a%20b"     "a b" "%20 -> space")
                   ("abc"       "abc" "no % -> unchanged")
                   ("%2F"       "/"   "%2F -> /")
                   ("a%"        "a%"  "incomplete trailing % is literal")
                   ("a%zz"      "a%zz" "non-hex after % is literal")
                   ("%E2%9C%93" "✓"  "UTF-8 multibyte (U+2713) decodes")))
        (destructuring-bind (input expected desc) c
          (declare (ignore desc))
          (expect (string= expected (d input)))))))

  (it "osc7-path-percent-decoded"
    (dolist (c '(("file://host/My%20Docs"              "/My Docs")
                 ("file:///Library/Application%20Support" "/Library/Application Support")))
      (destructuring-bind (url expected) c
        (expect (string= expected (nerimux/terminal/parser::%osc7-path url))))))

  (it "screen-cwd-defaults-empty"
    (with-screen (s 20 5)
      (expect (string= "" (nerimux/terminal/types:screen-cwd s)))))


  (it "define-osc-rules-macro-is-defined"
    (expect (macro-function 'nerimux/terminal/parser::define-osc-rules))))
