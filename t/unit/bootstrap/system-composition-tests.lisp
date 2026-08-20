(in-package #:nerimux/test)

;;;; ASDF system-composition tests.
;;;;
;;;; src/dataflow/ is a cold-path read-model with no call site anywhere in src/
;;;; outside its own directory.  It was moved out of core `nerimux' into the
;;;; optional `nerimux/dataflow-model' system so that cl-dataflow-kit stops
;;;; riding along in the shipped binary's dependency closure.
;;;;
;;;; Its counterpart, `nerimux/reasoning' (cl-prolog-kit, over src/reasoning/),
;;;; has since been deleted outright -- it projected the config key-table store,
;;;; and that store went when nothing was left to read it.  The cl-prolog-kit
;;;; assertions below therefore now guard something stronger than a layering
;;;; rule: that kit should not reappear in the closure at all.
;;;;
;;;; Nothing else in the suite would notice that regressing: re-adding either
;;;; kit to core :depends-on compiles clean, loads clean, and every other test
;;;; still passes.  These two checks are the only thing standing between that
;;;; edit and a silently re-bloated binary.

;;; ── Layering guard helpers ───────────────────────────────────────────────────

(defparameter *layer-rank*
  '(("nerimux/model" . 0) ("nerimux/terminal" . 0) ("nerimux/terminal/actions" . 0)
    ("nerimux/terminal/parser" . 0) ("nerimux/options" . 0) ("nerimux/buffer" . 0)
    ("nerimux/hooks" . 0) ("nerimux/format" . 0) ("nerimux/ports" . 0)
    ("nerimux/repository" . 0) ("nerimux/persistence" . 0)
    ("nerimux/config" . 1) ("nerimux/commands" . 1) ("nerimux/picker" . 1)
    ("nerimux/pty" . 2) ("nerimux/net" . 2) ("nerimux/protocol" . 2)
    ("nerimux/transport" . 2) ("nerimux/vcs" . 2)
    ("nerimux/renderer" . 3) ("nerimux/prompt" . 3) ("nerimux/input" . 3)
    ("nerimux" . 4))
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
  ;;; order in nerimux.asd, nothing stronger.  The workspace views
  ;;; (renderer-workspace.lisp) depend on renderer-format.lisp and on none of
  ;;; the pane compositor; loading them ahead of that chain is how the .asd
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
           (format-pos    (position "renderer-format"    names :test #'string=))
           (workspace-pos (position "renderer-workspace" names :test #'string=))
           (compose-pos   (position "renderer-compose"   names :test #'string=)))
      ;; Vacuity guard: a typo'd module path returns NIL children, and every
      ;; position below would then be NIL rather than wrong.
      (expect (plusp (length names)))
      (expect format-pos)
      (expect workspace-pos)
      (expect compose-pos)
      (expect (< format-pos workspace-pos))
      (expect (< workspace-pos compose-pos))))

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
      (expect (null violations)))))
