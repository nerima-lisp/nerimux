(in-package #:nerimux/test)

;;;; Capture-pane and terminal rendering dispatch cases.

(describe "dispatch-suite"

  ;; capture-pane -a errors with tmux's 'no alternate screen' unless the pane's
  ;; alternate screen is in use; while active, -a captures the (live) alternate.
  (it "capture-pane-a-requires-alternate-screen"
    (with-fake-session (s)
      (let ((screen (nerimux/model:pane-screen (nerimux/model:session-active-pane s))))
        (let ((*overlay* nil))
          (nerimux::%cmd-capture-pane-arg s '("-a" "-p"))
          (assert-overlay-contains "no alternate screen" (overlay-lines)
                                   "capture-pane -a without an alt screen"))
        ;; Enter the alternate screen: -a now captures.
        (nerimux/terminal/actions:enter-alt-screen screen)
        (let ((*overlay* nil))
          (nerimux::%cmd-capture-pane-arg s '("-a" "-p"))
          (expect (null (and *overlay* (search "no alternate screen" *overlay*))))))))

  ;; capture-pane -J joins a scrollback row that wrapped into the next row -
  ;; the wrap flag travels with the row when it scrolls into history.
  (it "capture-pane-J-joins-wrapped-scrollback-rows"
    (with-fake-session (s)
      (let* ((pane   (nerimux/model:session-active-pane s))
             (screen (nerimux/model:pane-screen pane))
             (w      (nerimux/terminal/types:screen-width screen)))
        ;; Row 0 content 'AB', marked wrapped; scroll it into history.
        (setf (nerimux/terminal/types:cell-char
               (nerimux/terminal/types:screen-cell screen 0 0)) #\A
              (nerimux/terminal/types:cell-char
               (nerimux/terminal/types:screen-cell screen 1 0)) #\B)
        (nerimux/terminal/types:%mark-line-wrapped screen 0)
        (nerimux/terminal/actions:scroll-up-one screen)
        ;; The visible top row now continues the wrapped line: 'CD'.
        (setf (nerimux/terminal/types:cell-char
               (nerimux/terminal/types:screen-cell screen 0 0)) #\C
              (nerimux/terminal/types:cell-char
               (nerimux/terminal/types:screen-cell screen 1 0)) #\D)
        (expect (eq t (first (nerimux/terminal/types:screen-scrollback-wrapped screen))))
        (let ((joined (nerimux/commands:capture-pane pane
                                                     :include-scrollback t
                                                     :join t))
              (plain  (nerimux/commands:capture-pane pane
                                                     :include-scrollback t)))
          (declare (ignorable w))
          ;; -J preserves trailing spaces, so assert AB and CD land on the SAME
          ;; line rather than being adjacent characters.
          (flet ((line-with-ab (text)
                   (find-if (lambda (l) (search "AB" l))
                            (host-kit:split-string text :separator '(#\Newline)))))
            (expect (search "CD" (or (line-with-ab joined) "")))
            (expect (null (search "CD" (or (line-with-ab plain) "")))))))))

  ;; ESC # 6 (DECDWL) records the row's line size; the renderer re-emits
  ;; ESC # 6 for that row (and ESC # 5 for unflagged rows) so the outer terminal
  ;; draws double-width lines; ESC # 5 clears; RIS resets.
  (it "decdwl-line-size-recorded-and-rendered"
    (with-fake-session (s)
      (let* ((pane   (nerimux/model:session-active-pane s))
             (screen (nerimux/model:pane-screen pane)))
        (nerimux/terminal/emulator:screen-process-bytes
         screen (cl-codec-kit:string-to-octets (format nil "~C#6WIDE" #\Escape)
                                        :encoding :utf-8))
        (expect (eql #\6 (gethash 0 (nerimux/terminal/types:screen-line-sizes screen))))
        (let ((out (nerimux/renderer::render-session-to-string s 5 20)))
          (expect (search (format nil "~C#6" #\Escape) out))
          (expect (search (format nil "~C#5" #\Escape) out)))
        (nerimux/terminal/emulator:screen-process-bytes
         screen (cl-codec-kit:string-to-octets (format nil "~C#5" #\Escape)
                                        :encoding :utf-8))
        (expect (null (gethash 0 (nerimux/terminal/types:screen-line-sizes screen))))
        (nerimux/terminal/emulator:screen-process-bytes
         screen (cl-codec-kit:string-to-octets (format nil "~C#6~Cc" #\Escape #\Escape)
                                        :encoding :utf-8))
        (expect (zerop (hash-table-count
                        (nerimux/terminal/types:screen-line-sizes screen)))))))

  ;;; -- capture-pane -S/-E line-range slicing ------------------------------------
  ;;;
  ;;; %capture-pane-parse-range-value and %capture-pane-slice-range had no test
  ;;; passing -S/-E to capture-pane at all before this — the whole line-range
  ;;; feature was untested.

  ;; %capture-pane-parse-range-value: NIL when absent, :edge for "-", an integer
  ;; (negative reaches into scrollback) otherwise, NIL for unparseable junk.
  (it "capture-pane-parse-range-value-table"
    (dolist (row '((nil    nil    "absent -S/-E value")
                   ("-"    :edge  "dash means edge of history/visible")
                   ("5"    5      "positive line number")
                   ("-3"   -3     "negative line number reaches into scrollback")
                   ("abc"  nil    "unparseable junk")))
      (destructuring-bind (raw expected desc) row
        (declare (ignore desc))
        (expect (equal expected
                       (nerimux::%capture-pane-parse-range-value raw))))))

  ;; %capture-pane-slice-range: line 0 is the first VISIBLE row; HEIGHT=3 over a
  ;; 5-line capture means lines 0-1 are scrollback (vis0 = 5-3 = 2) and lines
  ;; 2-4 are the visible rows 0-2.
  (it "capture-pane-slice-range-table"
    (let ((content (format nil "L0~%L1~%L2~%L3~%L4~%")))
      (dolist (row '((nil     nil     "L0~%L1~%L2~%L3~%L4~%" "no range -> unchanged")
                     (:edge   nil     "L0~%L1~%L2~%L3~%L4~%" "edge start -> whole history")
                     (0       0       "L2~%"                 "single visible row 0")
                     (-1      nil     "L1~%L2~%L3~%L4~%"     "negative start reaches into scrollback")
                     (2       0       ""                     "from >= to -> empty string")))
        (destructuring-bind (start end expected desc) row
          (declare (ignore desc))
          (expect (string= (format nil expected)
                           (nerimux::%capture-pane-slice-range content 3 start end)))))))

  ;; %cmd-capture-pane-arg wires -S/-E through to a real dispatch: -S 0 -E 0
  ;; (a single visible row) saves strictly less content to the paste buffer
  ;; than a plain capture-pane with no range restriction.
  (it "capture-pane-dispatch-honours-s-e-range"
    (with-fake-session (s)
      (let* ((pane (nerimux/model:session-active-pane s)))
        (feed (nerimux/model:pane-screen pane) "row0")
        (nerimux::%cmd-capture-pane-arg s nil)
        (let ((full (nerimux/buffer:get-paste-buffer 0)))
          (nerimux::%cmd-capture-pane-arg s '("-S" "0" "-E" "0"))
          (let ((sliced (nerimux/buffer:get-paste-buffer 0)))
            (expect full :to-be-truthy)
            (expect sliced :to-be-truthy)
            (expect (< (length sliced) (length full)))))))))
