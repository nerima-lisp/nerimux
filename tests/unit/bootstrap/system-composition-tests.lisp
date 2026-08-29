(in-package #:nerimux/test)

;;;; ASDF system-composition tests.
;;;;
;;;; src/dataflow/ (nerimux/dataflow-model, cl-dataflow-kit) and src/reasoning/
;;;; (nerimux/reasoning, cl-prolog-kit) have both been deleted outright, along
;;;; with the optional systems that carried them -- neither appears in
;;;; nerimux.asd anymore.  The cl-prolog-kit and cl-dataflow-kit assertions
;;;; below therefore guard something stronger than a layering rule: that
;;;; neither kit reappears in the dependency closure at all, direct or
;;;; transitive.
;;;;
;;;; Nothing else in the suite would notice that regressing: re-adding either
;;;; kit to core :depends-on compiles clean, loads clean, and every other test
;;;; still passes.  These two checks are the only thing standing between that
;;;; edit and a silently re-bloated binary.

;;; ── Layering guard helpers ───────────────────────────────────────────────────

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

(defparameter *layer-rank*
  '(("nerimux/model" . 0) ("nerimux/terminal" . 0) ("nerimux/terminal/actions" . 0)
    ("nerimux/terminal/parser" . 0) ("nerimux/ports" . 0)
    ("nerimux/commands" . 1) ("nerimux/picker" . 1)
    ("nerimux/pty" . 2) ("nerimux/net" . 2) ("nerimux/protocol" . 2)
    ("nerimux/transport" . 2) ("nerimux/vcs" . 2)
    ("nerimux/renderer" . 3) ("nerimux/input" . 3)
    ("nerimux" . 4)
    ;; Below every layer, not above one: nothing declaring :use or
    ;; :import-from of nerimux/text can ever be an upward violation, so -1
    ;; is safe at any position in the comparison below.
    ("nerimux/text" . -1))
  "Package name -> layer index, lowest first.  Encodes the layer order stated in
   docs/src/reference/architecture.md: domain -> application -> infrastructure ->
   presentation -> bootstrap.")

(defun %strip-lisp-comments (text)
  "TEXT with `;' comments blanked, so a package name mentioned in prose is not
   read as a declared dependency.  This matters: the very comment explaining why
   a :use clause was removed names the package it removed."
  (with-output-to-string (out)
    (dolist (line (uiop:split-string text :separator (list #\Newline)))
      (let ((semi (position #\; line)))
        (write-line (if semi (subseq line 0 semi) line) out)))))

(defun %package-declared-dependencies (text)
  "Parse TEXT (the contents of a package*.lisp file) into a list of
   (PACKAGE-NAME . DEPENDENCY-NAMES), reading only the clauses BEFORE (:export --
   i.e. :use and :import-from, the places a dependency is declared."
  (let ((clean (%strip-lisp-comments text))
        (result '())
        (start 0))
    (loop
      (let ((hit (search "(defpackage #:" clean :start2 start)))
        (unless hit (return))
        (let* ((name-start (+ hit (length "(defpackage #:")))
               (name-end   (position-if (lambda (c) (member c '(#\Space #\Newline #\) #\Tab)))
                                        clean :start name-start))
               (name       (subseq clean name-start name-end))
               (next       (or (search "(defpackage #:" clean :start2 name-end)
                               (length clean)))
               (body       (subseq clean name-end next))
               (head-end   (or (search "(:export" body) (length body)))
               (head       (subseq body 0 head-end))
               (deps       '())
               (from       0))
          (loop
            (let ((d (search "#:" head :start2 from)))
              (unless d (return))
              (let ((e (position-if (lambda (c) (member c '(#\Space #\Newline #\) #\Tab)))
                                    head :start (+ d 2))))
                (push (subseq head (+ d 2) e) deps)
                (setf from (or e (length head))))))
          (push (cons name (nreverse deps)) result)
          (setf start name-end))))
    (nreverse result)))

;;; ── Source-text layering guard helpers ──────────────────────────────────────
;;;
;;; See the "source-text layering guard" comment in the describe block below
;;; for why these exist alongside the declaration-based helpers above.

(defparameter *layer-name-rank*
  '(("FOUNDATION" . -1) ("DOMAIN" . 0) ("APPLICATION" . 1)
    ("INFRASTRUCTURE" . 2) ("PRESENTATION" . 3) ("BOOTSTRAP" . 4))
  "Layer marker word -> the same 0..4 scale *layer-rank* uses for domain..
   bootstrap, extended with -1 for FOUNDATION so a foundation package can
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
          (let ((j (1+ open)) (len (length defpackage-body)))
            (loop while (< j len) do
              (cond
                ((char= (char defpackage-body j) #\\) (incf j 2))
                ((char= (char defpackage-body j) #\") (return))
                (t (incf j))))
            (subseq defpackage-body (1+ open) (min j len))))))))

(defun %package-name->layer-name ()
  "Package name -> layer marker word (the *layer-name-rank* scale), read
   from every defpackage's own documentation string in
   src/bootstrap/package*.lisp -- the same glob the declaration-based guard
   above reads."
  (let ((result '()))
    (dolist (file (directory
                   (merge-pathnames #P"src/bootstrap/package*.lisp"
                                    (asdf:system-source-directory :nerimux))))
      (let* ((raw (%file-text file))
             (from 0))
        (loop
          (let ((hit (search "(defpackage #:" raw :start2 from)))
            (unless hit (return))
            (let* ((name-start (+ hit (length "(defpackage #:")))
                   (name-end (position-if (lambda (c) (member c '(#\Space #\Newline #\) #\Tab)))
                                          raw :start name-start))
                   (name (subseq raw name-start name-end))
                   (next (or (search "(defpackage #:" raw :start2 name-end) (length raw)))
                   (doc  (%extract-documentation-string (subseq raw name-end next)))
                   (marker (and doc
                                (loop for (word . nil) in *layer-name-rank*
                                      for p = (search word doc)
                                      when p collect (cons p word) into hits
                                      finally (return (and hits (cdr (first (sort hits #'< :key #'car)))))))))
              (push (cons name marker) result)
              (setf from name-end))))))
    result))

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
               (loop for k from start below end
                     when (char= (char text k) #\Newline)
                     do (setf (char out k) #\Newline))))
      (let ((i 0))
        (loop while (< i len) do
          (let ((c (char text i)))
            (cond
              ((and (char= c #\#) (< (1+ i) len) (char= (char text (1+ i)) #\\))
               (let ((lit-end (min len (+ i 3))))
                 (keep-newlines i lit-end)
                 (setf i lit-end)))
              ((char= c #\;)
               (let ((eol (or (position #\Newline text :start i) len)))
                 (keep-newlines i eol)
                 (setf i eol)))
              ((and (char= c #\#) (< (1+ i) len) (char= (char text (1+ i)) #\|))
               (let ((depth 1) (j (+ i 2)))
                 (loop while (and (< j len) (plusp depth)) do
                   (cond
                     ((and (char= (char text j) #\#) (< (1+ j) len) (char= (char text (1+ j)) #\|))
                      (incf depth) (incf j 2))
                     ((and (char= (char text j) #\|) (< (1+ j) len) (char= (char text (1+ j)) #\#))
                      (decf depth) (incf j 2))
                     (t (incf j))))
                 (keep-newlines i j)
                 (setf i j)))
              ((char= c #\")
               (let ((j (1+ i)))
                 (loop while (< j len) do
                   (cond
                     ((char= (char text j) #\\) (incf j 2))
                     ((char= (char text j) #\") (incf j) (return))
                     (t (incf j))))
                 (keep-newlines i j)
                 (setf i j)))
              (t (setf (char out i) c) (incf i)))))))
    out))

(defun %package-name-char-p (c)
  (or (alpha-char-p c) (digit-char-p c) (char= c #\-) (char= c #\/)))

(defun %reference-boundary-char-p (c)
  (not (or (alphanumericp c) (member c '(#\- #\/ #\: #\#)))))

(defun %identifier-terminator-p (c)
  (member c '(#\Space #\Tab #\Newline #\Return #\Linefeed #\Page
              #\( #\) #\" #\; #\' #\` #\,)))

(defun %scan-package-qualified-references (clean-text)
  "Every PKG::SYM or PKG:SYM reference in CLEAN-TEXT (already stripped by
   %strip-lisp-source) where PKG is `nerimux' or `nerimux/...'.  Returns a
   list of (line-number package-name qualifier symbol-name)."
  (let ((len (length clean-text)) (refs '()) (i 0))
    (loop while (< i len) do
      (if (and (char= (char clean-text i) #\n)
               (or (zerop i) (%reference-boundary-char-p (char clean-text (1- i))))
               (<= (+ i 7) len)
               (string= clean-text "nerimux" :start1 i :end1 (+ i 7)))
          (let ((pkg-end (+ i 7)))
            (loop while (and (< pkg-end len) (%package-name-char-p (char clean-text pkg-end)))
                  do (incf pkg-end))
            (if (and (< pkg-end len) (char= (char clean-text pkg-end) #\:))
                (let* ((double (and (< (1+ pkg-end) len) (char= (char clean-text (1+ pkg-end)) #\:)))
                       (sym-start (+ pkg-end (if double 2 1))))
                  (if (and (< sym-start len)
                           (not (%identifier-terminator-p (char clean-text sym-start)))
                           (not (char= (char clean-text sym-start) #\:)))
                      (let ((sym-end sym-start))
                        (loop while (and (< sym-end len) (not (%identifier-terminator-p (char clean-text sym-end))))
                              do (incf sym-end))
                        (push (list (1+ (count #\Newline clean-text :end i))
                                    (subseq clean-text i pkg-end)
                                    (if double :double :single)
                                    (subseq clean-text sym-start sym-end))
                              refs)
                        (setf i sym-end))
                      (setf i (1+ pkg-end))))
                (setf i pkg-end)))
          (incf i)))
    (nreverse refs)))

(defun %relative-path-segments (path src-dir)
  (uiop:split-string (enough-namestring path src-dir) :separator (list #\/)))

(defun %file-layer-name (segments)
  "SEGMENTS is a file's path under src/, split on `/'.  Its layer marker
   word, or NIL if the first segment is not one of the five layer
   directories (see the guard's header comment).
   *layer-name-rank* maps NAME -> RANK, so the name itself comes back via
   the matched pair's CAR, not its CDR -- CDR is the rank integer, which is
   not a string designator and breaks every later (assoc ... :test #'string=)
   call downstream."
  (car (assoc (string-upcase (first segments)) *layer-name-rank* :test #'string=)))

(describe "system-composition-suite"

  ;;; -- declared dependencies ---------------------------------------------------

  ;; Catches the regression at its source: someone adding :cl-prolog-kit or
  ;; :cl-dataflow-kit back to core `nerimux''s :depends-on in nerimux.asd.
  ;; Checked against the declaration rather than the load, so it fires even if
  ;; load order happens to mask the effect.
  (it "core-nerimux-does-not-declare-the-optional-kits"
    (let ((deps (mapcar (lambda (d) (string-downcase (princ-to-string d)))
                        (asdf:system-depends-on (asdf:find-system "nerimux")))))
      ;; Guard against a vacuous pass: if the dependency list came back empty
      ;; the two assertions below would hold for the wrong reason.
      (expect (plusp (length deps)))
      (expect (member "cl-tty-kit" deps :test #'string=))
      (expect (null (member "cl-prolog-kit" deps :test #'string=)))
      (expect (null (member "cl-dataflow-kit" deps :test #'string=)))))

  ;;; -- resulting image ---------------------------------------------------------

  ;; Catches an accidental transitive pull-in that never appears in
  ;; :depends-on -- e.g. a future core dependency that itself requires one of
  ;; the kits.  This suite's own system depends only on ("nerimux" "cl-weave"),
  ;; so the running image is core plus the test framework and nothing else.
  (it "core-nerimux-load-does-not-intern-the-optional-kits"
    ;; Same vacuity guard: assert the packages that MUST be here are, so an
    ;; empty or half-loaded image cannot pass by absence.
    (expect (find-package "NERIMUX"))
    (expect (find-package "NERIMUX/TERMINAL"))
    (expect (null (find-package "CL-PROLOG-KIT")))
    (expect (null (find-package "CL-DATAFLOW-KIT"))))

  ;;; -- renderer load order -----------------------------------------------------
  ;;;
  ;;; Be precise about what this proves.  It asserts the DECLARED component
  ;;; order in nerimux.asd, nothing stronger.  The workspace tree projection
  ;;; and frame depend on renderer-format.lisp and on none of the pane
  ;;; compositor; loading them ahead of that chain is how the .asd
  ;;; states it, and this catches someone quietly reordering it back -- the
  ;;; likely regression, since "move the file next to renderer-compose" looks
  ;;; tidy.
  ;;;
  ;;; It does NOT prove the two paths are independent, and must not be cited as
  ;;; if it did.  They share one package and one system, so nothing stops
  ;;; workspace code calling a pane-compositor function; SBCL would emit a
  ;;; style-warning for the forward reference and this build does not treat
  ;;; style-warnings as fatal.  Proving independence needs the file-level
  ;;; closure computed from the render entry points, which is a review-time
  ;;; analysis rather than something a unit test can hold.

  (it "renderer-workspace-loads-before-the-pane-compositor"
    ;; The module path is ("src" "presentation/renderer"): nerimux.asd nests every
    ;; module under a single "src" module, so the one-element path returns NIL.
    (let* ((module (asdf:find-component (asdf:find-system "nerimux")
                                        '("src" "presentation/renderer")))
           (names  (mapcar #'asdf:component-name
                           (asdf:component-children module)))
           (format-pos (position "renderer-format" names :test #'string=))
           (status-title-pos
             (position "renderer-workspace-status-title" names :test #'string=))
           (command-line-pos
             (position "renderer-workspace-command-line" names :test #'string=))
           (tree-pos (position "renderer-workspace-tree" names :test #'string=))
           (workspace-pos (position "renderer-workspace" names :test #'string=))
           (compose-pos (position "renderer-compose" names :test #'string=)))
      ;; Vacuity guard: a typo'd module path returns NIL children, and every
      ;; position below would then be NIL rather than wrong.
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
    (let* ((module (asdf:find-component (asdf:find-system "nerimux")
                                        '("src" "presentation/renderer")))
           (names (mapcar #'asdf:component-name
                          (asdf:component-children module)))
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
    (let* ((module (asdf:find-component (asdf:find-system "nerimux")
                                        '("src" "domain/terminal")))
           (names (mapcar #'asdf:component-name
                          (asdf:component-children module)))
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
    (let* ((module (asdf:find-component (asdf:find-system "nerimux")
                                        '("src" "domain/terminal")))
           (names (mapcar #'asdf:component-name
                          (asdf:component-children module)))
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

  ;;; -- layering -----------------------------------------------------------
  ;;;
  ;;; Nothing enforced the layer order, and three violations had accumulated
  ;;; unnoticed: nerimux/model :use'd nerimux/config, which made every
  ;;; domain->application reference UNQUALIFIED and therefore invisible to a
  ;;; search for "nerimux/config:".  They surfaced only when someone read the
  ;;; defpackage forms directly.
  ;;;
  ;;; Be precise about the reach.  This reads DECLARATIONS, not the call graph:
  ;;; it catches a package declaring an upward :use or :import-from, which is
  ;;; what re-opens the invisible-reference hole.  It does NOT catch one
  ;;; qualified upward reference inside a function body -- that stays a
  ;;; review-time check, and is at least greppable.
  (it "no-package-declares-an-upward-layer-dependency"
    (let ((violations '())
          (edges 0))
      (dolist (file (directory
                     (merge-pathnames #P"src/bootstrap/package*.lisp"
                                      (asdf:system-source-directory :nerimux))))
        (dolist (entry (%package-declared-dependencies (%file-text file)))
          (let ((mine (cdr (assoc (car entry) *layer-rank* :test #'string=))))
            (when mine
              (dolist (dep (cdr entry))
                (let ((theirs (cdr (assoc dep *layer-rank* :test #'string=))))
                  (when theirs
                    (incf edges)
                    (when (> theirs mine)
                      (push (list (car entry) "->" dep) violations)))))))))
      ;; Vacuity guard: a parser that matched nothing reports no violations.
      (expect (> edges 10))
      (expect (null violations))))

  ;;; -- source-text layering guard -----------------------------------------
  ;;;
  ;;; The guard above reads DECLARATIONS: a package's own :use and
  ;;; :import-from clauses.  A reference written PKG::SYM or PKG:SYM inside a
  ;;; function body names no :use, so it appears in no defpackage form and the
  ;;; declaration scan cannot see it; double-colon additionally bypasses the
  ;;; export list.  Four such references had accumulated by 2026-08-20 -- an
  ;;; audit found them while the test above stayed green -- each reaching from
  ;;; a lower layer up into BOOTSTRAP: NERIMUX::%PARSE-INTEGER-OR-NIL,
  ;;; NERIMUX::%JOIN-THREAD-WITH-TIMEOUT, NERIMUX::SERVER-FIND-SESSION, and
  ;;; NERIMUX::*CLOCK-MODE-PANE-ID*.
  ;;;
  ;;; This guard scans the SOURCE TEXT of every file under src/ instead of any
  ;;; defpackage form.  It derives a FILE's layer from its path
  ;;; (src/domain/... -> DOMAIN, src/application/... -> APPLICATION, and so
  ;;; on -- a file outside the five layer directories matches none of them
  ;;; and is skipped).  It derives a referenced PACKAGE's layer from the
  ;;; first layer marker inside that
  ;;; package's own (:documentation ...) string in
  ;;; src/bootstrap/package*.lisp: "DOMAIN layer", "APPLICATION layer",
  ;;; "INFRASTRUCTURE layer", "PRESENTATION layer", "BOOTSTRAP layer", or
  ;;; "FOUNDATION" for nerimux/text, which sits below every layer by design
  ;;; and may be referenced from anywhere.  Every one of the 29 defpackage
  ;;; forms in src/bootstrap/package*.lisp carries exactly one such marker in
  ;;; its documentation string, so this is a complete mapping, not a
  ;;; hand-maintained subset -- unlike *layer-rank* above, which several
  ;;; terminal sub-packages and nerimux/version are missing from.
  ;;;
  ;;; A file whose layer is strictly lower than a referenced package's layer
  ;;; is an upward reference, full stop.  Whether the symbol is exported is a
  ;;; separate, unrelated concern this guard does not check: a downward or
  ;;; same-layer double-colon reference (nerimux/model::%shell-basename from
  ;;; src/bootstrap/, say) is legal direction and must not fail here.

  (it "no-source-file-references-a-higher-layer-package"
    (let* ((src-dir (merge-pathnames #P"src/" (asdf:system-source-directory :nerimux)))
           (pkg->layer (%package-name->layer-name))
           (all-files (directory (merge-pathnames #P"src/**/*.lisp"
                                                   (asdf:system-source-directory :nerimux))))
           (layered-files
             (remove-if-not (lambda (p) (%file-layer-name (%relative-path-segments p src-dir)))
                            all-files))
           (violations '())
           (unclassified '())
           (total-refs 0))
      (dolist (file layered-files)
        (let* ((mine-name (%file-layer-name (%relative-path-segments file src-dir)))
               (mine-rank (cdr (assoc mine-name *layer-name-rank* :test #'string=)))
               (clean (%strip-lisp-source (%file-text file))))
          (dolist (ref (%scan-package-qualified-references clean))
            (destructuring-bind (line pkg qualifier symbol) ref
              (incf total-refs)
              (let ((theirs-name (cdr (assoc pkg pkg->layer :test #'string=))))
                (cond
                  ;; A referenced nerimux-family package absent from every
                  ;; documentation string cannot be placed in the layer
                  ;; order; report it rather than silently treating it as
                  ;; legal, so a future package added without a marker
                  ;; cannot become a blind spot the way :: was.
                  ((null theirs-name)
                   (push (format nil "~a:~d  ~a~a~a  -- referenced package has no layer marker"
                                 (enough-namestring file src-dir) line pkg
                                 (if (eq qualifier :double) "::" ":") symbol)
                         unclassified))
                  ((> (cdr (assoc theirs-name *layer-name-rank* :test #'string=)) mine-rank)
                   (push (format nil "~a:~d  ~a~a~a  (file layer ~a -> reference layer ~a)"
                                 (enough-namestring file src-dir) line pkg
                                 (if (eq qualifier :double) "::" ":") symbol
                                 mine-name theirs-name)
                         violations))))))))
      ;; Vacuity guards: a scan that walked no files, or matched no
      ;; references, would report zero violations for the wrong reason.
      (expect (> (length layered-files) 50))
      (expect (> total-refs 100))
      (expect (null unclassified))
      (expect (null violations))))

  ;;; -- version string --------------------------------------------------------
  ;;;
  ;;; nerimux.asd's :version comment calls itself "Single source of truth for
  ;;; the version: flake.nix reads this form and release.yml refuses to
  ;;; publish a tag that disagrees with it" -- but nothing previously checked
  ;;; it against nerimux/version:version-string, the literal every runtime
  ;;; reporter (-V, the cl-cli option spec, XTVERSION/DA3, #{version}) actually
  ;;; returns. The two had drifted silently to "0.3.0" vs "0.1.0" before this
  ;;; test existed.

  (it "nerimux-version-string-matches-asdf-version"
    (expect (string= (asdf:component-version (asdf:find-system "nerimux"))
                     (nerimux/version:version-string))))

  ;;; -- the reporter can print the domain model --------------------------------
  ;;;
  ;;; These two guard the runner's *PRINT-CIRCLE* binding (tests/suite.lisp).
  ;;; Without it, a failed assertion whose ACTUAL value is any linked model
  ;;; object sends SBCL's structure pretty printer into unbounded recursion and
  ;;; kills the process mid-report -- so instead of one red test, the run
  ;;; produces no results at all and every other test's outcome is lost.
  ;;;
  ;;; The ordering matters: the binding check below fails CLEANLY if someone
  ;;; removes the binding, which is the signal we want.  The render check that
  ;;; follows it proves the actual behaviour, but can only ever be reached
  ;;; while the binding is in place -- a regression that got past the first
  ;;; check would take the process down here rather than report.  That is
  ;;; precisely why the cheap canary comes first.

  (it "the-runner-binds-print-circle"
    (expect *print-circle*))

  (it "a-cyclic-model-object-renders-without-exhausting-the-stack"
    (let ((organization (nerimux/model:make-organization :id "org" :name "org"))
          (repository (nerimux/model:make-repository :id "repo")))
      (nerimux/model:organization-add-repository organization repository)
      ;; Pin the cycle itself: without this the render below would prove
      ;; nothing, because a non-cyclic structure prints fine either way.
      (expect (eq organization
                  (nerimux/model:repository-organization repository)))
      (expect (member repository
                      (nerimux/model:organization-repositories organization)
                      :test #'eq))
      ;; ~S with the pretty printer on is exactly how a reporter renders a
      ;; failed assertion's value.
      (let ((rendered (let ((*print-pretty* t))
                        (format nil "~S" organization))))
        (expect (plusp (length rendered)))
        ;; #N= is the circular-reference label: its presence is what
        ;; distinguishes "cycle detected and rendered" from "happened not to
        ;; recurse", so this asserts the mechanism, not just survival.
        (expect (search "#1=" rendered))))))
