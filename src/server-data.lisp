(in-package #:nerimux)

(defvar *bound-socket-path*
  nil
  "The socket path this server actually bound, or NIL in standalone mode.")

(defvar *runtime-server-name*
  "default"
  "Name selecting the server's persistent runtime snapshot.")

(defconstant +status-line-rows+
  1
  "Rows the status bar occupies. Fixed at 1 (§1.4 — no `status' option).")
