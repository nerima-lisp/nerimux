(in-package #:nerimux/test)

;;;; ASDF system-composition tests.
;;;;
;;;; src/reasoning/ and src/dataflow/ are cold-path read-models with no call
;;;; site anywhere in src/ outside their own directories.  They were moved out
;;;; of core `nerimux' into the optional `nerimux/reasoning' and
;;;; `nerimux/dataflow-model' systems so that cl-prolog-kit and cl-dataflow-kit
;;;; stop riding along in the shipped binary's dependency closure.
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
    (expect (null (find-package "CL-DATAFLOW-KIT")))))
