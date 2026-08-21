(in-package #:nerimux/terminal/parser)

;;;; OSC 52 clipboard helpers.

;;; OSC 52 delivers clipboard data; the Base64 payload is decoded and forwarded
;;; to *osc52-handler* when one has been installed.  nerimux keeps no
;;; clipboard state of its own (docs/notes/workspace-requirements.md §1.1,
;;; §R3.3): a pane's OSC 52 write is passed straight through to the client
;;; terminal via the owning SCREEN's clipboard-queue — the same queue
;;; copy-mode yank uses (nerimux/commands::%maybe-copy-to-clipboard).

(defvar *osc52-handler* nil
  "A function of two arguments (screen, text) called when OSC 52 clipboard
   data is received from a pane's SCREEN.  Wired to %osc52-inbound-passthrough
   at load time, at the bottom of this file (after osc52-clipboard-sequence,
   which it calls, is defined).")

(defparameter +base64-alphabet+
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  "The standard (RFC 4648 §4) Base64 alphabet, shared by %base64-decode and
   %base64-encode so both stay in sync should a variant ever be needed.")

(defun %alphabet-index (alphabet char)
  "Return the zero-based index of CHAR in ALPHABET, or NIL if absent."
  (position char alphabet :test #'char=))

(defun %b64-byte0 (index-a index-b)
  (logior (ash index-a 2)
          (ldb (byte 2 4) index-b)))

(defun %b64-byte1 (index-b index-c)
  (logior (ash (ldb (byte 4 0) index-b) 4)
          (ldb (byte 4 2) index-c)))

(defun %b64-byte2 (index-c index-d)
  (logior (ash (ldb (byte 2 0) index-c) 6)
          index-d))

(defun %decode-base64-group (alphabet encoded-string group-start)
  "Decode one 4-character Base64 group starting at GROUP-START in ENCODED-STRING.
   Returns (values byte0-or-nil byte1-or-nil byte2-or-nil)."
  (let* ((index-a (%alphabet-index alphabet (char encoded-string group-start)))
         (index-b (%alphabet-index alphabet (char encoded-string (1+ group-start))))
         (index-c (%alphabet-index alphabet (char encoded-string (+ group-start 2))))
         (index-d (%alphabet-index alphabet (char encoded-string (+ group-start 3)))))
    (when (and index-a index-b)
      (values (%b64-byte0 index-a index-b)
              (when index-c (%b64-byte1 index-b index-c))
              (when index-d (%b64-byte2 index-c index-d))))))

(defun %base64-decode (encoded-string)
  "Decode Base64-encoded ENCODED-STRING into a byte vector."
  (handler-case
      (let* ((alphabet +base64-alphabet+)
             (input-length (length encoded-string))
             (output (make-array 0 :element-type '(unsigned-byte 8)
                                   :fill-pointer 0 :adjustable t)))
        (when (= (mod input-length 4) 0)
          (loop for group-start from 0 below input-length by 4
                do (multiple-value-bind (byte0 byte1 byte2)
                       (%decode-base64-group alphabet encoded-string group-start)
                     (when byte0 (vector-push-extend byte0 output))
                     (when byte1 (vector-push-extend byte1 output))
                     (when byte2 (vector-push-extend byte2 output))))
          output))
    (error () nil)))

(defun %base64-encode (bytes)
  "Encode a sequence of (unsigned-byte 8) BYTES to a padded Base64 string."
  (let ((alphabet +base64-alphabet+)
        (n (length bytes)))
    (with-output-to-string (out)
      (loop for i from 0 below n by 3
            for b0 = (aref bytes i)
            for b1 = (and (< (1+ i) n) (aref bytes (1+ i)))
            for b2 = (and (< (+ i 2) n) (aref bytes (+ i 2)))
            do (let* ((x (ash b0 -2))
                      (y (logior (ash (ldb (byte 2 0) b0) 4)
                                 (if b1 (ash b1 -4) 0)))
                      (z (if b1
                             (logior (ash (ldb (byte 4 0) b1) 2)
                                     (if b2 (ash b2 -6) 0))
                             64))
                      (w (if b2 (ldb (byte 6 0) b2) 64)))
                 (write-char (char alphabet x) out)
                 (write-char (char alphabet y) out)
                 (write-char (if (< (1+ i) n) (char alphabet z) #\=) out)
                 (write-char (if (< (+ i 2) n) (char alphabet w) #\=) out))))))

(defun osc52-clipboard-sequence (text)
  "Build the OSC 52 set-clipboard escape sequence."
  (format nil "~C]52;c;~A~C\\"
          #\Escape
          (%base64-encode (cl-codec-kit:string-to-octets text :encoding :utf-8))
          #\Escape))

(defun %osc52-inbound-passthrough (screen text)
  "Forward an inbound OSC 52 clipboard write from a pane straight to the
   client terminal: rebuild the escape sequence and push it onto SCREEN's
   clipboard-queue, the same queue copy-mode yank uses.  nerimux holds no
   clipboard state of its own (§1.1, §R3.3)."
  (push (osc52-clipboard-sequence text) (screen-clipboard-queue screen)))

(defun initialize-osc52-handler ()
  "Wire the OSC 52 clipboard handler to the pass-through above.  Called once
   at load time; separated from top-level to make the coupling explicit and
   allow re-initialisation if the handler variable is reset."
  (setf *osc52-handler* #'%osc52-inbound-passthrough))

;; Wire OSC 52 handler at module load time via an explicit named call.
(initialize-osc52-handler)
