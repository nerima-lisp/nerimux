(in-package #:nerimux)

(defun %parse-session-component (target-string colon-pos dot-pos)
  "Derive the session component from TARGET-STRING given split positions.
   When a colon is present, the session is the text before it (possibly empty).
   When no colon is present, the session is the text before the dot (or the
   whole string when no dot is present either).
   Returns a non-empty string or NIL."
  (if colon-pos
      (nerimux/text:non-empty-string (subseq target-string 0 colon-pos))
      (nerimux/text:non-empty-string
       (if dot-pos
           (subseq target-string 0 dot-pos)
           target-string))))

(defun %parse-target (target-string)
  "Split TARGET-STRING into (values session-str window-str pane-str).
   Each value is NIL when the component is absent.
   Grammar: [SESSION][:WINDOW][.PANE]
   The SESSION portion is everything up to the first colon (if any).
   The WINDOW portion is between the first colon and the first dot (if any).
   The PANE portion is everything after the first dot.
   A BARE token (no ':' or '.') carrying an id sigil selects its component
   directly, using the position-independent id convention: %N → pane, @N →
   window ($N or a plain name → session).  Without this, `-t %2` / `-t @3`
   were mis-parsed as session names and silently fell back to the active
   object."
  (if (or (null target-string) (string= target-string ""))
      (values nil nil nil)
      (let* ((colon-pos (position #\: target-string))
             (dot-pos   (position #\. target-string :start (or colon-pos 0))))
        (if (and (null colon-pos) (null dot-pos))
            (case (char target-string 0)
              (#\% (values nil nil target-string))     ; %N → pane-id
              (#\@ (values nil target-string nil))     ; @N → window-id
              (t   (values target-string nil nil)))    ; $N session-id or plain name
            (let* ((win-raw  (cond
                               ((and colon-pos dot-pos)
                                (subseq target-string (1+ colon-pos) dot-pos))
                               (colon-pos
                                (subseq target-string (1+ colon-pos)))
                               (t nil)))
                   (pane-raw (when dot-pos
                               (subseq target-string (1+ dot-pos))))
                   (sess-str (%parse-session-component target-string colon-pos dot-pos)))
              (values sess-str (nerimux/text:non-empty-string win-raw) (nerimux/text:non-empty-string pane-raw)))))))

(defmacro define-target-lookup (name lambda-list &rest rules)
  "Generate a target lookup function NAME with LAMBDA-LIST.
   An optional docstring may appear as the first element of RULES.
   Each remaining RULE is either:
     (:nil-guard EXPR)  -- return NIL early when EXPR is NIL
     (TEST-EXPR)        -- return TEST-EXPR when it is non-NIL
   Rules are tried in order via a cond.  Returns NIL when no rule matches."
  (let* ((docstring
          (when (stringp (first rules))
            (first rules)))
         (actual-rules
          (if docstring
              (rest rules)
              rules)))
    `(defun ,name ,lambda-list
       ,@(when docstring
           (list docstring))
       (cond
         ,@(mapcar
            (lambda (rule)
              (if (eq (car rule) :nil-guard)
                  `((null ,(cadr rule)) nil)
                  `(,(car rule))))
            actual-rules)
         (t nil)))))

(defun %sigil-id (target-str sigil-char)
  "If TARGET-STR starts with SIGIL-CHAR, parse the rest as an integer.
   Returns the integer or NIL."
  (when (and (plusp (length target-str)) (char= (char target-str 0) sigil-char))
    (nerimux/text:parse-integer-or-nil (subseq target-str 1))))

(defun %name-prefix-p (prefix name)
  "T when NAME starts with PREFIX (both strings)."
  (and (>= (length name) (length prefix))
       (string= prefix name :end2 (min (length prefix) (length name)))))

(define-target-lookup find-session-by-target
                      (server target-str)
                      "Find a session in SERVER matching TARGET-STR.
   Rules: exact name, $N id, name prefix. Returns session or NIL."
                      (:nil-guard target-str)
                      ((cdr (assoc target-str server :test #'string=)))
                      ((let ((id (%sigil-id target-str #\$)))
                         (when id
                           (find id (mapcar #'cdr server) :key #'session-id))))
                      ((loop for (name . sess) in server
                             when (and (stringp name)
                                       (plusp (length name))
                                       (%name-prefix-p target-str name))
                               return sess)))

(define-target-lookup find-window-by-target
                      (session target-str)
                      "Find a window in SESSION matching TARGET-STR.
   Rules: exact name, @N id, numeric index, name prefix. Returns window or NIL."
                      (:nil-guard (and session target-str))
                      ((find target-str
                             (session-windows session)
                             :key
                             #'window-name
                             :test
                             #'string=))
                      ((let ((id (%sigil-id target-str #\@)))
                         (when id
                           (find id (session-windows session) :key #'window-id))))
                      ((let* ((wins (session-windows session))
                              (idx
                               (nerimux/text:parse-integer-or-nil target-str)))
                         (when (and idx (>= idx 0) (< idx (length wins)))
                           (nth idx wins))))
                      ((let ((wins (session-windows session)))
                         (loop for window in wins
                               when (%name-prefix-p target-str
                                                    (window-name window))
                                 return window))))

(define-target-lookup find-pane-by-target
                      (window target-str)
                      "Find a pane in WINDOW matching TARGET-STR.
   Rules: %N id, numeric index. Returns pane or NIL."
                      (:nil-guard (and window target-str))
                      ((let ((id (%sigil-id target-str #\%)))
                         (when id
                           (find id (window-panes window) :key #'pane-id))))
                      ((let* ((panes (window-panes window))
                              (idx
                               (nerimux/text:parse-integer-or-nil target-str)))
                         (when (and idx (>= idx 0) (< idx (length panes)))
                           (nth idx panes)))))
