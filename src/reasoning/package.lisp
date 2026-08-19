;;;; Package for the Prolog-backed key-binding reasoning read-model.
;;;;
;;;; This subsystem is an *additive* introspection layer built on the
;;;; dependency-free `cl-prolog-kit' engine.  It projects nerimux's live
;;;; key-table store into a Prolog rulebase and answers relational
;;;; questions about it that the imperative store cannot express directly
;;;; (reverse lookup, cross-table conflicts, repeatable-command inference).
;;;;
;;;; It ships as the OPTIONAL `nerimux/reasoning' ASDF system, not as part of
;;;; core `nerimux' -- nothing in src/ outside this directory calls it, so
;;;; loading it into core pulled cl-prolog-kit into the shipped binary for no
;;;; runtime benefit.  The system depends on the whole of `nerimux' because it
;;;; reads nerimux/config's key-table helpers and reaches *COMMAND-USAGE-TABLE*
;;;; out of the NERIMUX package by name; see the comment on the defsystem.
;;;;
;;;; `\=', `\+', and `findall' are imported from cl-prolog-kit: builtin goals
;;;; dispatch on symbol identity, so inequality/negation/collection goals in
;;;; clause data must reference the engine's own symbols, whereas the domain
;;;; predicates below are ordinary symbols owned by this package.
;;;; (cl-prolog-kit's SETOF/3 was tried here and reverted — see the note above
;;;; REPEATABLE-COMMANDS in key-rulebase.lisp: its term-ordering comparator
;;;; can't sort raw Lisp strings, which this domain's command/table names
;;;; are built from. FINDALL/3 does not sort or dedupe internally, so it has
;;;; no such limitation — %FINDALL below is the shared query helper built on
;;;; it.)

(defpackage #:nerimux/reasoning
  (:use #:cl)
  (:import-from #:cl-prolog-kit #:|\\=| #:|\\+| #:findall)
  (:import-from #:nerimux/config #:key-display-string)
  (:documentation
   "A cl-prolog-kit read-model over nerimux key tables: projection, a small
    rule set, and query helpers for binding introspection.")
  (:export
   ;; Projection + rulebase construction
   #:snapshot-key-bindings
   #:build-key-rulebase
   #:current-key-rulebase
   ;; Query helpers (return Lisp values, not raw solutions)
   #:key-command
   #:keys-running
   #:repeatable-commands
   #:binding-conflicts
   #:shadowing-bindings
   #:unique-bindings
   #:explain-binding
   ;; Command-metadata read-model (second cold-path domain)
   #:build-command-rulebase
   #:current-command-rulebase
   #:command-usage-facts
   #:command-accepts-flag-p
   #:commands-with-flag
   #:flags-of-command
   #:scriptable-commands
   ;; Prolog query vocabulary — the predicate symbols used inside the
   ;; rulebase, exported so callers (and tests) can pose raw queries.
   #:binding
   #:repeatable
   #:note
   #:conflict
   #:shadows-root
   #:repeatable-command
   #:unique-binding
   #:command
   #:usage
   #:accepts-flag
   #:scriptable))
