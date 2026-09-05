(in-package #:nerimux/commands)

(defun %copy-mode-make-matcher (term)
  "Return a matcher closure (row-string start) → match-start-column (or NIL).
   TERM is compiled as a cl-regex-kit regex; on compile failure falls back to
   literal substring search so terms with unbalanced metacharacters still work.

   :OCTAL NIL because TERM is whatever the user typed at the copy-mode / prompt.
   Under cl-regex-kit's :OCTAL T default a typed `\\1` compiles to U+0001 and
   silently matches nothing; refused, it takes the literal-substring branch
   below, which is the useful answer for someone searching for the text `\\1`.

   RENDERER-PANE-SEARCH.LISP's %ALL-MATCH-RANGES MUST KEEP THE SAME OPTIONS.
   That function decides independently whether the same TERM is a valid regex,
   and it is what paints the highlight.  If the two disagree, n/N jumps to
   matches that are not highlighted, or highlights spans the cursor never visits.

   SCAN returns a MATCH-RESULT struct, not cl-ppcre's four values, so the start
   column is read back with MATCH-START rather than taken as the first value."
  (let ((scanner
         (handler-case (cl-regex-kit:compile-regex term :octal nil)
           (cl-regex-kit:regex-syntax-error ()
             nil))))
    (if scanner
        (lambda (str start)
          (let ((match (cl-regex-kit:scan scanner str :start start)))
            (and match (cl-regex-kit:match-start match))))
        (lambda (str start)
          (search term str :start2 start)))))

(defun %copy-mode-find-forward (screen term start-vrow start-col)
  "Scan forward through the full virtual buffer from (START-VROW, START-COL).
   Returns (values vrow col) of the first match, or (values nil nil) when absent."
  (let ((total (%copy-mode-total-rows screen))
        (match (%copy-mode-make-matcher term)))
    (loop for vrow from start-vrow below total
          for row-str = (%copy-mode-virtual-row-string screen vrow)
          for from-col = (if (= vrow start-vrow)
                             start-col
                             0)
          for pos = (and (<= from-col (length row-str))
                         (funcall match row-str from-col))
          when pos
            return (values vrow pos)
          finally (return (values nil nil)))))

(defun %copy-mode-find-backward (screen term start-vrow start-col)
  "Scan backward through the full virtual buffer from (START-VROW, START-COL).
   Within a row takes the LAST match whose start is strictly < START-COL (cursor-adjacent).
   Returns (values vrow col) or (values nil nil)."
  (let ((match (%copy-mode-make-matcher term)))
    (loop for vrow from start-vrow downto 0
          for row-str = (%copy-mode-virtual-row-string screen vrow)
          for end-col = (if (= vrow start-vrow) start-col (length row-str))
          for best = (loop with b = nil and from = 0
                           for pos = (and (<= from (length row-str))
                                          (funcall match row-str from))
                           if (or (null pos) (>= pos end-col)) return b
                           else do (setf b pos from (1+ pos)))
          when best return (values vrow best)
          finally (return (values nil nil)))))

(defun %copy-mode-wrap-start (forwardp screen)
  "The (vrow col) a wrapped search restarts from: the top-left corner when
   searching FORWARDP, otherwise the bottom-right corner of the virtual buffer."
  (if forwardp
      (values 0 0)
      (values (1- (%copy-mode-total-rows screen)) (screen-width screen))))

(defun %search-with-wrap (finder screen
                                 term
                                 start-vrow
                                 start-col
                                 wrap-start-fn
                                 found-k)
  "Continuation-passing search engine shared by every copy-mode search.
   Run FINDER at (START-VROW, START-COL); on a miss, retry once from the
   position (funcall WRAP-START-FN) returns.  Invoke the success continuation
   FOUND-K with the hit's (vrow col) on the first match and return T; return
   NIL on a total miss.  The caller supplies FOUND-K, so this engine never
   touches screen cursor state itself."
  (flet ((attempt (vrow col)
           (multiple-value-bind (found-vrow found-col) 
               (funcall finder screen term vrow col)
             (and found-vrow
                  (progn
                    (funcall found-k found-vrow found-col)
                    t)))))
    (or (attempt start-vrow start-col)
        (multiple-value-bind (wrap-vrow wrap-col) (funcall wrap-start-fn)
          (attempt wrap-vrow wrap-col)))))

(defun %copy-mode-all-matches (screen term)
  "Every match for TERM in the virtual buffer, as (VROW . COL) in buffer order.

   Uses %COPY-MODE-MAKE-MATCHER, so this census and the n/N cursor agree on what
   counts as a match. A separate matcher here would produce a total that
   disagrees with the positions the user can actually reach."
  (let ((match (%copy-mode-make-matcher term))
        (total (%copy-mode-total-rows screen))
        (found '()))
    (dotimes (vrow total (nreverse found))
      (let ((row-str (%copy-mode-virtual-row-string screen vrow)))
        (loop with from = 0
              for pos = (and (<= from (length row-str))
                             (funcall match row-str from))
              while pos
              do (push (cons vrow pos) found)
                 (setf from (1+ pos)))))))

(defun %copy-mode-record-search-position (screen term vrow col)
  "Record which match of TERM the cursor now sits on, and how many exist."
  (let* ((matches (%copy-mode-all-matches screen term))
         (index
          (position-if
           (lambda (m)
             (and (= (car m) vrow) (= (cdr m) col)))
           matches)))
    (setf (screen-copy-search-total screen) (length matches)
          (screen-copy-search-index screen) (and index (1+ index)))))

(defun %copy-mode-clear-search-position (screen)
  "Forget the match census (leaving copy mode, or a search that found nothing)."
  (setf (screen-copy-search-index screen) nil
        (screen-copy-search-total screen) 0))

(defun %copy-mode-search-direction (screen term direction &optional (save-direction-p t))
  "Shared search engine for copy-mode-search-{forward,backward}.
   DIRECTION is :forward or :backward.  Saves TERM; always wraps around the
   buffer ends.
   Forward starts one past the cursor col; backward starts at the cursor col.
   When SAVE-DIRECTION-P (the default for / and ?), records DIRECTION as the
   last-search direction; n/N pass NIL so a repeat does not overwrite the
   original heading."
  (when (and (screen-copy-mode-p screen) term (plusp (length term)))
    (setf (screen-copy-search-term screen) term)
    (when save-direction-p
      (setf (screen-copy-search-direction screen) direction))
    (let* ((cursor     (or (screen-copy-cursor screen) (cons 0 0)))
           (start-vrow (%copy-mode-cursor-vrow screen))
           (forwardp   (eq direction :forward))
           (finder     (if forwardp #'%copy-mode-find-forward #'%copy-mode-find-backward))
           (start-col  (if forwardp (1+ (cdr cursor)) (cdr cursor))))
      (or (%search-with-wrap
           finder screen term start-vrow start-col
           (lambda () (%copy-mode-wrap-start forwardp screen))
           (lambda (found-vrow found-col)
             (%copy-mode-set-virtual-row screen found-vrow found-col)
             (%copy-mode-record-search-position screen term found-vrow found-col)))
          (progn (%copy-mode-clear-search-position screen) nil)))))

(defun copy-mode-search-forward (screen term)
  "Search forward from the current cursor for TERM through the full scrollback + live grid.
   Saves TERM for n/N repeats.  Always wraps to top of the buffer."
  (%copy-mode-search-direction screen term :forward))

(defun copy-mode-search-backward (screen term)
  "Search backward from the current cursor for TERM through the full scrollback + live grid.
   Saves TERM for n/N repeats.  Always wraps to bottom of the buffer."
  (%copy-mode-search-direction screen term :backward))

(defun copy-mode-search-next (screen)
  "Repeat the last search in its ORIGINAL direction (vi n): forward when the last
   / search went forward, backward when the last ? search went backward.  Does
   not change the stored direction, so a run of n keeps the same heading."
  (when (screen-copy-mode-p screen)
    (let ((term (screen-copy-search-term screen)))
      (when term
        (%copy-mode-search-direction screen
                                     term
                                     (or (screen-copy-search-direction screen)
                                         :forward)
                                     nil)))))

(defun copy-mode-search-prev (screen)
  "Repeat the last search in the OPPOSITE of its original direction (vi N).
   Does not change the stored direction, so n and N stay relative to the same / ?
   heading across repeats."
  (when (screen-copy-mode-p screen)
    (let ((term (screen-copy-search-term screen)))
      (when term
        (%copy-mode-search-direction screen
                                     term
                                     (if (eq
                                          (or
                                           (screen-copy-search-direction screen)
                                           :forward)
                                          :forward)
                                         :backward
                                         :forward)
                                     nil)))))
