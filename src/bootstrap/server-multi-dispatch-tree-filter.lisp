(in-package #:nerimux)

(defun %client-tree-filter-buffer-delete-character (conn)
  "Backspace in :tree-filter mode; reset the tree scroll after editing."
  (let ((query (client-conn-tree-filter conn)))
    (when (and (stringp query) (plusp (length query)))
      (setf (client-conn-tree-filter conn) (subseq query 0 (1- (length query)))
            (client-conn-tree-scroll conn) 0)
      (%mark-dirty)
      t)))

(defconstant +max-tree-filter-length+ 256
  "Hard cap on the tree-filter query length.")

(defun %client-tree-filter-buffer-append (conn payload)
  "Append printable input to the tree filter, within its fixed cap."
  (let ((text (%client-payload-text payload))
        (query (or (client-conn-tree-filter conn) "")))
    (when (and text
               (every (lambda (character)
                        (>= (char-code character) 32))
                      text)
               (< (length query) +max-tree-filter-length+))
      (setf (client-conn-tree-filter conn)
            (concatenate 'string query text)
            (client-conn-tree-scroll conn) 0)
      (%mark-dirty)
      t)))

(define-key-rules %handle-client-tree-filter-key-payload (session conn payload)
  "Handle ESC, Enter, editing, and printable input in tree-filter mode."
  (27
   (%client-esc-swallow-start conn)
   (%transition-client-ui-mode conn :cancel)
   (%mark-dirty)
   t)
  ((or (%client-byte-p payload 13) (%client-byte-p payload 10))
   (%transition-client-ui-mode conn :accept)
   (%mark-dirty)
   t)
  ((or (%client-byte-p payload 8) (%client-byte-p payload 127))
   (%client-tree-filter-buffer-delete-character conn)
   t)
  (t
   (%client-tree-filter-buffer-append conn payload)
   t))
