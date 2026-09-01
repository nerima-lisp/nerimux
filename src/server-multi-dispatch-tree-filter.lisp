(in-package #:nerimux)

(defun %client-tree-filter-buffer-delete-character (conn)
  "Backspace in :tree-filter mode; reset the tree scroll after editing."
  (let ((query (client-conn-tree-filter conn)))
    (when (and (stringp query) (plusp (length query)))
      (setf (client-conn-tree-filter conn) (subseq query 0 (1- (length query)))
            (client-conn-tree-scroll conn) 0)
      (%mark-dirty)
      t)))

(defun %client-tree-filter-buffer-append (conn payload)
  "Append printable input to the tree filter, within its fixed cap."
  (let ((text (%client-payload-text payload))
        (query (or (client-conn-tree-filter conn) "")))
    (when 
        (and text
             (every
              (lambda (character)
                (>= (char-code character) 32))
              text)
             (< (length query) +max-tree-filter-length+))
      (setf (client-conn-tree-filter conn) (concatenate 'string query text)
            (client-conn-tree-scroll conn) 0)
      (%mark-dirty)
      t)))

(define-key-rules %handle-client-tree-filter-key-payload (session conn payload)
  "Handle ESC, Enter, editing, and printable input in tree-filter mode."
  (27
   (%client-esc-swallow-start conn)
   ;; ESC drops the in-progress query entirely; Enter below keeps it -- the
   ;; user is happy with the filtered set and wants to keep navigating it
   ;; with MODAL back to NIL, not have it silently reset to the full tree.
   (%set-client-modal conn nil)
   (setf (client-conn-tree-filter conn) nil)
   (%mark-dirty)
   t)
  ((or (%client-byte-p payload 13) (%client-byte-p payload 10))
   (%set-client-modal conn nil)
   (%mark-dirty)
   t)
  ((or (%client-byte-p payload 8) (%client-byte-p payload 127))
   (%client-tree-filter-buffer-delete-character conn)
   t)
  (t
   (%client-tree-filter-buffer-append conn payload)
   t))
