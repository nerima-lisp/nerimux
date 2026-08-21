;;; Global CLI flag definitions.
;;;
;;; The define-flag-parser macro and the %parse-attach-flags/%parse-new-session-flags
;;; parsers it generated were removed with the tmux startup modes that used them;
;;; the surviving entry surface (attach, server, -V, -h) takes no per-mode flags.

(in-package :nerimux)

;;; ── Global CLI flags (cl-cli) ────────────────────────────────────────────────
;;;
;;; `nerimux [flags] [command [flags]]`.  The only global flags are -V
;;; (version) and -h (usage); every other flag nerimux once accepted (socket
;;; selection, config file, colour downsampling, read-only attach, and the
;;; rest) is gone along with the settings and startup modes it configured.
;;; An unrecognised flag is a fatal "unknown flag" error.

(defparameter *cli-app*
  (cl-cli:make-app
   :name "nerimux"
   :summary "A workspace multiplexer for git worktrees."
   ;; -h/-V dispatch through run-usage/run-version below, not cl-cli's own
   ;; help/version machinery, to keep their exact existing output.
   :auto-help nil
   :global-options
   (list
         ;; :key overrides the default derived key (:version / :help), which
         ;; cl-cli reserves for its own built-in --version/--help dispatch
         ;; even with :auto-help nil (see %validate-user-option-keys).
         (cl-cli:make-option :name "version" :short #\V :kind :flag :key :print-version)
         (cl-cli:make-option :name "help"    :short #\h :kind :flag :key :print-help))
   :positionals (list (cl-cli:make-positional :key :mode-args :rest-p t)))
  "The root cl-cli app for nerimux's global startup flags.  See main()
   (main-startup.lisp), which also defines %parse-global-cli-argv /
   %apply-global-cli-invocation / %dispatch-global-cli-flag-actions — placed
   there rather than here because they call run-version / run-usage /
   %usage-string, all defined later in the load order
   (main-startup-commands.lisp, main-startup.lisp).")
