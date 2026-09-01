(in-package #:nerimux)

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

(defconstant +reader-thread-join-timeout+
  10
  "Maximum seconds spent joining a PTY reader thread.")

(defconstant +wait-for-channel-timeout+
  30
  "Maximum seconds spent waiting for a channel notification.")

(defparameter *wait-channels*
  (make-hash-table :test #'equal)
  "Condition variables keyed by the channel names used by the runtime.")
