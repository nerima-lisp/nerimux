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
      (expect (< workspace-pos compose-pos)))))
