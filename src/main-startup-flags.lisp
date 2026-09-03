(in-package :nerimux)

(defparameter *cli-app*
  (cl-cli:make-app
   :name "nerimux"
   :summary "A workspace multiplexer for git worktrees."
   :auto-help nil
   :global-options
   (list
         (cl-cli:make-option :name "version" :short #\V :kind :flag :key :print-version)
         (cl-cli:make-option :name "help"    :short #\h :kind :flag :key :print-help))
   :positionals (list (cl-cli:make-positional :key :mode-args :rest-p t)))
  "The root cl-cli app for nerimux's global startup flags.  See main()
   (main-startup.lisp), which also defines %parse-global-cli-argv /
   %apply-global-cli-invocation / %dispatch-global-cli-flag-actions — placed
   there rather than here because they call run-version / run-usage /
   %usage-string, all defined later in the load order
   (main-startup-commands.lisp, main-startup.lisp).")
