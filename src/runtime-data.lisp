(in-package #:nerimux)

(defparameter +runtime-safe-server-name-punctuation+
  '(#\- #\_ #\.)
  "Punctuation preserved when a runtime server name becomes a path component.")

(deftype peer-io-failure ()
  "Conditions that terminate a peer I/O operation and reach its CPS failure path.

The timeout type is explicit because SBCL signals it outside the ERROR hierarchy.
"
  '(or error sb-ext:timeout))

(defvar *dirty*
  t
  "Whether the terminal needs another render pass.")

(defvar *running*
  t
  "Whether the main event loop should continue processing input.")

(defvar *resize-pending*
  nil
  "Whether a SIGWINCH resize is waiting to be applied.")

(defvar *term-rows*
  24
  "Current terminal height in rows.")

(defvar *term-cols*
  80
  "Current terminal width in columns.")

(defvar *server-sessions*
  nil
  "Sessions currently owned by the server runtime.")

(defvar *runtime-persistence-enabled-p*
  nil
  "Whether the running server owns the runtime state file.")

(defvar *runtime-restored-panes*
  nil
  "Restored panes whose one-shot `restored' label has not been cleared.")

(defvar *runtime-restored-worktrees*
  nil
  "Synthetic worktrees waiting to be rebound to the VCS catalog.")

(defvar *runtime-state-signature*
  nil
  "Serialized runtime state last written by this server process.")

(defconstant +reader-thread-join-timeout+
  10
  "Maximum seconds spent joining a PTY reader thread.")

(defconstant +wait-for-channel-timeout+
  30
  "Maximum seconds spent waiting for a channel notification.")

(defparameter *wait-channels*
  (make-hash-table :test #'equal)
  "Condition variables keyed by the channel names used by the runtime.")
