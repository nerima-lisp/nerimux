(in-package #:nerimux/test)

(defun %file-text (path)
  "PATH's contents as a string.

   This used to live in the domain/format structural tests, which went with
   domain/format itself (R2). The three callers below were left behind, so this
   file referenced a function that no longer existed anywhere -- which would
   have taken the layering guard down with it, silently, since a guard that
   cannot load reports no violations rather than reporting a failure."
  (with-open-file (in path :external-format :utf-8)
    (let ((buffer (make-string (file-length in))))
      (subseq buffer 0 (read-sequence buffer in)))))

(defun %strip-lisp-comments (text)
  "TEXT with `;' comments blanked, so a package name mentioned in prose is not
   read as a declared dependency.  This matters: the very comment explaining why
   a :use clause was removed names the package it removed."
  (with-output-to-string (out)
    (dolist (line (uiop:split-string text :separator (list #\Newline)))
      (let ((semi (position #\; line)))
        (write-line
         (if semi
             (subseq line 0 semi)
             line)
         out)))))

(defun %package-declared-dependencies (text)
  "Parse TEXT (the contents of a package*.lisp file) into a list of
   (PACKAGE-NAME . DEPENDENCY-NAMES), reading only the clauses BEFORE (:export --
   i.e. :use and :import-from, the places a dependency is declared."
  (let ((clean (%strip-lisp-comments text))
        (result '())
        (start 0))
    (loop (let ((hit (search "(defpackage #:" clean :start2 start)))
            (unless hit
              (return))
            (let* ((name-start (+ hit (length "(defpackage #:")))
                   (name-end
                    (position-if
                     (lambda (c)
                       (member c '(#\Space #\Newline #\) #\Tab)))
                     clean
                     :start
                     name-start))
                   (name (subseq clean name-start name-end))
                   (next
                    (or (search "(defpackage #:" clean :start2 name-end)
                        (length clean)))
                   (body (subseq clean name-end next))
                   (head-end (or (search "(:export" body) (length body)))
                   (head (subseq body 0 head-end))
                   (deps '())
                   (from 0))
              (loop (let ((d (search "#:" head :start2 from)))
                      (unless d
                        (return))
                      (let ((e
                             (position-if
                              (lambda (c)
                                (member c '(#\Space #\Newline #\) #\Tab)))
                              head
                              :start
                              (+ d 2))))
                        (push (subseq head (+ d 2) e) deps)
                        (setf from (or e (length head))))))
              (push (cons name (nreverse deps)) result)
              (setf start name-end))))
    (nreverse result)))

(defun %layered-source-files ()
  "Every .lisp file that participates in the layering: src/ plus each unit's
   packages/<name>/src/.

   packages/<name>/tests/ is deliberately excluded.  A unit's test package
   declares no layer and legitimately reaches whatever it exercises, so
   including it would either force a meaningless marker onto every test package
   or report every test file as unplaceable.  This matches the pre-extraction
   behaviour, where tests/ was outside the scan for the same reason."
  (let ((root (asdf:system-source-directory :nerimux)))
    (append (directory (merge-pathnames #P"src/**/*.lisp" root))
            (directory (merge-pathnames #P"packages/*/src/**/*.lisp" root)))))

(defun %package-declaration-files ()
  "Every layered source file whose text contains a defpackage form, wherever in
   the tree it happens to live.  Package declarations happened to all sit under
   src/bootstrap/ when this scan was a fixed glob on src/bootstrap/package*.lisp;
   that stops being true once files start moving under packages/<name>/src/, so
   this asks each file itself rather than assuming a location."
  (remove-if-not
   (lambda (file)
     (search "(defpackage" (%file-text file)))
   (%layered-source-files)))

(defparameter *layer-name-rank*
  '(("FOUNDATION" . -1) ("DOMAIN" . 0)
                        ("APPLICATION" . 1)
                        ("INFRASTRUCTURE" . 2)
                        ("PRESENTATION" . 3)
                        ("BOOTSTRAP" . 4))
  "Layer marker word -> a 0..4 scale for domain..bootstrap (see
   %package-name->layer-rank, which projects a package name onto this same
   scale), extended with -1 for FOUNDATION so a foundation package can
   never rank above anything it is compared against.")

(defun %extract-documentation-string (defpackage-body)
  "DEFPACKAGE-BODY is the text of one defpackage form, from just after its
   name to just before the next defpackage.  Return the contents of its
   (:documentation \"...\") string, or NIL if it has none.  Scoped to the
   string itself, not the whole form: nerimux/model's defpackage carries a
   leading comment -- '... is the APPLICATION layer and this is DOMAIN ...',
   about nerimux/config -- that sits before nerimux/model's own
   documentation string starts.  A search over the whole body picks that
   comment's \"APPLICATION layer\" up as nerimux/model's own marker,
   misclassifying the aggregate root and hiding exactly the kind of
   reference this guard exists to catch."
  (let ((doc-kw (search "(:documentation" defpackage-body)))
    (when doc-kw
      (let ((open (position #\" defpackage-body :start doc-kw)))
        (when open
          (let ((j (1+ open))
                (len (length defpackage-body)))
            (loop while (< j len)
                  do (cond
                       ((char= (char defpackage-body j) #\\) (incf j 2))
                       ((char= (char defpackage-body j) #\") (return))
                       (t (incf j))))
            (subseq defpackage-body (1+ open) (min j len))))))))

(defun %package-name->layer-name ()
  "Package name -> layer marker word (the *layer-name-rank* scale), read
   from every defpackage's own documentation string, wherever in the tree
   that defpackage form lives -- see %package-declaration-files."
  (let ((result '()))
    (dolist (file (%package-declaration-files))
      (let* ((raw (%file-text file))
             (from 0))
        (loop (let ((hit (search "(defpackage #:" raw :start2 from)))
                (unless hit
                  (return))
                (let* ((name-start (+ hit (length "(defpackage #:")))
                       (name-end
                        (position-if
                         (lambda (c)
                           (member c '(#\Space #\Newline #\) #\Tab)))
                         raw
                         :start
                         name-start))
                       (name (subseq raw name-start name-end))
                       (next
                        (or (search "(defpackage #:" raw :start2 name-end)
                            (length raw)))
                       (doc
                        (%extract-documentation-string
                         (subseq raw name-end next)))
                       (marker
                        (and doc
                             (loop for (word . nil) in *layer-name-rank*
                                   for p = (search word doc)
                                   when p
                                     collect (cons p word) into hits
                                   finally (return
                                            (and hits
                                                 (cdr
                                                  (first
                                                   (sort hits #'< :key #'car)))))))))
                  (push (cons name marker) result)
                  (setf from name-end))))))
    result))

(defun %package-name->layer-rank ()
  "Package name -> the same 0..4 scale (-1 for FOUNDATION) *layer-rank* used
   to hardcode, but read from every defpackage's own documentation string
   via %package-name->layer-name instead of a maintained list.

   *layer-rank* was a fixed 16-entry table nobody kept in sync with the
   packages that exist: one entry (nerimux/model) named a package deleted
   outright in 3e00db6, and ten live packages -- nerimux/version and every
   nerimux/terminal/* sub-package, nerimux/workspace-model, nerimux/pane,
   nerimux/layout, nerimux/window, nerimux/session -- were simply absent.
   'no-package-declares-an-upward-layer-dependency' read it through
   `(when mine ...)' / `(when theirs ...)' guards, so a package missing from
   the table was skipped on BOTH sides of every edge it took part in: not
   under-tested, silently unreachable.  Today, nerimux/pane declaring
   `:use #:nerimux/renderer' would not be detected.

   This function makes that class of gap structurally impossible: every
   name it returns comes from a defpackage this build actually found, so
   there is no second, hand-maintained list to fall out of sync with the
   packages that exist."
  (mapcar
   (lambda (entry)
     (cons (car entry)
           (cdr (assoc (cdr entry) *layer-name-rank* :test #'string=))))
   (%package-name->layer-name)))

(defun %strip-lisp-source (text)
  "TEXT with `;' comments, `#| |#' nested block comments, string literals,
   and #\\x character literals all blanked to spaces, newlines kept so line
   numbers stay valid.  Deliberately a single pass rather than
   %strip-lisp-comments followed by a string-stripping pass:
   %strip-lisp-comments blanks from the first `;' on a line unconditionally,
   so a `;' inside a string literal -- ordinary prose, as in this very
   paragraph -- would truncate the string early and desynchronise every
   quote-parity check for the rest of the file.  A character literal is
   handled by unconditionally consuming exactly one character after #\\,
   which is what keeps #\\\" from being misread as opening a string."
  (let* ((len (length text))
         (out (make-string len :initial-element #\Space)))
    (labels ((keep-newlines (start end)
               (loop for k from start below
                     end
                     when (char= (char text k) #\Newline)
                       do (setf (char out k) #\Newline))))
      (let ((i 0))
        (loop while (< i len)
              do (let ((c (char text i)))
                   (cond
                     ((and (char= c #\#)
                           (< (1+ i) len)
                           (char= (char text (1+ i)) #\\))
                      (let ((lit-end (min len (+ i 3))))
                        (keep-newlines i lit-end)
                        (setf i lit-end)))
                     ((char= c #\;)
                      (let ((eol (or (position #\Newline text :start i) len)))
                        (keep-newlines i eol)
                        (setf i eol)))
                     ((and (char= c #\#)
                           (< (1+ i) len)
                           (char= (char text (1+ i)) #\|))
                      (let ((depth 1)
                            (j (+ i 2)))
                        (loop while (and (< j len) (plusp depth))
                              do (cond
                                   ((and (char= (char text j) #\#)
                                         (< (1+ j) len)
                                         (char= (char text (1+ j)) #\|))
                                     (incf depth)
                                     (incf j 2))
                                   ((and (char= (char text j) #\|)
                                         (< (1+ j) len)
                                         (char= (char text (1+ j)) #\#))
                                     (decf depth)
                                     (incf j 2))
                                   (t (incf j))))
                        (keep-newlines i j)
                        (setf i j)))
                     ((char= c #\")
                      (let ((j (1+ i)))
                        (loop while (< j len)
                              do (cond
                                   ((char= (char text j) #\\) (incf j 2))
                                   ((char= (char text j) #\")
                                     (incf j)
                                     (return))
                                   (t (incf j))))
                        (keep-newlines i j)
                        (setf i j)))
                     (t
                       (setf (char out i) c)
                       (incf i)))))))
    out))

(defun %package-name-char-p (c)
  (or (alpha-char-p c) (digit-char-p c) (char= c #\-) (char= c #\/)))

(defun %reference-boundary-char-p (c)
  (not (or (alphanumericp c) (member c '(#\- #\/ #\: #\#)))))

(defun %identifier-terminator-p (c)
  (member c
          '(#\Space #\Tab
                    #\Newline
                    #\Return
                    #\Linefeed
                    #\Page
                    #\(
                    #\)
                    #\"
                    #\;
                    #\'
                    #\`
                    #\,)))

(defun %scan-package-qualified-references (clean-text)
  "Every PKG::SYM or PKG:SYM reference in CLEAN-TEXT (already stripped by
   %strip-lisp-source) where PKG is `nerimux' or `nerimux/...'.  Returns a
   list of (line-number package-name qualifier symbol-name)."
  (let ((len (length clean-text))
        (refs '())
        (i 0))
    (loop while (< i len)
          do (if (and (char= (char clean-text i) #\n)
                      (or (zerop i)
                          (%reference-boundary-char-p (char clean-text (1- i))))
                      (<= (+ i 7) len)
                      (string= clean-text "nerimux" :start1 i :end1 (+ i 7)))
                 (let ((pkg-end (+ i 7)))
                   (loop while (and (< pkg-end len)
                                    (%package-name-char-p
                                     (char clean-text pkg-end)))
                         do (incf pkg-end))
                   (if (and (< pkg-end len)
                            (char= (char clean-text pkg-end) #\:))
                       (let* ((double
                               (and (< (1+ pkg-end) len)
                                    (char= (char clean-text (1+ pkg-end)) #\:)))
                              (sym-start
                               (+ pkg-end
                                  (if double
                                      2
                                      1))))
                         (if (and (< sym-start len)
                                  (not
                                   (%identifier-terminator-p
                                    (char clean-text sym-start)))
                                  (not (char= (char clean-text sym-start) #\:)))
                             (let ((sym-end sym-start))
                               (loop while (and (< sym-end len)
                                                (not
                                                 (%identifier-terminator-p
                                                  (char clean-text sym-end))))
                                     do (incf sym-end))
                               (push
                                (list (1+ (count #\Newline clean-text :end i))
                                      (subseq clean-text i pkg-end)
                                      (if double
                                          :double
                                          :single)
                                      (subseq clean-text sym-start sym-end))
                                refs)
                               (setf i sym-end))
                             (setf i (1+ pkg-end))))
                       (setf i pkg-end)))
                 (incf i)))
    (nreverse refs)))

(defun %file-in-package-name (text)
  "The package name TEXT's first (in-package ...) form switches into, or NIL
   if TEXT has no in-package form.  Handles both `#:' and bare `:' package
   designators: every ordinary source file in the tree writes
   (in-package #:nerimux/foo), but src/bootstrap/main-startup*.lisp writes
   the bare (in-package :nerimux) instead, and both forms put the name
   right after the first `:' following `(in-package' either way."
  (let ((hit (search "(in-package" text)))
    (when hit
      (let ((colon (position #\: text :start hit)))
        (when colon
          (let* ((name-start (1+ colon))
                 (name-end
                  (position-if
                   (lambda (c)
                     (member c '(#\Space #\Newline #\) #\Tab)))
                   text
                   :start
                   name-start)))
            (subseq text name-start name-end)))))))

(defun %file-layer-name (file pkg->layer)
  "FILE's layer marker word, derived from what FILE itself declares -- never
   from its path.  The previous implementation read the segment right after
   the nearest `src' path component (src/domain/... -> DOMAIN), which
   depended on every source file living under a layer-named directory.
   That stopped holding the moment a layer flattens to
   packages/<name>/src/*.lisp with no layer segment at all: the segment
   right after `src' becomes the bare filename, which matches none of the
   five layer directories, so every such file returned NIL here and was
   silently dropped by the caller's remove-if-not.  Nothing failed loudly;
   the guard just stopped looking at 131 of 160 files without saying so.

   FILE says what it is regardless of where it sits, so read that instead
   of the path:
   - An ordinary source file opens with (in-package ...); look up the
     package it switches into in PKG->LAYER, the same name -> marker table
     %package-name->layer-name builds from every defpackage's own
     documentation string.
   - A package-declaration file (bootstrap/package.lisp and its dozen
     siblings) has no in-package form of its own -- it defines the package,
     it does not enter it -- so fall back to the name its own defpackage
     form declares, and look THAT up in PKG->LAYER instead.  PKG->LAYER
     already carries a marker for it: %package-declaration-files finds this
     same file, and %package-name->layer-name reads the marker straight out
     of its documentation string.

   NIL only when FILE has neither form: not a layer directory it happens to
   fall outside of, but a source file this guard has no way to place at
   all.  The caller below treats that as a hard failure, not a silent
   omission -- see the conservation check there."
  (let* ((text (%file-text file))
         (own-package
          (or (%file-in-package-name text)
              (let ((hit (search "(defpackage #:" text)))
                (when hit
                  (let* ((name-start (+ hit (length "(defpackage #:")))
                         (name-end
                          (position-if
                           (lambda (c)
                             (member c '(#\Space #\Newline #\) #\Tab)))
                           text
                           :start
                           name-start)))
                    (subseq text name-start name-end)))))))
    (and own-package (cdr (assoc own-package pkg->layer :test #'string=)))))

(defun %find-module-components (system-name)
  "Return the direct component names of SYSTEM-NAME."
  (let ((system (asdf:find-system system-name nil)))
    (and system (mapcar #'asdf:component-name (asdf:component-children system)))))

(describe "system-composition-suite"


  (it "core-nerimux-does-not-declare-the-optional-kits"
    (let ((deps (mapcar (lambda (d) (string-downcase (princ-to-string d)))
                        (asdf:system-depends-on (asdf:find-system "nerimux")))))
      (expect (plusp (length deps)))
      (expect (member "cl-tty-kit" deps :test #'string=))
      (expect (null (member "cl-prolog-kit" deps :test #'string=)))
      (expect (null (member "cl-dataflow-kit" deps :test #'string=)))))


  (it "core-nerimux-load-does-not-intern-the-optional-kits"
    (expect (find-package "NERIMUX"))
    (expect (find-package "NERIMUX/TERMINAL"))
    (expect (null (find-package "CL-PROLOG-KIT")))
    (expect (null (find-package "CL-DATAFLOW-KIT"))))


  (it "renderer-workspace-loads-before-the-pane-compositor"
    (let* ((names (%find-module-components "nerimux-renderer"))
           (format-pos (position "renderer-format" names :test #'string=))
           (status-title-pos
             (position "renderer-workspace-status-title" names :test #'string=))
           (command-line-pos
             (position "renderer-workspace-command-line" names :test #'string=))
           (tree-pos (position "renderer-workspace-tree" names :test #'string=))
           (workspace-pos (position "renderer-workspace" names :test #'string=))
           (compose-pos (position "renderer-compose" names :test #'string=)))
      (expect (plusp (length names)))
      (expect format-pos)
      (expect status-title-pos)
      (expect command-line-pos)
      (expect tree-pos)
      (expect workspace-pos)
      (expect compose-pos)
      (expect (< format-pos status-title-pos command-line-pos tree-pos workspace-pos))
      (expect (< workspace-pos compose-pos))))

  (it "renderer-tui-kit-modules-load-in-dependency-order"
    (let* ((names (%find-module-components "nerimux-renderer"))
           (compose-pos (position "renderer-compose" names :test #'string=))
           (frame-grid-pos
             (position "renderer-tui-kit-frame-grid" names :test #'string=))
           (widgets-pos
             (position "renderer-tui-kit-widgets" names :test #'string=))
           (tui-kit-pos (position "renderer-tui-kit" names :test #'string=))
           (confirm-pos
             (position "renderer-tui-kit-confirm-view" names :test #'string=)))
      (expect (consp names))
      (expect compose-pos)
      (expect frame-grid-pos)
      (expect widgets-pos)
      (expect tui-kit-pos)
      (expect confirm-pos)
      (expect (< compose-pos frame-grid-pos widgets-pos tui-kit-pos confirm-pos))))

  (it "terminal-character-writing-modules-load-in-dependency-order"
    (let* ((names (%find-module-components "nerimux-terminal"))
           (definitions-pos
             (position "char-write-definitions" names :test #'string=))
           (cells-pos (position "char-write-cells" names :test #'string=))
           (flow-pos (position "char-write" names :test #'string=)))
      (expect (consp names))
      (expect definitions-pos)
      (expect cells-pos)
      (expect flow-pos)
      (expect (< definitions-pos cells-pos flow-pos))))

  (it "terminal-sgr-modules-load-in-dependency-order"
    (let* ((names (%find-module-components "nerimux-terminal"))
           (definitions-pos (position "sgr-definitions" names :test #'string=))
           (colors-pos (position "sgr-colors" names :test #'string=))
           (flow-pos (position "sgr" names :test #'string=))
           (report-pos (position "sgr-report" names :test #'string=)))
      (expect (consp names))
      (expect definitions-pos)
      (expect colors-pos)
      (expect flow-pos)
      (expect report-pos)
      (expect (< definitions-pos colors-pos flow-pos report-pos))))

  (it "no-package-declares-an-upward-layer-dependency"
    (let* ((pkg->rank (%package-name->layer-rank))
           (violations '())
           (edges 0))
      (dolist (file (%package-declaration-files))
        (dolist (entry (%package-declared-dependencies (%file-text file)))
          (let ((mine (cdr (assoc (car entry) pkg->rank :test #'string=))))
            (when mine
              (dolist (dep (cdr entry))
                (let ((theirs (cdr (assoc dep pkg->rank :test #'string=))))
                  (when theirs
                    (incf edges)
                    (when (> theirs mine)
                      (push (list (car entry) "->" dep) violations)))))))))
      (format t "~&no-package-declares-an-upward-layer-dependency: ranked ~d of ~d live package~:p~%"
              (length (remove-if-not #'cdr pkg->rank)) (length pkg->rank))
      (expect (plusp (length pkg->rank)))
      (expect (= (length pkg->rank) (length (remove-if-not #'cdr pkg->rank))))
      (expect (> edges 10))
      (expect (null violations))))


  (it "no-source-file-references-a-higher-layer-package"
    (let* ((root-dir (asdf:system-source-directory :nerimux))
           (pkg->layer (%package-name->layer-name))
           (all-files (%layered-source-files))
           (layered-files
             (remove-if-not (lambda (p) (%file-layer-name p pkg->layer)) all-files))
           (unplaceable-files
             (remove-if (lambda (p) (%file-layer-name p pkg->layer)) all-files))
           (violations '())
           (unclassified '())
           (total-refs 0))
      (dolist (file layered-files)
        (let* ((mine-name (%file-layer-name file pkg->layer))
               (mine-rank (cdr (assoc mine-name *layer-name-rank* :test #'string=)))
               (clean (%strip-lisp-source (%file-text file))))
          (dolist (ref (%scan-package-qualified-references clean))
            (destructuring-bind (line pkg qualifier symbol) ref
              (incf total-refs)
              (let ((theirs-name (cdr (assoc pkg pkg->layer :test #'string=))))
                (cond
                  ((null theirs-name)
                   (push (format nil "~a:~d  ~a~a~a  -- referenced package has no layer marker"
                                 (enough-namestring file root-dir) line pkg
                                 (if (eq qualifier :double) "::" ":") symbol)
                         unclassified))
                  ((> (cdr (assoc theirs-name *layer-name-rank* :test #'string=)) mine-rank)
                   (push (format nil "~a:~d  ~a~a~a  (file layer ~a -> reference layer ~a)"
                                 (enough-namestring file root-dir) line pkg
                                 (if (eq qualifier :double) "::" ":") symbol
                                 mine-name theirs-name)
                         violations))))))))
      (format t "~&no-source-file-references-a-higher-layer-package: examined ~d of ~d source file~:p~%"
              (length layered-files) (length all-files))
      (expect (plusp (length all-files)))
      (expect (null unplaceable-files))
      (expect (= (length layered-files) (length all-files)))
      (expect (> total-refs 100))
      (expect (null unclassified))
      (expect (null violations))))


  (it "nerimux-version-string-matches-asdf-version"
    (expect (string= (asdf:component-version (asdf:find-system "nerimux"))
                     (nerimux/version:version-string))))


  (it "the-runner-binds-print-circle"
    (expect *print-circle*))

  (it "a-cyclic-model-object-renders-without-exhausting-the-stack"
    (let ((organization (nerimux/workspace-model:make-organization :id "org" :name "org"))
          (repository (nerimux/workspace-model:make-repository :id "repo")))
      (nerimux/workspace-model:organization-add-repository organization repository)
      (expect (eq organization
                  (nerimux/workspace-model:repository-organization repository)))
      (expect (member repository
                      (nerimux/workspace-model:organization-repositories organization)
                      :test #'eq))
      (let ((rendered (let ((*print-pretty* t))
                        (format nil "~S" organization))))
        (expect (plusp (length rendered)))
        (expect (search "#1=" rendered))))))
