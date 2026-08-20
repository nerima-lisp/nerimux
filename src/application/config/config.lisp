(in-package #:nerimux/config)

;;; ── Inert-directive warning ──────────────────────────────────────────────
;;;
;;; Some tmux .tmux.conf directives still parse successfully but the
;;; subsystem they used to configure was deleted when nerimux narrowed to a
;;; workspace-only multiplexer (bind/unbind/unbind-all/set-hook, and the
;;; prefix/prefix2/mouse options).  %WARN-INERT-CONFIG-DIRECTIVE gives a user
;;; reusing an old config a one-line signal instead of silent misconfiguration,
;;; without changing the "parses, has no effect" contract: callers must keep
;;; treating the directive/option as handled.
;;;
;;; Defined here (config.lisp, the first file in the application/config ASDF
;;; module -- see nerimux.asd) rather than in config-loader.lisp, which the
;;; docstring contract for bind/unbind/set-hook otherwise lives in: the ASDF
;;; load order there is config-directives-set.lisp, then
;;; config-option-side-effects.lisp, then (much later) config-loader.lisp, so
;;; a definition in config-loader.lisp would not be load-order-visible to
;;; config-option-side-effects.lisp's use for prefix/prefix2/mouse.

(defun %warn-inert-config-directive (kind name)
  "Write a one-line warning to *ERROR-OUTPUT* naming a config KIND (\"directive\"
   or \"option\") NAME that parses successfully but has no effect in this
   workspace-only build, because the subsystem it used to configure was
   deleted.  A pure side effect: does not signal a condition and callers must
   keep treating the directive/option as handled (no change to return
   values)."
  (format *error-output*
          "nerimux: config ~A '~A' has no effect (workspace-only build)~%"
          kind name))

;;; ── Shell default ─────────────────────────────────────────────────────────
;;;
;;; The shell to launch lives in the `default-shell' option and nowhere else.
;;; There used to be a *default-shell* variable beside it that every writer
;;; updated and every reader read, leaving the option itself inert -- so
;;; `set-shell' could change the real shell while show-options still reported
;;; the old one.  init-default-shell now writes the option like any other
;;; configuration source; run-server calls it before loading the config file,
;;; so a default-shell line still wins over $SHELL.

(defun init-default-shell ()
  "Set the `default-shell' option from $SHELL when that variable is non-empty.
   Called once from run-server, before the config file is loaded."
  (let ((shell (sb-ext:posix-getenv "SHELL")))
    (when (and shell (plusp (length shell)))
      (nerimux/options:set-option "default-shell" shell))))

(defconstant +pty-buf-size+ 4096
  "Byte buffer size for PTY reads.")

(defconstant +max-scrollback-lines+ 1000
  "Maximum rows retained in the per-pane scrollback buffer.")

(defconstant +poll-timeout-us+ 50000
  "Select timeout in microseconds for stdin/socket polling (50 ms ≈ 20 fps max).")

(defconstant +accept-timeout-us+ 100000
  "Select timeout in microseconds for the server accept-connection loop (100 ms).
   Prevents blocking forever so *running* is checked between connection attempts.")

(defconstant +pty-poll-timeout-us+ 50000
  "Select timeout in microseconds for per-pane PTY reader threads (50 ms).
   Allows the reader loop to observe *running* even when the shell is silent.")
