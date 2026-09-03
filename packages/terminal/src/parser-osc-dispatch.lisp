(in-package #:nerimux/terminal/parser)

(defun %parse-osc-command (payload semicolon-position)
  "Parse the OSC command integer from PAYLOAD up to SEMICOLON-POSITION."
  (handler-case (parse-integer (subseq payload 0 semicolon-position))
    (parse-error ()
      nil)))

(defun %handle-osc-52 (text)
  "Handle OSC 52 clipboard write: decode Base64 payload and call *osc52-handler*."
  (let* ((inner-semi (position #\; text))
         (payload-data (and inner-semi (subseq text (1+ inner-semi)))))
    (when (and payload-data (string/= payload-data "?"))
      (let* ((decoded-bytes (and payload-data (%base64-decode payload-data)))
             (decoded-text
              (and decoded-bytes
                   (handler-case (cl-codec-kit:octets-to-string decoded-bytes
                                                                :encoding
                                                                :utf-8)
                     (cl-codec-kit:decode-error ()
                       nil)))))
        (when (and decoded-text *osc52-handler*)
          (funcall *osc52-handler* decoded-text))))))

(defun %handle-osc-133 (screen body)
  "OSC 133 (shell integration / semantic prompts)."
  (when (and (plusp (length body)) (char-equal (char body 0) #\A))
    (let ((absolute
           (+ (screen-history-trimmed screen)
              (length (screen-scrollback screen))
              (screen-cursor-y screen))))
      (pushnew absolute (screen-prompt-marks screen)))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defmacro define-osc-rules (&rest rules)
    "Build %DISPATCH-OSC-COMMAND from a declarative OSC command table."
    `(defun %dispatch-osc-command (screen command body)
       (declare (type screen screen)
                (ignorable body))
       (cond
         ,@(loop for rule in rules
                 collect (destructuring-bind (command-designator &body
                                                                 body-forms) 
                             rule
                           (let ((commands
                                  (if (listp command-designator)
                                      command-designator
                                      (list command-designator))))
                             `((member command ',commands)
                               (progn
                                 ,@body-forms)))))
         (t nil)))))

(define-osc-rules ((0 1 2) (set-screen-title screen body))
                  (8 (%handle-osc-8 screen body))
                  (7 (set-screen-cwd screen (%osc7-path body)))
                  (10
                   (%osc-color-command screen
                                       10
                                       body
                                       (screen-osc-default-fg screen)
                                       #'(lambda (rgb)
                                           (setf (screen-osc-default-fg screen) rgb))))
                  (110 (reset-osc-default-fg screen))
                  (11
                   (%osc-color-command screen
                                       11
                                       body
                                       (screen-osc-default-bg screen)
                                       #'(lambda (rgb)
                                           (setf (screen-osc-default-bg screen) rgb))))
                  (111 (reset-osc-default-bg screen))
                  (4 (%handle-osc-4 screen body))
                  (104 (%handle-osc-104 screen body))
                  (52 (%handle-osc-52 body))
                  (133 (%handle-osc-133 screen body)))

(defun %dispatch-osc (screen payload-buffer)
  "Parse accumulated OSC payload PAYLOAD-BUFFER and apply side effects to SCREEN.

   OSC payloads arrive from the child process and are untrusted, so a malformed
   UTF-8 sequence must not signal out of the parser: :ERRORP NIL substitutes
   :REPLACEMENT for each one instead.

   :REPLACEMENT is passed explicitly rather than defaulted.  CL-CODEC-KIT's own
   default is #\\SUB (U+001A), which is a C0 control character — wrong for a
   terminal emulator, where this string is scanned for #\\; and then handed to
   title/clipboard/cwd handlers as display text.  U+FFFD is both what babel did
   here originally (its UTF-8 decoder hardcodes +REPL+ = #xFFFD for every
   decoding error, regardless of the encoding's own :DEFAULT-REPLACEMENT slot)
   and what nerimux substitutes everywhere else it cannot represent a code
   point — see SAFE-CODE-CHAR and +UNICODE-REPLACEMENT-CHAR+ in cell.lisp.

   How MANY U+FFFD one bad sequence yields is not guaranteed: CL-CODEC-KIT
   emits one per decode error and resyncs one octet at a time, so ED A0 80
   yields three.  Nothing here is length-sensitive: PAYLOAD is only scanned for
   the first #\\; and split there, and BODY reaches title/colour/clipboard/cwd
   handlers that treat it as opaque text."
  (let* ((payload
          (cl-codec-kit:octets-to-string payload-buffer
                                         :encoding
                                         :utf-8
                                         :errorp
                                         nil
                                         :replacement
                                         #\REPLACEMENT_CHARACTER))
         (semi-pos (position #\; payload))
         (command (%parse-osc-command payload (or semi-pos (length payload))))
         (body
          (if semi-pos
              (subseq payload (1+ semi-pos))
              "")))
    (when command
      (%dispatch-osc-command screen command body))))
