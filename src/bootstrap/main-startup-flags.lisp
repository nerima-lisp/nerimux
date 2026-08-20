;;; Global CLI flag definitions.
;;;
;;; The define-flag-parser macro and the %parse-attach-flags/%parse-new-session-flags
;;; parsers it generated were removed with the tmux startup modes that used them;
;;; the surviving entry surface (attach, server, -V, -h) takes no per-mode flags.

(in-package :nerimux)

;;; ── Global CLI flags (cl-cli) ────────────────────────────────────────────────
;;;
;;; `nerimux [flags] [command [flags]]` mirrors real tmux(1) (verified against
;;; `man 1 tmux`, tmux 3.7b: usage `tmux [-2CDhlNuVv] [-c shell-command]
;;; [-f file] [-L socket-name] [-S socket-path] [-T features] [command
;;; [flags]]`).  Global flags may appear in ANY order before the command word.
;;;
;;; This replaces the old hand-rolled -L/-S-only argv scanner with a real
;;; option parser, so global flags work in any order rather than only as
;;; argv's first token.
;;;
;;; Flags with real, additional effects: -L/-S (socket), -f (config file, see
;;; config-paths.lisp), -2 (256-colour downsampling, see renderer-format.lisp
;;; *color-downsample-fn*), -r (read-only attach, see runtime.lisp
;;; *client-read-only* and server-multi-dispatch.lisp's per-connection
;;; enforcement), -V (version), -h (usage).  -C (control mode) was
;;; removed with the tmux compatibility surface and is now an unknown flag.
;;; Flags accepted for tmux(1) compatibility with no further behaviour wired
;;; up: -D, -N, -T, -c, -u, -v (real tmux's own -l is likewise documented as
;;; "currently has no effect").  Accepting-without-erroring is still a real
;;; improvement: today every one of these is a fatal "unknown flag" error.

(defparameter *cli-app*
  (cl-cli:make-app
   :name "nerimux"
   :summary "A tmux-compatible terminal multiplexer."
   ;; -h/-V dispatch through run-usage/run-version below, not cl-cli's own
   ;; help/version machinery, to keep their exact existing output.
   :auto-help nil
   :global-options
   (list (cl-cli:make-option :name "socket-name"    :short #\L :kind :value)
         (cl-cli:make-option :name "socket-path"    :short #\S :kind :value)
         (cl-cli:make-option :name "file"           :short #\f :kind :value)
         (cl-cli:make-option :name "force-256"      :short #\2 :kind :flag)
         (cl-cli:make-option :name "read-only"      :short #\r :kind :flag)
         (cl-cli:make-option :name "no-daemonize"   :short #\D :kind :flag)
         (cl-cli:make-option :name "no-start-server" :short #\N :kind :flag)
         (cl-cli:make-option :name "login-shell"    :short #\l :kind :flag)
         (cl-cli:make-option :name "utf8"           :short #\u :kind :flag)
         (cl-cli:make-option :name "features"       :short #\T :kind :value)
         (cl-cli:make-option :name "shell-command"  :short #\c :kind :value)
         (cl-cli:make-option :name "verbose"        :short #\v :kind :count)
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
