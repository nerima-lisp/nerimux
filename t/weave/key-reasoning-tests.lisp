;;;; cl-weave specs for the cl-prolog-kit key-binding reasoning read-model.

(in-package #:nerimux/weave-tests)

(describe "nerimux key-binding reasoning"

  ;; Fixture: every `it' below runs with a private, freshly-projected rulebase
  ;; bound to *RULEBASE*.  around-each brackets the whole test, so the dynamic
  ;; binding is in force for the body and torn down afterwards.
  (around-each (next)
    (let ((*rulebase* (fresh-default-rulebase)))
      (funcall next)))

  (describe "projection"
    (it "projects the live key tables into non-empty facts"
      (let ((facts (fresh-default-snapshot)))
        (expect facts :to-satisfy #'consp)
        (expect (length facts) :to-be-greater-than 100)))

    (it "produces well-formed binding plists"
      (let ((fact (first (fresh-default-snapshot))))
        (expect (getf fact :table) :to-be-type-of 'string)
        (expect (member :command fact) :to-be-truthy))))

  (describe "direct lookup"
    (it "resolves a known prefix binding to its command"
      (expect (list *rulebase* nerimux/config:+table-prefix+ #\c)
              :to-resolve-to :new-window))

    (it "reports an unbound key as unbound"
      (expect (list *rulebase* nerimux/config:+table-prefix+ #\Z)
              :to-be-unbound))

    (it "proves a ground binding goal directly (custom :to-prove matcher)"
      (expect *rulebase*
              :to-prove (list 'binding nerimux/config:+table-prefix+ #\c :new-window))))

  (describe "reverse lookup"
    (it "finds every table/key that runs a command"
      (expect *rulebase* :to-run-command :new-window)
      (expect (keys-running *rulebase* :new-window)
              :to-contain-equal (cons nerimux/config:+table-prefix+ #\c)))

    (it "returns nothing for a command that is never bound"
      (expect (keys-running *rulebase* :this-command-does-not-exist)
              :to-be-null)))

  (describe "inference"
    (it "infers repeatable commands from repeatable bindings"
      (let ((commands (repeatable-commands *rulebase*)))
        (expect commands :to-satisfy #'consp)
        ;; resize-pane is bound repeatably in the default prefix table.
        (expect commands
                :to-satisfy
                (lambda (cs)
                  (some (lambda (c) (and (consp c) (equal (first c) "resize-pane")))
                        cs)))))

    (it "detects cross-table conflicts (copy-mode vs copy-mode-vi)"
      (let ((conflicts (binding-conflicts *rulebase*)))
        (expect conflicts :to-satisfy #'consp)
        (expect conflicts
                :to-satisfy
                (lambda (rows)
                  (some (lambda (row)
                          (equal (getf row :tables)
                                 (list nerimux/config:+table-copy-mode+
                                       nerimux/config:+table-copy-mode-vi+)))
                        rows)))))

    (it "lists bindings that shadow a root binding"
      ;; Shape check: every entry is a (table . key) cons with a non-root table.
      (dolist (entry (shadowing-bindings *rulebase*))
        (expect entry :to-satisfy #'consp)
        (expect (car entry) :not :to-equal nerimux/config:+table-root+)))

    (it "lists unique bindings via negation-as-failure, disjoint from shadowing-bindings"
      ;; unique-binding/2 is unique-binding(Table,Key) :- binding(Table,Key,_),
      ;; \+ binding(root,Key,_) — every non-root binding is either a shadow of a
      ;; root binding or unique; the two sets never overlap.
      (let ((shadowed (shadowing-bindings *rulebase*))
            (unique (unique-bindings *rulebase*)))
        (expect unique :to-satisfy #'consp)
        (dolist (entry unique)
          (expect entry :to-satisfy #'consp)
          (expect (car entry) :not :to-equal nerimux/config:+table-root+)
          (expect (member entry shadowed :test #'equal) :to-be-falsy)))))

  (describe "explanation"
    (it "explains a bound key as a readable string"
      (let ((text (explain-binding nerimux/config:+table-prefix+ #\c *rulebase*)))
        (expect text :to-be-type-of 'string)
        (expect text :to-contain "NEW-WINDOW")))

    (it "requires at least one assertion (expect-has-assertions demo)"
      (expect-has-assertions)
      (expect (explain-binding nerimux/config:+table-prefix+ #\Z *rulebase*)
              :to-contain "unbound")))

  ;; Property: every projected default binding must resolve back to exactly the
  ;; command it was projected from.  The generator draws real bindings from the
  ;; default snapshot; the rulebase is the fixture's *RULEBASE* (same tables).
  (it-property "every default binding round-trips through the rulebase"
      ((fact (gen-member (fresh-default-snapshot))))
    (expect (list *rulebase* (getf fact :table) (getf fact :key))
            :to-resolve-to (getf fact :command))))

;; Raw-query block through cl-prolog-kit's own cl-weave bridge: each spec builds a
;; fresh rulebase and asserts a literal Prolog query against it.  This is the
;; two libraries meeting — cl-prolog-kit/weave:deftest-queries emitting cl-weave
;; cases over a nerimux-derived rulebase.
(deftest-queries "raw prolog key-binding queries" ((fresh-default-rulebase))
  ("prefix c runs new-window"
   (binding "prefix" #\c :new-window) :succeeds)
  ("an unbound prefix key has no solution"
   (binding "prefix" #\Z ?command) :fails)
  ("new-window is reachable from some table/key"
   (binding ?table ?key :new-window) :succeeds)
  ("copy-mode and copy-mode-vi conflict on some key"
   (conflict ?key "copy-mode" ?command-1 "copy-mode-vi" ?command-2) :succeeds))


;;;; The second cold-path domain — command metadata — was removed with the
;;;; tmux command table it projected.  command-rulebase.lisp read
;;;; *COMMAND-USAGE-TABLE* out of the NERIMUX package by name; once
;;;; application/dispatch/ was deleted that find-symbol returned NIL and the
;;;; rulebase degraded to an empty table rather than erroring.  These tests are
;;;; what caught it.
