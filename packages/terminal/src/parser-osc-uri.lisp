(in-package #:nerimux/terminal/parser)

;;;; OSC 7 and OSC 8 helpers.
(defun %flush-utf8-octets (octets out)
  "Write accumulated UTF-8 OCTETS to the string stream OUT and reset OCTETS."
  (when (> (length octets) 0)
    (write-string
     (cl-codec-kit:octets-to-string octets
                                    :encoding
                                    :utf-8
                                    :errorp
                                    nil
                                    :replacement
                                    #\REPLACEMENT_CHARACTER)
     out)
    (setf (fill-pointer octets) 0)))

(defun %percent-decode (encoded-string)
  "Decode %XX percent-escapes in ENCODED-STRING, UTF-8 aware."
  (let ((octets
         (make-array 0
                     :element-type
                     '(unsigned-byte 8)
                     :fill-pointer
                     0
                     :adjustable
                     t))
        (len (length encoded-string)))
    (with-output-to-string (out)
      (loop with i = 0
            while (< i len)
            for ch = (char encoded-string i)
            do (cond
                 ((and (char= ch #\%) (<= (+ i 2) (1- len)))
                  (let ((hi (%hex-digit-16 (char encoded-string (1+ i))))
                        (lo (%hex-digit-16 (char encoded-string (+ i 2)))))
                    (if (and hi lo)
                        (progn
                          (vector-push-extend (+ (* hi 16) lo) octets)
                          (incf i 3))
                        (progn
                          (%flush-utf8-octets octets out)
                          (write-char ch out)
                          (incf i)))))
                 (t
                   (%flush-utf8-octets octets out)
                   (write-char ch out)
                   (incf i))))
      (%flush-utf8-octets octets out))))

(defun %handle-osc-8 (screen body)
  "Handle OSC 8 hyperlink state."
  (let ((uri-start (position #\; body)))
    (when uri-start
      (let ((uri (subseq body (1+ uri-start))))
        (setf (screen-current-hyperlink screen) (and (> (length uri) 0) uri))))))

(defun %osc7-path (body)
  "Extract the filesystem path from an OSC 7 file:// URL and percent-decode it."
  (let* ((prefix "file://")
         (prefix-length (length prefix)))
    (if (and (>= (length body) prefix-length)
             (string= prefix body :end2 prefix-length))
        (let* ((after-scheme (subseq body prefix-length))
               (slash (position #\/ after-scheme)))
          (if slash
              (%percent-decode (subseq after-scheme slash))
              "/"))
        body)))
