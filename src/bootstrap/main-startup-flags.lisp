;;; Global CLI flag definitions.
;;;
;;; The define-flag-parser macro and the %parse-attach-flags/%parse-new-session-flags
;;; parsers it generated were removed with the tmux startup modes that used them;
;;; attach and server take no flags of their own.  kill (R8.1) is the one
;;; exception — its --force is parsed by run-kill itself
;;; (main-startup-commands.lisp), not by *cli-app* below, per the next
;;; paragraph.

(in-package :nerimux)

;;; ── Global CLI flags (cl-cli) ────────────────────────────────────────────────
;;;
;;; `nerimux [flags] [command [flags]]`.  The only GLOBAL flags are -V
;;; (version) and -h (usage); every other flag nerimux once accepted (socket
;;; selection, config file, colour downsampling, read-only attach, and the
;;; rest) is gone along with the settings and startup modes it configured.
;;; An unrecognised global flag is a fatal "unknown flag" error.
;;;
;;; kill's --force (R8.1, 1.6) is deliberately NOT added here: 1.6 fixes the
;;; global flags at exactly -V and -h, and --force only means anything after
;;; `kill`.  *cli-app*'s single positional (:mode-args, :rest-p t) swallows
;;; the whole "kill --force" tail in one shot once the mixed-argument scanner
;;; reaches the non-flag "kill" token (cl-cli's rest positionals consume
;;; every remaining token unconditionally rather than re-testing each one
;;; against the option table — verified by reading cl-cli 1.3.0's
;;; parser-consumption.lisp, the version pinned in flake.lock), so "--force"
;;; is never matched against *cli-app*'s option table at all and cannot
;;; trigger cl-cli's "unknown option" error the way it would if it appeared
;;; before the mode word.

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
