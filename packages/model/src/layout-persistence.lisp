(in-package #:nerimux/layout)

(defconstant +checksum-multiplier+
  61
  "Multiplier for the rolling 16-bit layout-string checksum.")

(defconstant +checksum-mask+
  #xFFFF
  "16-bit mask applied at each step of the rolling layout-string checksum.")

(defun %layout-checksum (str)
  "Compute STR's rolling 16-bit layout-string checksum.
   Algorithm: rolling multiply-add on character codes (multiplier = +checksum-multiplier+).
   Returns a 4-hex-digit string."
  (format nil
          "~4,'0X"
          (reduce
           (lambda (accumulator ch)
             (logand +checksum-mask+
                     (+ (* accumulator +checksum-multiplier+) (char-code ch))))
           str
           :initial-value
           0)))

(defun layout-node-bounding-box (node)
  "Derive (values min-x min-y width height) for a LAYOUT-SPLIT node from its leaves.
   The bounding box is re-derived from the already-laid-out pane coordinates."
  (let* ((leaves (layout-leaves node))
         (min-x (reduce #'min leaves :key #'pane-x))
         (min-y (reduce #'min leaves :key #'pane-y))
         (max-rx
          (reduce #'max
                  leaves
                  :key
                  (lambda (p)
                    (+ (pane-x p) (pane-width p)))))
         (max-ry
          (reduce #'max
                  leaves
                  :key
                  (lambda (p)
                    (+ (pane-y p) (pane-height p))))))
    (values min-x min-y (- max-rx min-x) (- max-ry min-y))))

(define-layout-fold %node->string
                    (node)
                    :docstring
                    "Serialize a layout node (leaf or split) to a layout string fragment.
   Does not include the checksum prefix."
                    :on-null
                    ""
                    :on-leaf
                    (format nil
                            "~Dx~D,~D,~D,~D"
                            (pane-width leaf-pane)
                            (pane-height leaf-pane)
                            (pane-x leaf-pane)
                            (pane-y leaf-pane)
                            (pane-id leaf-pane))
                    :on-split
                    (let ((open-bracket
                           (orient-case split-orient :h #\{ :v #\[))
                          (close-bracket
                           (orient-case split-orient :h #\} :v #\])))
                      (multiple-value-bind (min-x min-y width height) 
                          (layout-node-bounding-box node)
                        (format nil
                                "~Dx~D,~D,~D,~S~C~A;~A~C"
                                width
                                height
                                min-x
                                min-y
                                split-ratio
                                open-bracket
                                (%node->string split-first)
                                (%node->string split-second)
                                close-bracket))))

(defun %parse-layout-integer (token)
  (handler-case
      (parse-integer token :junk-allowed nil)
    (parse-error ()
      (error "invalid layout integer ~S" token))))

(defun %parse-layout-ratio (token)
  (let ((slash (position #\/ token)))
    (unless slash
      (error "invalid layout ratio ~S" token))
    (let ((numerator (%parse-layout-integer (subseq token 0 slash)))
          (denominator (%parse-layout-integer (subseq token (1+ slash)))))
      (unless (and (plusp numerator)
                   (plusp denominator)
                   (< numerator denominator))
        (error "invalid layout ratio ~S" token))
      (/ numerator denominator))))

(defun %layout-token-end (body start)
  (or (position-if (lambda (character)
                     (find character ",;{}[]" :test #'char=))
                   body
                   :start start)
      (length body)))

(defun %parse-layout-node (body start panes-by-id)
  (labels ((token (from delimiter)
             (let ((end (position delimiter body :start from)))
               (unless end
                 (error "truncated layout string"))
               (values (subseq body from end) (1+ end))))
           (pane-for-id (id)
             (or (gethash id panes-by-id)
                 (error "layout references unknown pane ~D" id))))
    (multiple-value-bind (width-token after-width) (token start #\x)
      (multiple-value-bind (height-token after-height)
          (token after-width #\,)
        (multiple-value-bind (x-token after-x) (token after-height #\,)
          (let* ((y-end (%layout-token-end body after-x))
                 (y-token (subseq body after-x y-end))
                 (width (%parse-layout-integer width-token))
                 (height (%parse-layout-integer height-token))
                 (x (%parse-layout-integer x-token))
                 (y (%parse-layout-integer y-token)))
            (declare (ignore x y))
            (unless (and (plusp width) (plusp height))
              (error "layout dimensions must be positive"))
            (cond
              ((= y-end (length body))
               (error "layout leaf is missing its pane id"))
              ((member (char body y-end) '(#\{ #\[))
               (multiple-value-bind (first next)
                   (%parse-layout-node body (1+ y-end) panes-by-id)
                 (unless (and (< next (length body))
                              (member (char body next) '(#\, #\;)))
                   (error "layout split is missing its child separator"))
                 (multiple-value-bind (second after-second)
                     (%parse-layout-node body (1+ next) panes-by-id)
                   (let ((close (if (char= (char body y-end) #\{) #\} #\])))
                     (unless (and (< after-second (length body))
                                  (char= (char body after-second) close))
                       (error "layout split has an invalid closing delimiter"))
                     (values (make-layout-split
                              (if (char= (char body y-end) #\{) :h :v)
                              first
                              second
                              1/2)
                             (1+ after-second))))))
              ((char= (char body y-end) #\,)
               (let* ((ratio-start (1+ y-end))
                      (ratio-end (%layout-token-end body ratio-start))
                      (ratio-token (subseq body ratio-start ratio-end)))
                 (if (and (position #\/ ratio-token)
                          (< ratio-end (length body))
                          (member (char body ratio-end) '(#\{ #\[)))
                     (multiple-value-bind (first next)
                         (%parse-layout-node body (1+ ratio-end) panes-by-id)
                       (unless (and (< next (length body))
                                    (char= (char body next) #\;))
                         (error "layout split is missing its child separator"))
                       (multiple-value-bind (second after-second)
                           (%parse-layout-node body (1+ next) panes-by-id)
                         (let ((close (if (char= (char body ratio-end) #\{)
                                          #\}
                                          #\])))
                           (unless (and (< after-second (length body))
                                        (char= (char body after-second) close))
                             (error "layout split has an invalid closing delimiter"))
                           (values (make-layout-split
                                    (if (char= (char body ratio-end) #\{) :h :v)
                                    first
                                    second
                                    (%parse-layout-ratio ratio-token))
                                   (1+ after-second)))))
                     (let ((id (%parse-layout-integer ratio-token)))
                       (values (make-layout-leaf (pane-for-id id)) ratio-end)))))
              (t
               (let* ((id-end (%layout-token-end body (1+ y-end)))
                      (id-token (subseq body (1+ y-end) id-end))
                      (id (%parse-layout-integer id-token)))
                 (values (make-layout-leaf (pane-for-id id)) id-end))))))))))

(defun string->layout (layout-string panes)
  "Deserialize LAYOUT-STRING into a tree whose leaves refer to PANES by ID.
   The checksum and the pane-id set are validated before a tree is returned.
   Ratio-bearing splits use semicolons between child nodes; the legacy split
   format without a ratio remains readable as a 1/2 split."
  (unless (stringp layout-string)
    (error "layout string must be a string"))
  (let ((prefix-end (position #\, layout-string)))
    (unless (and prefix-end (= prefix-end 4))
      (error "layout string has no checksum"))
    (let ((checksum (subseq layout-string 0 prefix-end))
          (body (subseq layout-string (1+ prefix-end)))
          (panes-by-id (make-hash-table)))
      (unless (string-equal checksum (%layout-checksum body))
        (error "layout checksum mismatch"))
      (dolist (pane panes)
        (when (gethash (pane-id pane) panes-by-id)
          (error "duplicate pane id ~D" (pane-id pane)))
        (setf (gethash (pane-id pane) panes-by-id) pane))
      (multiple-value-bind (tree end) (%parse-layout-node body 0 panes-by-id)
        (unless (= end (length body))
          (error "trailing bytes in layout string"))
        (let ((tree-panes (layout-leaves tree)))
          (unless (and (= (length tree-panes) (length panes))
                       (every (lambda (pane)
                               (member pane tree-panes :test #'eq))
                              panes))
            (error "layout pane set does not match its pane records")))
        tree))))

(defun layout->string (window)
  "Serialize WINDOW's layout tree to a checksummed layout string.
   When WINDOW is zoomed, serialize its saved full tree. Split ratios are
   included explicitly and child nodes are separated so the result can be read
   back without guessing pane-id boundaries. Returns NIL when WINDOW has no
   tree."
  (let ((tree (or (and (nerimux/window:window-zoom-p window)
                     (nerimux/window:window-zoom-tree window))
                  (nerimux/window:window-tree window))))
    (when tree
      (let* ((body (%node->string tree))
             (checksum (%layout-checksum body)))
        (format nil "~A,~A" checksum body)))))
