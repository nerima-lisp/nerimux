(in-package #:nerimux/test/terminal)

(describe "terminal-suite/special"



  (it "ground-escape-osc-state-have-docstrings"
    (dolist (fn-symbol '(nerimux/terminal/parser:ground-state
                         nerimux/terminal/parser:escape-state
                         nerimux/terminal/parser:osc-state))
      (let ((doc (documentation fn-symbol 'function)))
        (expect (and (stringp doc) (plusp (length doc)))))))

  (it "bel-sets-bell-pending"
    (with-screen (s 10 2)
      (feed s "ab")
      (expect (nerimux/terminal/types:screen-bell-pending s) :to-be-falsy)
      (screen-process-bytes s (make-array 1 :element-type '(unsigned-byte 8)
                                            :initial-contents '(#x07)))
      (expect (char= #\a (char-at s 0 0)))
      (expect (char= #\b (char-at s 1 0)))
      (check-cursor s 2 0)
      (expect (nerimux/terminal/types:screen-bell-pending s))))


  (defun %feed-osc (s payload)
    "Feed an OSC sequence (ESC ] PAYLOAD ST) to screen S via screen-process-bytes."
    (screen-process-bytes s
      (cl-codec-kit:string-to-octets (format nil "~C]~A~C\\" #\Escape payload #\Escape)
                              :encoding :utf-8)))

  (it "osc-0-1-2-set-screen-title"
    (dolist (row '((0 "my-window"  "OSC 0 sets the window title")
                   (1 "icon-name"  "OSC 1 (icon name) also sets screen-title")
                   (2 "xterm-title" "OSC 2 also sets the window title")))
      (destructuring-bind (cmd title desc) row
        (declare (ignore desc))
        (with-screen (s 20 5)
          (%feed-osc s (format nil "~D;~A" cmd title))
          (expect (string= title (nerimux/terminal/types:screen-title s)))))))

  (it "parse-osc-color-forms"
    (dolist (row '((#xFF8000 "#ff8000"              "#RRGGBB")
                   (#xFF0000 "#f00"                 "#RGB expands (0xF->0xFF)")
                   (#xFF0000 "rgb:ffff/0000/0000"   "rgb: with 16-bit channels scales down to 8-bit")
                   (#x00FF00 "rgb:00/ff/00"         "rgb: with 8-bit channels")
                   (#xAAABAB "rgb:a/abc/abcd"       "rgb: with mixed 4-bit/12-bit/16-bit channel widths")))
      (destructuring-bind (expected input desc) row
        (declare (ignore desc))
        (expect (= expected (nerimux/terminal/parser::%parse-osc-color input)))))
    (dolist (input '("tomato" "rgb:zz/00/00"))
      (expect (null (nerimux/terminal/parser::%parse-osc-color input)))))

  (it "parse-osc-color-rgb-rejects-empty-and-extra-fields"
    (dolist (input '("rgb:ff/00/00/"    ; trailing delimiter -> 4 fields
                     "rgb:/ff/00/00"    ; leading delimiter  -> 4 fields
                     "rgb:ff//00"       ; empty middle channel
                     "rgb:ff/00"        ; too few
                     "rgb:ff/00/00/00")) ; too many
      (expect (null (nerimux/terminal/parser::%parse-osc-color input))))
    (expect (= #xFF0000 (nerimux/terminal/parser::%parse-osc-color "rgb:ff/00/00"))))

  (it "osc-color-helper-replies-format-correctly"
    (expect (string= (format nil "~C]11;rgb:0101/0202/0303~C\\" #\Escape #\Escape)
                     (nerimux/terminal/parser::%osc-color-reply 11 #x010203)))
    (expect (string= (format nil "~C]4;196;rgb:ffff/0000/0000~C\\" #\Escape #\Escape)
                     (nerimux/terminal/parser::%osc4-reply 196 #xFF0000))))

  (it "osc-rgb-reply-channel-doubling-arithmetic"
    (dolist (row '((#x000000 "0000" "0000" "0000" "black  #x00->\"0000\"")
                   (#xFFFFFF "ffff" "ffff" "ffff" "white  #xFF->\"ffff\"")
                   (#x800000 "8080" "0000" "0000" "maroon #x80->\"8080\"")
                   (#x010203 "0101" "0202" "0303" "mixed  #x01->\"0101\" #x02->\"0202\" #x03->\"0303\"")))
      (destructuring-bind (rgb er eg eb desc) row
        (declare (ignore desc))
        (let ((reply (nerimux/terminal/parser::%osc-rgb-reply "]11;rgb:" rgb)))
          (expect (search (format nil "~A/~A/~A" er eg eb) reply))))))


  (it "osc-4-set-does-not-reply"
    (with-screen (s 20 5)
      (%feed-osc s "4;1;rgb:ffff/0000/ffff")
      (expect (null (nerimux/terminal/types:screen-response-queue s)))))

  (it "osc-4-set-stores-custom-palette-override"
    (with-screen (s 20 5)
      (%feed-osc s "4;1;rgb:ffff/0000/ffff")
      (expect (= #xFF00FF (nerimux/terminal/types:%palette-override-get s 1)))))

  (it "osc-4-query-reports-custom-override"
    (with-screen (s 20 5)
      (%feed-osc s "4;1;rgb:ffff/0000/ffff")
      (%feed-osc s "4;1;?")
      (expect (string= (format nil "~C]4;1;rgb:ffff/0000/ffff~C\\" #\Escape #\Escape)
                       (first (nerimux/terminal/types:screen-response-queue s))))))

  (it "osc-4-set-and-query-in-one-sequence"
    (with-screen (s 20 5)
      (%feed-osc s "4;1;rgb:ffff/0000/ffff;1;?")
      (expect (string= (format nil "~C]4;1;rgb:ffff/0000/ffff~C\\" #\Escape #\Escape)
                       (first (nerimux/terminal/types:screen-response-queue s))))))

  (it "osc-4-set-junk-spec-is-ignored"
    (with-screen (s 20 5)
      (%feed-osc s "4;junk")
      (expect (null (nerimux/terminal/types:screen-response-queue s)))))

  (it "osc-104-resets-single-index"
    (with-screen (s 20 5)
      (%feed-osc s "4;1;rgb:ffff/0000/ffff")
      (%feed-osc s "104;1")
      (expect (null (nerimux/terminal/types:%palette-override-get s 1)))))

  (it "osc-104-empty-body-resets-all"
    (with-screen (s 20 5)
      (%feed-osc s "4;1;rgb:ffff/0000/ffff")
      (%feed-osc s "104")
      (expect (null (nerimux/terminal/types:%palette-override-get s 1)))))

  (it "osc-color-command-routes-query-and-set"
    (with-screen (s 20 5)
      (%feed-osc s "10;?")
      (expect (not (null (nerimux/terminal/types:screen-response-queue s)))))
    (with-screen (s 20 5)
      (%feed-osc s "10;#112233")
      (expect (= #x112233 (nerimux/terminal/types:screen-osc-default-fg s)))))

  (it "osc-11-query-reports-default-background"
    (with-screen (s 20 5)
      (%feed-osc s "11;?")
      (expect (string= (format nil "~C]11;rgb:0000/0000/0000~C\\" #\Escape #\Escape)
                       (first (nerimux/terminal/types:screen-response-queue s))))))

  (it "osc-10-query-reports-default-foreground"
    (with-screen (s 20 5)
      (%feed-osc s "10;?")
      (expect (string= (format nil "~C]10;rgb:ffff/ffff/ffff~C\\" #\Escape #\Escape)
                       (first (nerimux/terminal/types:screen-response-queue s))))))

  (it "osc-11-set-updates-default-background"
    (with-screen (s 20 5)
      (%feed-osc s "11;rgb:ffff/0000/0000")
      (expect (= #xFF0000 (nerimux/terminal/types:screen-osc-default-bg s)))
      (expect (null (nerimux/terminal/types:screen-response-queue s)))))

  (it "osc-11-query-after-set-roundtrips"
    (with-screen (s 20 5)
      (%feed-osc s "11;#3366ff")
      (%feed-osc s "11;?")
      (expect (string= (format nil "~C]11;rgb:3333/6666/ffff~C\\" #\Escape #\Escape)
                       (first (nerimux/terminal/types:screen-response-queue s))))))

  (it "osc-111-resets-default-background"
    (with-screen (s 20 5)
      (%feed-osc s "11;#ffffff")
      (expect (= #xFFFFFF (nerimux/terminal/types:screen-osc-default-bg s)))
      (%feed-osc s "111")
      (expect (= #x000000 (nerimux/terminal/types:screen-osc-default-bg s)))))


  (it "xterm-palette-rgb-values"
    (dolist (c '((#x000000   0 "index 0 = black")
                 (#xffffff  15 "index 15 = white")
                 (#x000000  16 "cube origin = black")
                 (#x0000ff  21 "index 21 = pure blue")
                 (#xff0000 196 "index 196 = pure red")
                 (#xffffff 231 "cube max = white")
                 (#x080808 232 "grayscale ramp start")
                 (#xeeeeee 255 "grayscale ramp end")))
      (destructuring-bind (expected idx desc) c
        (declare (ignore desc))
        (expect (= expected (nerimux/terminal/parser::%xterm-palette-rgb idx)))))
    (expect (null (nerimux/terminal/parser::%xterm-palette-rgb 256))))

  (it "osc-4-query-reports-palette-colour"
    (with-screen (s 20 5)
      (%feed-osc s "4;196;?")
      (expect (string= (format nil "~C]4;196;rgb:ffff/0000/0000~C\\" #\Escape #\Escape)
                       (first (nerimux/terminal/types:screen-response-queue s))))))

  (it "osc-4-query-multiple-indices"
    (with-screen (s 20 5)
      (%feed-osc s "4;0;?;15;?")
      (expect (= 2 (length (nerimux/terminal/types:screen-response-queue s))))))

  (it "osc-8-stamps-cell-hyperlink"
    (with-screen (s 20 5)
      (%feed-osc s "8;;https://example.com")
      (feed s "X")
      (%feed-osc s "8;;")        ; clear the hyperlink
      (feed s "Y")
      (expect (string= "https://example.com"
                       (nerimux/terminal/types:cell-hyperlink
                        (nerimux/terminal/types:screen-cell s 0 0))))
      (expect (null (nerimux/terminal/types:cell-hyperlink
                     (nerimux/terminal/types:screen-cell s 1 0))))))

  (it "osc-bel-no-crash"
    (with-screen (s 10 2)
      (feed s "a")
      (screen-process-bytes s
        (cl-codec-kit:string-to-octets
          (format nil "~C]0;window title~C" #\Escape (code-char 7))
          :encoding :utf-8))
      (feed s "b")
      (expect (char= #\a (char-at s 0 0)))
      (expect (char= #\b (char-at s 1 0)))))

  (it "osc-st-ignored"
    (with-screen (s 10 2)
      (feed s "a")
      (screen-process-bytes s
        (cl-codec-kit:string-to-octets
          (format nil "~C]0;title~C\\" #\Escape #\Escape)
          :encoding :utf-8))
      (feed s "b")
      (expect (char= #\a (char-at s 0 0)))
      (expect (char= #\b (char-at s 1 0))))))
